#!/usr/bin/env python3
"""Asserts on signed-product smoke output. Any failed assertion exits nonzero.

Reads smoke-out/*.json plus smoke-out.log, the pluginkit listing and the
qlmanage log. CI prints the actual values first (see the `1-initial:` /
`2-after-edit:` / `4-dark:` lines in the log), then checks the hard
thresholds below. Thresholds were taken from those printed values for
web/test/fixtures/plan.md -> plan-v2.md and must NOT be edited to make a
run pass — a mismatch means the product regressed.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "smoke-out"

failures = []


def check(name, cond, extra=""):
    print(("ok: " if cond else "FAIL: ") + name + (f" [{extra}]" if extra else ""))
    if not cond:
        failures.append(name)


def load(name):
    p = OUT / name
    try:
        return json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001 - report and fail, never crash
        check(f"{name} readable", False, str(e))
        return {}


initial = load("1-initial.json")
print(f"1-initial: {initial}")
check("1-initial blocks == 33", initial.get("blocks") == 33, initial)
check("1-initial highlighted >= 2", (initial.get("highlighted") or 0) >= 2, initial)
check("1-initial math >= 3", (initial.get("math") or 0) >= 3, initial)
# Task E4: tools/smoke-run.py replaced the file 50ms after the app opened it;
# the first capture must already show the replacement, not the stale content.
check("1-initial early edit applied", initial.get("early") is True, initial)

edit = load("2-after-edit.json")
print(f"2-after-edit: {edit}")
check("2-after-edit blocks == 34", edit.get("blocks") == 34, edit)
check("2-after-edit marks == 4", edit.get("marks") == 4, edit)
check("2-after-edit deletions == 1", edit.get("deletions") == 1, edit)
shift = edit.get("anchorShift")
check(
    "2-after-edit |anchorShift| <= 2",
    isinstance(shift, (int, float)) and abs(shift) <= 2,
    f"anchorShift={shift}",
)
check("2-after-edit mermaid >= 1", (edit.get("mermaid") or 0) >= 1, edit)

marks = load("3-marks.json")
print(f"3-marks: {marks}")
# The edited table's comparison: the changed cell reads 未知 -> 不支持.
ins = "".join(marks.get("diffIns") or [])
dels = "".join(marks.get("diffDel") or [])
check("3-marks table comparison shows 不支持 as added", "不支持" in ins, marks)
check("3-marks table comparison shows 未知 as removed", "未知" in dels, marks)

dark = load("4-dark.json")
print(f"4-dark: {dark}")
check("4-dark theme == dark", dark.get("theme") == "dark", dark)

agent = load("agent-folder.json")
print(f"agent-folder: {agent}")
# A document an agent writes into a watched folder opens on its own and leaves focus where it was.
check("agent folder: Readout was in the background", agent.get("active_before") is False, agent)
check("agent folder: notes.md opened on its own", agent.get("auto_opened") == ["notes.md"], agent)
check("agent folder: Readout was not activated", agent.get("active_after") is False, agent)

logp = OUT / "smoke-out.log"
log = logp.read_text() if logp.exists() else ""
check("smoke-out.log present", logp.exists())
check("no page errors in log", "Readout page error" not in log)
check("no scheme 404 in log", "scheme handler: 404" not in log)

qlp = OUT / "ql-pluginkit.log"
ql = qlp.read_text() if qlp.exists() else ""
check("ql-pluginkit.log present", qlp.exists())
check(
    "quicklook extension registered",
    "io.github.hxddh.readout.quicklook" in ql.lower(),
    ql[:300],
)

qm = OUT / "qlmanage.log"
qmt = qm.read_text() if qm.exists() else ""
check("qlmanage.log present", qm.exists())
check(
    "qlmanage log has no errors",
    not re.search(r"error|failed|invalid|cannot|traceback", qmt, re.I),
    qmt[:500],
)

# Quick Look must have rendered the document, not merely registered: the
# extension logs "preview applied: rendered N of M blocks" for each preview.
# The smoke file ends as plan-v2.md (34 blocks).
qr = OUT / "ql-render.log"
qrt = qr.read_text() if qr.exists() else ""
check("ql-render.log present", qr.exists())
m = re.search(r"preview (applied|timed out): rendered (-?\d+) of (\d+) blocks", qrt)
check("quicklook preview rendered", bool(m), qrt[-500:])
if m:
    check("quicklook preview applied (not timed out)", m.group(1) == "applied", m.group(0))
    check("quicklook rendered == 34 blocks", m.group(2) == "34" and m.group(3) == "34", m.group(0))

print(f"{len(failures)} failing assertion(s)")
sys.exit(1 if failures else 0)
