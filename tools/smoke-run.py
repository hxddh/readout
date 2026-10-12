#!/usr/bin/env python3
"""Drives the signed-product smoke test from outside the app.

The app only exports what it shows (READOUT_SMOKE_OUT, see App/SmokeTest.swift);
every write to the document happens here, the way agents write: a temp file
in the same directory, then an atomic rename over the target.

usage: tools/smoke-run.py APP_BINARY WORK_DIR OUT_DIR

  1. copies web/test/fixtures/plan.md (+ image) into WORK_DIR and launches the app on it
  2. 50 ms after the app reports `opened`, replaces it with plan-early.md
     (an agent write racing the first load: the first capture must show it)
  3. when the app reports `await-edit`, replaces it with plan-v2.md
  4. opens a second document while running (warm open)
  4b. when the app reports `await-agent-write` (Readout in the background,
     watching WORK_DIR/agent), writes WORK_DIR/agent/notes.md the agent way;
     the app records whether it opened on its own without activating
  5. waits for the app to exit on its own (90 s), with its log in OUT_DIR/smoke-out.log
  6. writes OUT_DIR/timings.json: cold start, warm open and write-to-update
     times, from its own clock readings and the app's (timings-app.json)
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "web" / "test" / "fixtures"


def agent_write(target: Path, source: Path) -> None:
    tmp = target.with_name(f".{target.name}.agent.tmp")
    shutil.copyfile(source, tmp)
    os.replace(tmp, target)


def wait_for(path: Path, proc: subprocess.Popen, timeout: float, poll: float = 0.005) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return True
        if proc.poll() is not None:
            return False
        time.sleep(poll)
    return False


def write_timings(out: Path, clock: dict, second: Path) -> None:
    """Combines the harness's clock with the app's into milliseconds."""
    try:
        app = json.loads((out / "timings-app.json").read_text())
    except (OSError, ValueError) as e:
        print(f"harness: no app timings ({e})")
        return
    # On-screen times: the frames that showed a patch (fall back to the apply).
    applied = sorted(app.get("painted_at") or app.get("applied_at", []))
    after = lambda t: next((a for a in applied if a >= t), None)
    first = applied[0] if applied else None
    update = after(clock["edit"]) if "edit" in clock else None
    timings = {
        # Process launch to the first patch on screen.
        "cold_start_ms": round((first - clock["spawn"]) * 1000, 1) if first else None,
        # Agent write (rename) to the patch on screen: FSEvents, debounce, parse, diff, apply.
        "write_to_update_ms": round((update - clock["edit"]) * 1000, 1) if update else None,
        # App already running: window request to first patch, for a 77 KB document.
        "warm_open_ms": None,
    }
    paints = app.get("first_paint_s", {})
    warm = paints.get(str(second.resolve()), paints.get(str(second)))
    if warm is None:  # the app reports the standardized path; match by name
        warm = next((v for k, v in paints.items() if k.endswith("/second.md")), None)
    if warm is not None:
        timings["warm_open_ms"] = round(warm * 1000, 1)
    (out / "timings.json").write_text(json.dumps(timings, indent=1, sort_keys=True) + "\n")
    print(f"harness: timings {timings}")


def main() -> int:
    app, work, out = (Path(a) for a in sys.argv[1:4])
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    target = work / "plan.md"
    shutil.copyfile(FIXTURES / "plan.md", target)
    shutil.copyfile(FIXTURES / "missing-diagram.png", work / "missing-diagram.png")
    second = work / "second.md"
    shutil.copyfile(ROOT / "web" / "test" / "corpus" / "01-sdd-fix-loop-plan.md", second)

    agent_dir = work / "agent"
    agent_dir.mkdir(exist_ok=True)
    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out),
               READOUT_SMOKE_SECOND=str(second), READOUT_SMOKE_AGENT_FOLDER=str(agent_dir))
    clock = {}
    with open(out / "smoke-out.log", "wb") as log:
        clock["spawn"] = time.time()
        proc = subprocess.Popen([str(app)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            if not wait_for(out / "opened", proc, 30):
                print("FAIL: the app never reported `opened`")
                return 1
            time.sleep(0.05)
            agent_write(target, FIXTURES / "plan-early.md")
            print("harness: early edit written")

            if not wait_for(out / "await-edit", proc, 60, poll=0.05):
                print("FAIL: the app never reported `await-edit`")
                return 1
            agent_write(target, FIXTURES / "plan-v2.md")
            clock["edit"] = time.time()
            print("harness: edit written")

            if wait_for(out / "await-agent-write", proc, 60, poll=0.05):
                agent_write(agent_dir / "notes.md", FIXTURES / "plan.md")
                print("harness: agent wrote notes.md")
            else:
                print("harness: the app never reported `await-agent-write`")

            try:
                code = proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                print("FAIL: the signed app did not exit on its own within 90 seconds")
                return 1
            print(f"signed app exited with code {code}")
            write_timings(out, clock, second)
            return code
        finally:
            if proc.poll() is None:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
