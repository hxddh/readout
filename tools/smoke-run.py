#!/usr/bin/env python3
"""Drives the signed-product smoke test from outside the app.

The app only exports what it shows (READOUT_SMOKE_OUT, see App/SmokeTest.swift);
every write to the document happens here, the way agents write: a temp file
in the same directory, then an atomic rename over the target.

usage: tools/smoke-run.py APP_BINARY WORK_DIR OUT_DIR

  0. launches the app once on a copy of plan.md (WORK_DIR/boot/boot.md, output in
     OUT_DIR/boot), lets it paint and quit, and removes what that launch saved
     for the next one: the job's first launch is the first time WebKit runs on
     the VM, so the measured launch is the second (cold_apply_ms; owner decision
     2026-10-21). cold_start_ms and the launch phases stay the first launch's;
     its cold_apply_ms is reported as cold_apply_first_boot_ms
  1. copies web/test/fixtures/plan.md (+ image) into WORK_DIR and launches the app on it
  2. 50 ms after the app reports `opened`, replaces it with plan-early.md
     (an agent write racing the first load: the first capture must show it)
  3. when the app reports `await-edit`, replaces it with plan-v2.md
  4. opens a second document while running, three times (warm open)
  4b. when the app reports `await-agent-write` (Readout in the background,
     watching WORK_DIR/agent), writes WORK_DIR/agent/notes.md the agent way;
     the app records whether it opened on its own without activating
  4b'. when the app reports `await-refill`, empties plan.md in place and, once
     the app reports it showed it empty (`refill-emptied`, up to 10 s), writes
     the same bytes back (an agent truncating, then writing); at
     `await-refill-fast`, empties it and writes the same bytes back at once
  4c. when the app reports `await-tmp-edit`, rewrites a document under /tmp
     (FSEvents reports it as /private/tmp/...); at `await-retarget`, points a
     symlink the app shows at another file, the way `ln -sf` does; at
     `await-dangle`, points one at a file not written yet, then writes it
  4d. when the app reports `await-cli`, runs `cli/readout -b` on a new file
     and `cli/readout --hook` on plan.md (open in a tab behind), on a plan
     outside its project, and as Cursor's hook calls it; the app records
     whether the tab being read stayed in front
  5. waits for the app to exit on its own (120 s), with its log in OUT_DIR/smoke-out.log
  6. writes OUT_DIR/timings.json: cold start (and its phases), warm open and
     write-to-update times, from its own clock readings and the app's (timings-app.json)
  7. launches it again in Chinese (-AppleLanguages '(zh-Hans)', READOUT_SMOKE_PASS=zh):
     the app writes menus-zh.json and Settings/welcome shots, then quits (log: smoke-zh.log)

Scroll bars show only while scrolling during the run (the global
AppleShowScrollBars default is set to WhenScrolling and put back afterwards),
so screenshots look as they do with a trackpad.
"""
import json
import os
import plistlib
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


def launch_timings(app: dict, spawn: float) -> dict:
    """One launch: process start to its first document on screen, in phases."""
    applied = sorted(app.get("painted_at") or app.get("applied_at", []))
    first = applied[0] if applied else None
    # Process launch to the first patch on screen.
    t = {"cold_start_ms": round((first - spawn) * 1000, 1) if first else None}
    # The cold start in phases (P5), each in ms since the process started
    # (sysctl), and the segments that are Readout's own: the first window's
    # page loading (from the window, which makes it, to its `ready`),
    # didFinishLaunching to the first window (all on the main thread, before
    # the window exists) and the first document going in (from the later of
    # that page being ready and the document read, to the page's apply). The
    # rest is launch, WebKit's first start and the frame the system paints.
    # The spare page for the next open is made after the first paint.
    phases = app.get("launch_phases_s") or {}
    start = phases.get("process_start")
    if start:
        order = ["will_finish_launching", "did_finish_launching", "open_requested",
                 "window_init", "window_visible", "page_ready", "did_load", "apply", "paint", "spare_created"]
        t["launch_phases_ms"] = {k: round((phases[k] - start) * 1000, 1) for k in order if k in phases}
        t["launch_phases_ms"]["spawn"] = round((spawn - start) * 1000, 1)
    else:
        print(f"harness: no process start time in the app's launch phases {phases}")
    # Process launch to the first window on screen (its first occlusion
    # change to visible): what the reader sees first.
    if "window_visible" in phases:
        t["cold_window_visible_ms"] = round((phases["window_visible"] - spawn) * 1000, 1)
    # The first window's page, from the window (which makes it) to its ready.
    if "window_init" in phases and "page_ready" in phases:
        t["cold_page_ready_ms"] = round((phases["page_ready"] - phases["window_init"]) * 1000, 1)
    if "did_finish_launching" in phases and "window_init" in phases:
        t["cold_dfl_to_window_ms"] = round((phases["window_init"] - phases["did_finish_launching"]) * 1000, 1)
    # Readout's own work between the window and its document: reading the
    # file, parsing it, the reading state and the git baseline (no WebKit).
    if "window_init" in phases and "did_load" in phases:
        t["cold_window_to_load_ms"] = round((phases["did_load"] - phases["window_init"]) * 1000, 1)
    # After the first document is on screen: the longest a call into its page
    # waited (App/SmokeTest.swift), what a click or a key pressed then waits for.
    if isinstance(app.get("post_paint_input_delay_ms"), (int, float)):
        t["cold_post_paint_input_delay_ms"] = app["post_paint_input_delay_ms"]
    if all(k in phases for k in ("page_ready", "did_load", "apply")):
        t["cold_apply_ms"] = round((phases["apply"] - max(phases["page_ready"], phases["did_load"])) * 1000, 1)
    # The page's side of it (page time): its first setAppearance, then the
    # first apply's block work and the layout it reads.
    page = app.get("page_first_apply_ms") or {}
    # And where its first paint's time goes (5.0 profiling): when its script
    # ran and its first apply came (since the page started), how long that
    # paint then waited for the code it shows, and when the highlighter's
    # worker said it runs.
    for k in ("setAppearance", "blocks", "layout", "script_at", "apply_at", "hold", "worker_ready", "raf_at", "painted_at", "mermaid_at", "katex_at", "katex_loaded_at", "katex", "gap", "gap_at"):
        if isinstance(page.get(k), (int, float)):
            t[f"cold_page_{k.lower()}_ms"] = page[k]
    return t


# The launch metrics the first launch of the job keeps (cold_start_ms is a
# tripwire for a first launch that crashes or hangs; the phases and Readout's
# segments before the document goes in are the first launch's, as before).
FIRST_LAUNCH_KEYS = ("cold_start_ms", "launch_phases_ms", "cold_page_ready_ms", "cold_dfl_to_window_ms", "cold_window_to_load_ms")


def write_timings(out: Path, clock: dict, second: Path) -> None:
    """Combines the harness's clock with the app's into milliseconds."""
    try:
        app = json.loads((out / "timings-app.json").read_text())
        boot = json.loads((out / "boot" / "timings-app.json").read_text())
    except (OSError, ValueError) as e:
        print(f"harness: no app timings ({e})")
        return
    applied = sorted(app.get("painted_at") or app.get("applied_at", []))
    after = lambda t: next((a for a in applied if a >= t), None)
    update = after(clock["edit"]) if "edit" in clock else None
    timings = {
        # Agent write (rename) to the patch on screen: FSEvents, debounce, parse, diff, apply.
        "write_to_update_ms": round((update - clock["edit"]) * 1000, 1) if update else None,
        # App already running: window request to first patch, for a 77 KB document.
        # The median of the app's opens of it (three), so one slow moment of a
        # shared runner does not decide; every sample is kept alongside.
        "warm_open_ms": None,
    }
    # Two launches (owner decision 2026-10-21): the first launch of the job,
    # on a VM just booted, is the first time WebKit runs there (its processes,
    # caches and shaders start cold: the first document's style and layout
    # took 2-3x as long as in any later launch on the same runner, with the
    # same Readout work). That is not what users pay, so cold_apply_ms is the
    # second launch's (a new process, nothing kept from the first but what
    # macOS and WebKit cache on disk); the first launch's value is reported as
    # cold_apply_first_boot_ms. The other launch metrics stay the first launch's.
    measured = launch_timings(app, clock["spawn"])
    first_boot = launch_timings(boot, clock["boot_spawn"])
    timings.update({k: first_boot[k] for k in FIRST_LAUNCH_KEYS if k in first_boot})
    timings["cold_apply_ms"] = measured.get("cold_apply_ms")
    timings["cold_apply_first_boot_ms"] = first_boot.get("cold_apply_ms")
    for k, v in measured.items():
        if k.startswith("cold_page_") and k != "cold_page_ready_ms":
            timings[k] = v
    for k, v in first_boot.items():
        if k.startswith("cold_page_") and k != "cold_page_ready_ms":
            timings[k.replace("_ms", "_first_boot_ms")] = v
    timings["launch_phases_second_ms"] = measured.get("launch_phases_ms")
    timings["cold_start_second_ms"] = measured.get("cold_start_ms")
    # Spawn to the first window on screen, the measured launch's (gated) and
    # the first launch's (reported, with its code-signing assessment and
    # WebKit's first start on the VM).
    timings["cold_window_visible_ms"] = measured.get("cold_window_visible_ms")
    timings["cold_window_visible_first_boot_ms"] = first_boot.get("cold_window_visible_ms")
    timings["cold_post_paint_input_delay_ms"] = measured.get("cold_post_paint_input_delay_ms")
    timings["cold_post_paint_input_delay_first_boot_ms"] = first_boot.get("cold_post_paint_input_delay_ms")

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
    # Each warm open's page timings (page time; report only): where the open's
    # time goes once the page has the document.
    timings["warm_page_ms"] = app.get("warm_page_ms") or []
    # And the app's side of the warm opens: request to the document read and
    # parsed, and to the apply sent (seconds; report only).
    timings["warm_open_steps_s"] = for_second(app.get("open_steps_s", {})) or []
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
    # Windows opened back to back: the second and third ones' pages start cold.
    (tmp / "cold-a.md").write_text("# Cold A\n")
    (tmp / "cold-b.md").write_text("# Cold B\n")
    (tmp / "cold-c.md").write_text("# Cold C\n")
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
    # One Cursor's afterFileEdit hook reports: the file at the top level, the project as a workspace root.
    cursor_plan = tmp / "plans" / "cursor.md"
    cursor_plan.write_text("# Cursor plan\n\nWritten by Cursor.\n")
    # Two documents restored as the tabs of one window (as after a relaunch).
    (tmp / "restore").mkdir()
    for name in ("first", "second"):
        (tmp / "restore" / f"{name}.md").write_text(f"# Restored {name}\n\nA tab of the last launch.\n")
    # Two documents with the same title, in different files: their tabs say which file.
    dups = [tmp / "dup-a" / "fix.md", tmp / "dup-b" / "refactor.md"]
    for d in dups:
        d.parent.mkdir()
        d.write_text("# Same plan\n\nTwo agents titled their plans alike.\n")

    # A git repository: a committed document changed since (first opened, it
    # is marked against the commit) and an untracked one beside it (unmarked).
    repo = tmp / "repo"
    (repo / "docs").mkdir(parents=True)
    git_file = repo / "docs" / "notes.md"
    git_file.write_text("# Notes\n\nThe first step stays as it was.\n\nRun the migration on staging first, then on production.\n")
    git = ["git", "-C", str(repo), "-c", "user.name=Readout Smoke", "-c", "user.email=smoke@example.invalid", "-c", "commit.gpgsign=false"]
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "notes"]):
        r = subprocess.run(git + args, capture_output=True, text=True)
        print(f"harness: git {args[0]} exited {r.returncode} {r.stderr.strip()}")
    git_file.write_text("# Notes\n\nThe first step stays as it was.\n\nRun the migration on staging first, then on production at night.\n\nA step the agent added.\n")
    git_untracked = repo / "docs" / "untracked.md"
    git_untracked.write_text("# Untracked\n\nNever committed.\n")

    env = dict(os.environ, READOUT_SMOKE_FILE=str(target), READOUT_SMOKE_OUT=str(out),
               READOUT_SMOKE_SECOND=str(second), READOUT_SMOKE_AGENT_FOLDER=str(agent_dir),
               READOUT_SMOKE_TMP_FILE=str(tmp_file), READOUT_SMOKE_LINK_FILE=str(link),
               READOUT_SMOKE_CLI_FILE=str(cli_file), READOUT_SMOKE_HOOK_PLAN=str(hook_plan), READOUT_SMOKE_COLLIDE_LINK=str(collide),
               READOUT_SMOKE_CURSOR_PLAN=str(cursor_plan),
               READOUT_SMOKE_RESTORE_FILES=":".join(str(tmp / "restore" / f"{n}.md") for n in ("first", "second")),
               READOUT_SMOKE_COLLIDE_TARGET=str(tmp / "runs" / "run-44.md"),
               READOUT_SMOKE_LATE_FOLDER=str(late_dir), READOUT_SMOKE_DANGLE_LINK=str(dangle), READOUT_SMOKE_UNREADABLE=str(locked),
               READOUT_SMOKE_DUP_FILES=":".join(str(d) for d in dups),
               READOUT_SMOKE_GIT_FILE=str(git_file), READOUT_SMOKE_GIT_UNTRACKED=str(git_untracked))
    # Launch Services must know the bundle for `open -b` to reach the running app.
    bundle = app.parents[2] if app.parent.name == "MacOS" else None
    if bundle is not None:
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-f", str(bundle)], check=False)
    scroll_bars = subprocess.run(["defaults", "read", "-g", "AppleShowScrollBars"], capture_output=True, text=True)
    subprocess.run(["defaults", "write", "-g", "AppleShowScrollBars", "-string", "WhenScrolling"], check=False)
    try:
        clock = {}
        code = boot_pass(app, work, out, clock)
        if code != 0:
            return code
        code = run(app, target, out, env, clock, second, cli_file, hook_plan, project, tmp, tmp_file, link, collide, dangle, agent_dir, late_dir, work)
        if code == 0:
            code = locale_pass(app, target, out)
        return code
    finally:
        if scroll_bars.returncode == 0:
            subprocess.run(["defaults", "write", "-g", "AppleShowScrollBars", "-string", scroll_bars.stdout.strip()], check=False)
        else:
            subprocess.run(["defaults", "delete", "-g", "AppleShowScrollBars"], check=False)


BUNDLE_ID = "io.github.hxddh.readout"
SENTINEL_KEY = "ReadoutSmokeSentinel"


class SavedState:
    """What a launch of the app can leave behind for the next one, as it was
    before: its defaults domain, its Application Support folder (reading
    state, baselines) and its saved windows. Restored exactly afterwards, so a
    launch the harness adds never changes anything it did not create (run on
    a developer's own account, the reader's data stays theirs).

    Nothing of theirs is deleted before what replaces it is in place: each
    folder's copy is made beside it (NAME.smoke-kept, same volume), and the
    restore renames the launch's folder aside, then the copy into place, and
    only then deletes the launch's. The defaults are imported over the
    launch's, then the keys it added are deleted. An interrupted run leaves
    the copy beside the folder; the next run stops until it is looked at."""

    def __init__(self, scratch: Path):
        lib = Path.home() / "Library"
        self.dirs = [lib / "Application Support" / "Readout", lib / "Saved Application State" / f"{BUNDLE_ID}.savedState"]
        self.scratch = scratch
        for d in self.dirs:
            if d.with_name(d.name + ".smoke-kept").exists():
                sys.exit(f"FAIL: {d.with_name(d.name + '.smoke-kept')} is left from an interrupted run: "
                         f"it may hold the only copy of {d.name}; put it back or remove it, then run again")
        shutil.rmtree(scratch, ignore_errors=True)
        scratch.mkdir(parents=True)
        for d in self.dirs:
            if d.exists():
                shutil.copytree(d, d.with_name(d.name + ".smoke-kept"), symlinks=True)
        self.prefs = scratch / "prefs.plist"
        self.had_prefs = subprocess.run(["defaults", "export", BUNDLE_ID, str(self.prefs)], capture_output=True).returncode == 0

    def restore(self) -> None:
        for d in self.dirs:
            kept, aside = d.with_name(d.name + ".smoke-kept"), d.with_name(d.name + ".smoke-boot")
            shutil.rmtree(aside, ignore_errors=True)
            if d.exists():
                os.rename(d, aside)
            if kept.exists():
                os.rename(kept, d)
            shutil.rmtree(aside, ignore_errors=True)
        if self.had_prefs:
            subprocess.run(["defaults", "import", BUNDLE_ID, str(self.prefs)], check=False)
            before = plistlib.loads(self.prefs.read_bytes())
            now = subprocess.run(["defaults", "export", BUNDLE_ID, "-"], capture_output=True).stdout
            for key in set(plistlib.loads(now) if now else {}) - set(before):
                subprocess.run(["defaults", "delete", BUNDLE_ID, key], capture_output=True)
        else:
            subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
        shutil.rmtree(self.scratch, ignore_errors=True)


def boot_pass(app: Path, work: Path, out: Path, clock: dict) -> int:
    """The job's first launch, before the measured one: the same document
    under another name, painted, its timings written to OUT_DIR/boot, then
    quit. WebKit's processes, caches and shaders have then run once on this
    VM. Everything the launch could leave for the next one (SavedState) is put
    back as it was, so the measured launch starts as this one did; the app
    adds nothing to the recent documents in this pass. A sentinel preference
    and baseline, written before, must still be there after
    (OUT_DIR/boot/sentinel.json, checked by smoke-assert)."""
    boot_dir = work / "boot"
    boot_dir.mkdir(exist_ok=True)
    doc = boot_dir / "boot.md"
    shutil.copyfile(FIXTURES / "plan.md", doc)
    shutil.copyfile(FIXTURES / "missing-diagram.png", boot_dir / "missing-diagram.png")
    boot_out = out / "boot"
    boot_out.mkdir(exist_ok=True)
    baselines = Path.home() / "Library" / "Application Support" / "Readout" / "Baselines"
    baselines.mkdir(parents=True, exist_ok=True)
    sentinel_file = baselines / "readout-smoke-sentinel.json"
    token = f"boot-{os.getpid()}-{time.time()}"
    sentinel_file.write_text(json.dumps({"sentinel": token}))
    subprocess.run(["defaults", "write", BUNDLE_ID, SENTINEL_KEY, "-string", token], check=False)
    saved = SavedState(work / "boot-saved-state")
    env = dict(os.environ, READOUT_SMOKE_FILE=str(doc), READOUT_SMOKE_OUT=str(boot_out), READOUT_SMOKE_PASS="boot")
    try:
        with open(boot_out / "smoke-boot.log", "wb") as log:
            clock["boot_spawn"] = time.time()
            proc = subprocess.Popen([str(app)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                print("FAIL: the first launch did not paint and quit within 60 seconds")
                return 1
    finally:
        saved.restore()
        pref = subprocess.run(["defaults", "read", BUNDLE_ID, SENTINEL_KEY], capture_output=True, text=True).stdout.strip()
        kept = {"preference": pref == token,
                "baseline": sentinel_file.exists() and json.loads(sentinel_file.read_text()).get("sentinel") == token}
        (boot_out / "sentinel.json").write_text(json.dumps(kept) + "\n")
        print(f"harness: state kept through the first launch: {kept}")
        # The sentinel is the harness's own: gone before the measured launch.
        subprocess.run(["defaults", "delete", BUNDLE_ID, SENTINEL_KEY], capture_output=True)
        sentinel_file.unlink(missing_ok=True)
    print(f"harness: first launch exited with code {code}")
    return code


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
                # Written back once the app has shown it empty (an empty read is
                # read again a moment later, and the same bytes as shown would
                # change nothing: DocumentLoader), so both versions are applied.
                if not wait_for(out / "refill-emptied", proc, 10, poll=0.05):
                    print("harness: the app never showed the emptied plan.md within 10 s (no `refill-emptied`); writing it back anyway")
                with open(target, "wb") as f:
                    f.write(data)
                print("harness: emptied plan.md and wrote it back")
            else:
                print("harness: the app never reported `await-refill`")

            if wait_for(out / "await-refill-fast", proc, 60, poll=0.05):
                data = target.read_bytes()
                with open(target, "wb"):
                    pass
                with open(target, "wb") as f:
                    f.write(data)  # the same bytes, at once
                print("harness: emptied plan.md and wrote the same bytes back at once")
            else:
                print("harness: the app never reported `await-refill-fast`")

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
                # Cursor's afterFileEdit: top-level file_path and workspace_roots.
                hook = json.dumps({"file_path": str(tmp / "plans" / "cursor.md"), "edits": [], "workspace_roots": [str(project)]})
                r = subprocess.run(["/bin/sh", str(cli), "--hook"], input=hook, capture_output=True, text=True)
                print(f"harness: readout --hook (Cursor) exited {r.returncode} {r.stdout}{r.stderr}")
                # The file opened behind gets a new section: its tab shows the unread dot.
                time.sleep(1.0)
                src = work / ".background.src"
                src.write_text("# Opened with readout -b\n\n## Added later\n\nA section written after it was opened.\n")
                agent_write(cli_file, src)
                print("harness: added a section to background.md")
            else:
                print("harness: the app never reported `await-cli`")

            try:
                code = proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                print("FAIL: the signed app did not exit on its own within 120 seconds")
                return 1
            print(f"signed app exited with code {code}")
            write_timings(out, clock, second)
            return code
        finally:
            if proc.poll() is None:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
