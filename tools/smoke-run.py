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
  4c. when the app reports `await-tmp-edit`, rewrites a document under /tmp
     (FSEvents reports it as /private/tmp/...); at `await-retarget`, points a
     symlink the app shows at another file, the way `ln -sf` does
  4d. when the app reports `await-cli`, runs `cli/readout -b` on a new file
     and `cli/readout --hook` on plan.md (open in a tab behind); the app
     records whether the tab being read stayed in front
  5. waits for the app to exit on its own (90 s), with its log in OUT_DIR/smoke-out.log
  6. writes OUT_DIR/timings.json: cold start, warm open and write-to-update
     times, from its own clock readings and the app's (timings-app.json)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
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

    # Under /tmp, spelled the way users and agents spell it (not /private/tmp).
    tmp = Path(tempfile.mkdtemp(prefix="readout-live-", dir="/tmp"))
    tmp_file = tmp / "live.md"
    tmp_file.write_text("# TMP-BEFORE\n\nWritten under /tmp.\n")
    # links/latest.md -> ../runs/run-41.md, in another folder than its target.
    (tmp / "runs").mkdir()
    (tmp / "links").mkdir()
    (tmp / "runs" / "run-41.md").write_text("# RUN-41\n\nThe first run.\n")
    (tmp / "runs" / "run-42.md").write_text("# RUN-42\n\nThe next run.\n")
    link = tmp / "links" / "latest.md"
    os.symlink("../runs/run-41.md", link)
    # links/other.md -> run-43.md, later pointed at run-44.md, which has a window of its own.
    (tmp / "runs" / "run-43.md").write_text("# RUN-43\n")
    (tmp / "runs" / "run-44.md").write_text("# RUN-44\n")
    collide = tmp / "links" / "other.md"
    os.symlink("../runs/run-43.md", collide)
    cli_file = work / "background.md"
    cli_file.write_text("# Opened with readout -b\n")

    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out),
               READOUT_SMOKE_SECOND=str(second), READOUT_SMOKE_AGENT_FOLDER=str(agent_dir),
               READOUT_SMOKE_TMP_FILE=str(tmp_file), READOUT_SMOKE_LINK_FILE=str(link),
               READOUT_SMOKE_CLI_FILE=str(cli_file), READOUT_SMOKE_COLLIDE_LINK=str(collide),
               READOUT_SMOKE_COLLIDE_TARGET=str(tmp / "runs" / "run-44.md"))
    # Launch Services must know the bundle for `open -b` to reach the running app.
    bundle = app.parents[2] if app.parent.name == "MacOS" else None
    if bundle is not None:
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-f", str(bundle)], check=False)
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

            if wait_for(out / "await-tmp-edit", proc, 60, poll=0.05):
                src = tmp / ".live.src"
                src.write_text("# TMP-AFTER\n\nRewritten under /tmp.\n")
                agent_write(tmp_file, src)
                print("harness: rewrote the file under /tmp")
            else:
                print("harness: the app never reported `await-tmp-edit`")

            if wait_for(out / "await-retarget", proc, 30, poll=0.05):
                staged = link.with_name(".latest.md.tmp")
                os.symlink("../runs/run-42.md", staged)
                os.replace(staged, link)  # ln -sf, atomically
                print("harness: pointed latest.md at run-42.md")
            else:
                print("harness: the app never reported `await-retarget`")

            if wait_for(out / "await-collide", proc, 30, poll=0.05):
                staged = collide.with_name(".other.md.tmp")
                os.symlink("../runs/run-44.md", staged)
                os.replace(staged, collide)
                print("harness: pointed other.md at run-44.md (open in its own window)")
            else:
                print("harness: the app never reported `await-collide`")

            if wait_for(out / "await-cli", proc, 30, poll=0.05):
                cli = ROOT / "cli" / "readout"
                r = subprocess.run(["/bin/sh", str(cli), "-b", str(cli_file)], capture_output=True, text=True)
                print(f"harness: readout -b exited {r.returncode} {r.stdout}{r.stderr}")
                hook = json.dumps({"tool_input": {"file_path": str(target)}})
                r = subprocess.run(["/bin/sh", str(cli), "--hook"], input=hook, capture_output=True, text=True)
                print(f"harness: readout --hook exited {r.returncode} {r.stdout}{r.stderr}")
            else:
                print("harness: the app never reported `await-cli`")

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
