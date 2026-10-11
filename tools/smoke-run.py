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
  4. waits for the app to exit on its own (90 s), with its log in OUT_DIR/smoke-out.log
"""
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


def main() -> int:
    app, work, out = (Path(a) for a in sys.argv[1:4])
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    target = work / "plan.md"
    shutil.copyfile(FIXTURES / "plan.md", target)
    shutil.copyfile(FIXTURES / "missing-diagram.png", work / "missing-diagram.png")

    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out))
    with open(out / "smoke-out.log", "wb") as log:
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
            print("harness: edit written")

            try:
                code = proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                print("FAIL: the signed app did not exit on its own within 90 seconds")
                return 1
            print(f"signed app exited with code {code}")
            return code
        finally:
            if proc.poll() is None:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
