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
  4. opens a second document while running, three times (warm open)
  4b. when the app reports `await-agent-write` (Readout in the background,
     watching WORK_DIR/agent), writes WORK_DIR/agent/notes.md the agent way;
     the app records whether it opened on its own without activating
  4b'. when the app reports `await-refill`, empties plan.md in place and writes
     the same bytes back a second later (an agent truncating, then writing)
  4c. when the app reports `await-tmp-edit`, rewrites a document under /tmp
     (FSEvents reports it as /private/tmp/...); at `await-retarget`, points a
     symlink the app shows at another file, the way `ln -sf` does; at
     `await-dangle`, points one at a file not written yet, then writes it
  4d. when the app reports `await-cli`, runs `cli/readout -b` on a new file
     and `cli/readout --hook` on plan.md (open in a tab behind); the app
     records whether the tab being read stayed in front
  5. waits for the app to exit on its own (90 s), with its log in OUT_DIR/smoke-out.log
  6. writes OUT_DIR/timings.json: cold start, warm open and write-to-update
     times, from its own clock readings and the app's (timings-app.json)
  7. launches it again in Chinese (-AppleLanguages '(zh-Hans)', READOUT_SMOKE_PASS=zh):
     the app writes menus-zh.json and Settings/welcome shots, then quits (log: smoke-zh.log)

Scroll bars show only while scrolling during the run (the global
AppleShowScrollBars default is set to WhenScrolling and put back afterwards),
so screenshots look as they do with a trackpad.
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
# Opens of the second document in App/SmokeTest.swift (warm_open_ms is their median).
WARM_OPENS = 3
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
        # The median of the app's opens of it (three), so one slow moment of a
        # shared runner does not decide; every sample is kept alongside.
        "warm_open_ms": None,
    }
    def for_second(table):
        found = table.get(str(second.resolve()), table.get(str(second)))
        if found is None:  # the app reports the standardized path; match by name
            found = next((v for k, v in table.items() if k.endswith("/second.md")), None)
        return found
    samples = for_second(app.get("first_paint_samples_s", {})) or []
    timings["warm_open_samples_ms"] = [round(v * 1000, 1) for v in samples]
    warm = None
    # Every open must have painted: one that never did (or past the app's
    # 10 s wait) leaves warm_open_ms unmeasured, which fails the budget.
    if len(samples) == WARM_OPENS:
        ordered = sorted(samples)
        warm = ordered[len(ordered) // 2]
    else:
        print(f"harness: {len(samples)} of {WARM_OPENS} warm opens painted")
    if warm is not None:
        timings["warm_open_ms"] = round(warm * 1000, 1)
    # Readout's own share of those opens: window request to the page's first
    # apply, without the frame the system paints it in. The fastest of the
    # three: a shared runner only ever adds time (main measured 768/416/403 ms
    # and 1274/451/693 ms for the same code), so the minimum is the closest
    # reading of Readout's own work and the one a regression must move.
    applied_samples = for_second(app.get("first_apply_samples_s", {})) or []
    timings["warm_open_to_applied_samples_ms"] = [round(v * 1000, 1) for v in applied_samples]
    timings["warm_open_to_applied_ms"] = (round(min(applied_samples) * 1000, 1)
                                          if len(applied_samples) == WARM_OPENS else None)
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
    # An agent folder in Settings that is created only after launch.
    late_dir = work / "late" / "plans"
    shutil.rmtree(work / "late", ignore_errors=True)

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
    # links/next.md -> run-45.md, later pointed at run-46.md before that file is written.
    (tmp / "runs" / "run-45.md").write_text("# RUN-45\n")
    dangle = tmp / "links" / "next.md"
    os.symlink("../runs/run-45.md", dangle)
    # A file that exists but cannot be read.
    locked = tmp / "locked.md"
    locked.write_text("# Locked\n")
    os.chmod(locked, 0)
    # Two windows opened back to back: the second one's page starts cold.
    (tmp / "cold-a.md").write_text("# Cold A\n")
    (tmp / "cold-b.md").write_text("# Cold B\n")
    cli_file = work / "background.md"
    cli_file.write_text("# Opened with readout -b\n")
    # A plan outside its project, as Claude Code keeps them (~/.claude/plans),
    # naming a file relative to the project the hook reports as its cwd.
    project = tmp / "project"
    (project / "src" / "app").mkdir(parents=True)
    (project / "src" / "app" / "feature.swift").write_text("// feature\n")
    (tmp / "plans").mkdir()
    hook_plan = tmp / "plans" / "hooked.md"
    hook_plan.write_text("# Hooked plan\n\nChange `src/app/feature.swift:3` first.\n")
    # Two documents with the same title, in different files: their tabs say which file.
    dups = [tmp / "dup-a" / "fix.md", tmp / "dup-b" / "refactor.md"]
    for d in dups:
        d.parent.mkdir()
        d.write_text("# Same plan\n\nTwo agents titled their plans alike.\n")

    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out),
               READOUT_SMOKE_SECOND=str(second), READOUT_SMOKE_AGENT_FOLDER=str(agent_dir),
               READOUT_SMOKE_TMP_FILE=str(tmp_file), READOUT_SMOKE_LINK_FILE=str(link),
               READOUT_SMOKE_CLI_FILE=str(cli_file), READOUT_SMOKE_HOOK_PLAN=str(hook_plan), READOUT_SMOKE_COLLIDE_LINK=str(collide),
               READOUT_SMOKE_COLLIDE_TARGET=str(tmp / "runs" / "run-44.md"),
               READOUT_SMOKE_LATE_FOLDER=str(late_dir), READOUT_SMOKE_DANGLE_LINK=str(dangle), READOUT_SMOKE_UNREADABLE=str(locked),
               READOUT_SMOKE_DUP_FILES=":".join(str(d) for d in dups))
    # Launch Services must know the bundle for `open -b` to reach the running app.
    bundle = app.parents[2] if app.parent.name == "MacOS" else None
    if bundle is not None:
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-f", str(bundle)], check=False)
    scroll_bars = subprocess.run(["defaults", "read", "-g", "AppleShowScrollBars"], capture_output=True, text=True)
    subprocess.run(["defaults", "write", "-g", "AppleShowScrollBars", "-string", "WhenScrolling"], check=False)
    try:
        code = run(app, target, out, env, {}, second, cli_file, hook_plan, project, tmp, tmp_file, link, collide, dangle, agent_dir, late_dir, work)
        if code == 0:
            code = locale_pass(app, target, out)
        return code
    finally:
        if scroll_bars.returncode == 0:
            subprocess.run(["defaults", "write", "-g", "AppleShowScrollBars", "-string", scroll_bars.stdout.strip()], check=False)
        else:
            subprocess.run(["defaults", "delete", "-g", "AppleShowScrollBars"], check=False)


def locale_pass(app: Path, target: Path, out: Path) -> int:
    """The app again, in Chinese: it writes menus-zh.json and two shots, then quits."""
    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out), READOUT_SMOKE_PASS="zh")
    with open(out / "smoke-zh.log", "wb") as log:
        proc = subprocess.Popen([str(app), "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"],
                                env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("FAIL: the Chinese pass did not exit on its own within 60 seconds")
            return 1
    print(f"Chinese pass exited with code {code}")
    return code


def run(app, target, out, env, clock, second, cli_file, hook_plan, project, tmp, tmp_file, link, collide, dangle, agent_dir, late_dir, work) -> int:
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

            if wait_for(out / "await-late-folder", proc, 30, poll=0.05):
                time.sleep(0.5)
                late_dir.mkdir(parents=True)
                agent_write(late_dir / "late.md", FIXTURES / "plan.md")
                print("harness: created the late agent folder and wrote late.md")
            else:
                print("harness: the app never reported `await-late-folder`")

            if wait_for(out / "await-refill", proc, 60, poll=0.05):
                data = target.read_bytes()
                with open(target, "wb"):
                    pass  # emptied in place, the way `>` truncates
                time.sleep(1.0)
                with open(target, "wb") as f:
                    f.write(data)
                print("harness: emptied plan.md and wrote it back")
            else:
                print("harness: the app never reported `await-refill`")

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

            if wait_for(out / "await-dangle", proc, 30, poll=0.05):
                staged = dangle.with_name(".next.md.tmp")
                os.symlink("../runs/run-46.md", staged)
                os.replace(staged, dangle)  # run-46.md does not exist yet
                time.sleep(1.0)
                src = tmp / ".run-46.src"
                src.write_text("# RUN-46\n\nWritten after the link.\n")
                agent_write(tmp / "runs" / "run-46.md", src)
                print("harness: pointed next.md at run-46.md, then wrote run-46.md")
            else:
                print("harness: the app never reported `await-dangle`")

            if wait_for(out / "await-cli", proc, 30, poll=0.05):
                cli = ROOT / "cli" / "readout"
                r = subprocess.run(["/bin/sh", str(cli), "-b", str(cli_file)], capture_output=True, text=True)
                print(f"harness: readout -b exited {r.returncode} {r.stdout}{r.stderr}")
                hook = json.dumps({"tool_input": {"file_path": str(target)}})
                r = subprocess.run(["/bin/sh", str(cli), "--hook"], input=hook, capture_output=True, text=True)
                print(f"harness: readout --hook exited {r.returncode} {r.stdout}{r.stderr}")
                # The plan opened by a hook without a folder (before 3.6), then
                # with the project folder Claude Code reports as its cwd.
                hook = json.dumps({"tool_input": {"file_path": str(hook_plan)}})
                r = subprocess.run(["/bin/sh", str(cli), "--hook"], input=hook, capture_output=True, text=True)
                print(f"harness: readout --hook (no cwd) exited {r.returncode} {r.stdout}{r.stderr}")
                time.sleep(1.5)
                hook = json.dumps({"cwd": str(project), "tool_input": {"file_path": str(hook_plan)}})
                r = subprocess.run(["/bin/sh", str(cli), "--hook"], input=hook, capture_output=True, text=True)
                print(f"harness: readout --hook (cwd) exited {r.returncode} {r.stdout}{r.stderr}")
                # The file opened behind gets a new section: its tab shows the unread dot.
                time.sleep(1.0)
                src = work / ".background.src"
                src.write_text("# Opened with readout -b\n\n## Added later\n\nA section written after it was opened.\n")
                agent_write(cli_file, src)
                print("harness: added a section to background.md")
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
