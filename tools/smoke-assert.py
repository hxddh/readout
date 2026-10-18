#!/usr/bin/env python3
"""Asserts on signed-product smoke output. Any failed assertion exits nonzero.

Reads smoke-out/*.json plus smoke-out.log, the pluginkit listing and the
qlmanage log. CI prints the actual values first (see the `1-initial:` /
`2-after-edit:` / `4-dark:` lines in the log), then checks the hard
thresholds below. Thresholds were taken from those printed values for
web/test/fixtures/plan.md -> plan-v2.md and must NOT be edited to make a
run pass — a mismatch means the product regressed.
"""
import html
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


# 3.7: the fixtures gained two paragraphs (Chinese emphasis and quotes, a
# Japanese line) for the typesetting shots: 33/34 blocks became 35/36.
initial = load("1-initial.json")
print(f"1-initial: {initial}")
check("1-initial blocks == 35", initial.get("blocks") == 35, initial)
check("1-initial highlighted >= 2", (initial.get("highlighted") or 0) >= 2, initial)
check("1-initial math >= 3", (initial.get("math") or 0) >= 3, initial)
# Task E4: tools/smoke-run.py replaced the file 50ms after the app opened it;
# the first capture must already show the replacement, not the stale content.
check("1-initial early edit applied", initial.get("early") is True, initial)

edit = load("2-after-edit.json")
print(f"2-after-edit: {edit}")
check("2-after-edit blocks == 36", edit.get("blocks") == 36, edit)
check("2-after-edit marks == 4", edit.get("marks") == 4, edit)
check("2-after-edit deletions == 1", edit.get("deletions") == 1, edit)
shift = edit.get("anchorShift")
check(
    "2-after-edit |anchorShift| <= 2",
    isinstance(shift, (int, float)) and abs(shift) <= 2,
    f"anchorShift={shift}",
)
check("2-after-edit mermaid >= 1", (edit.get("mermaid") or 0) >= 1, edit)

edit_applies = load("edit.json")
print(f"edit: {edit_applies}")
# The watcher reports a write at once and folds the events after it: one write, one patch.
check("one agent write applies exactly one patch", edit_applies.get("applies") == 1, edit_applies)

refill = load("refill.json")
print(f"refill: {refill}")
# Emptied and written back a second later: the empty version and the refill both shown...
check("refill: the emptied file and its refill were both applied", (refill.get("applies") or 0) >= 2, refill)
# ...and the reader is back where they were.
rshift = refill.get("shift")
check("refill: the reading position is restored (|shift| <= 4)",
      isinstance(rshift, (int, float)) and abs(rshift) <= 4, refill)
# A heading's link button copies the full path with the anchor.
prefix = refill.get("link_prefix") or "?"
copied = refill.get("copied_link") or ""
check("copy link to section copies the full path#anchor",
      prefix.startswith("/") and copied.startswith(prefix) and len(copied) > len(prefix), refill)

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
check("agent folder: the document being read stays in front",
      agent.get("reading_before") not in (None, "", "notes.md") and agent.get("reading_after") == agent.get("reading_before"), agent)

late = load("late-folder.json")
print(f"late-folder: {late}")
# An agent folder created after launch is watched without Readout becoming active.
check("late folder: a document written into a folder created later opens on its own",
      late.get("auto_opened") == ["late.md"], late)
check("late folder: Readout was not activated", late.get("active_after") is False, late)
# A missing folder is watched through the nearest folder above it that exists
# (kqueue), not polled every 2 s for as long as it is missing (3.4).
mw = late.get("missing_watch") or {}
missing, watched = mw.get("missing") or [], mw.get("watched") or []
check("late folder: the missing folder is watched through the folder above it",
      len(missing) == 1 and missing[0].endswith("/late/plans") and len(watched) == 1
      and missing[0].startswith(watched[0].rstrip("/") + "/") and not watched[0].endswith("/late"), late)
check("late folder: nothing polls for it", mw.get("polling") is False, late)
check("late folder: once it exists nothing is watched for it",
      (late.get("missing_watch_after") or {}).get("watched") == [], late)
# A folder added (or appearing, as the global shortcut finds it) is scanned:
# meanwhile the latest file known stays, so the shortcut never finds nothing.
rescan = late.get("rescan") or {}
check("rescan: the latest file stays known while a new folder is scanned",
      rescan.get("latest_during") not in (None, ""), late)
check("rescan: the scan lands", rescan.get("latest_after") not in (None, "", "(no scan)"), late)

live = load("live-updates.json")
print(f"live-updates: {live}")
# FSEvents reports /private/tmp/...: a file opened as /tmp/... must still update.
check("tmp: the file under /tmp was shown", (live.get("tmp") or {}).get("before") == "TMP-BEFORE", live)
check("tmp: the file under /tmp updated live", (live.get("tmp") or {}).get("after") == "TMP-AFTER", live)
# latest.md -> run-41.md, then `ln -sf run-42.md latest.md`: the window follows the link.
check("link: the symlink's target was shown", (live.get("link") or {}).get("before") == "RUN-41", live)
check("link: the retargeted symlink was followed", (live.get("link") or {}).get("after") == "RUN-42", live)
# The window is keyed by what it shows: reopening the link finds it, opening run-41.md would not.
check("link: the window is found through the retargeted link", (live.get("link") or {}).get("found_through_link") is True, live)
check("link: the old target no longer maps to that window", (live.get("link") or {}).get("old_target_free") is True, live)

check("link: the retargeted link's reading state is saved with its record",
      (live.get("link") or {}).get("record_at_new_target") is True, live)
leg = live.get("legacy") or {}
check("legacy: a pre-3.3 record is read", leg.get("loaded") is True, live)
check("legacy: it is moved under the real-path key", leg.get("moved") is True and leg.get("old_removed") is True, live)
check("legacy: a copy that fails keeps the old record", leg.get("kept_on_failure") is True, live)
check("legacy: the newer reading position moves with the record",
      leg.get("position_kept") is True and leg.get("old_position_removed") is True, live)
# Saving between the retarget and the new file's read must not store the old file's state under the new key.
check("link: no record under the new key before its content is read",
      (live.get("link") or {}).get("early_record") is not True, live)

chrome = (live.get("tmp") or {}).get("chrome") or {}
# Same-named files are told apart: the tab shows the document's title, the
# window title stays the file name, the tab's tooltip shows where it is.
check("chrome: the window title is the file name", chrome.get("title") == "live.md", live)
check("chrome: the tab title is the document title", chrome.get("tab_title") == "TMP-AFTER", live)
# The subtitle shows status or task progress (live.md has neither); else the
# folder only for a window without a tab bar, whose tab tooltip never shows
# (System Settings "Prefer tabs: In Full Screen", the default, opens windows).
check("chrome: the subtitle names the folder only without a tab bar",
      chrome.get("subtitle") == ("" if chrome.get("tab_bar_visible") else chrome.get("folder")), live)
tip, path = chrome.get("tab_tooltip") or "", chrome.get("path") or ""
check("chrome: the tab tooltip is the file's path", bool(tip) and (tip == path or path.endswith(tip.lstrip("~"))), live)
# The toolbar: sidebar, next change, find; no text-width item (View ▸ Wide Text stays).
check("chrome: no text-width toolbar item", "readout.width" not in (chrome.get("toolbar") or []), live)
check("chrome: the next-change item and find field are in the toolbar",
      {"readout.nextChange", "readout.search"} <= set(chrome.get("toolbar") or []), live)
check("chrome: the find field is 160 pt wide", chrome.get("search_width") == 160, live)
# ...as drawn too: macOS 26 grew it into the free toolbar space (3.5: ~325 pt).
check("chrome: the find field is drawn no wider than 160 pt",
      0 < (chrome.get("search_field_width") or -1) <= 160.5, live)
# New windows follow System Settings "Prefer tabs".
check("chrome: windows tab as System Settings says", chrome.get("tabbing_automatic") is True, live)
item = chrome.get("change_item") or {}
# The next-change button shows only with something unread (hidden, nothing reflows: find stays right).
unread_now = (chrome.get("unread") or 0) > 0
check("chrome: the next-change button shows only with something unread",
      item.get("present") is True and item.get("hidden") is (not unread_now)
      and item.get("enabled") == unread_now, live)

unreadable = live.get("unreadable") or {}
# A failed first read says why in the title bar, not only in the (maybe hidden) sidebar.
check("unreadable: the status is set", bool(unreadable.get("status")), live)
check("unreadable: the subtitle shows the status",
      bool(unreadable.get("status")) and unreadable.get("subtitle") == unreadable.get("status"), live)
# ...and the page says it too, in its empty state, instead of staying blank.
check("unreadable: the page shows the status in its empty state",
      bool(unreadable.get("status")) and unreadable.get("page_empty_text") == unreadable.get("status"), live)
uitem = unreadable.get("change_item") or {}
# Nothing unread: the next-change button is hidden (3.4 kept it, disabled, so the
# width item beside it would not move; that item is gone, so nothing reflows now).
check("chrome: with nothing unread the next-change button is hidden",
      unreadable.get("unread") == 0 and uitem.get("present") is True
      and uitem.get("hidden") is True and uitem.get("enabled") is False, live)

dangle = live.get("dangle") or {}
# `ln -sf` to a file written only afterwards: the window follows it once it exists.
check("dangle: the link's first target was shown", dangle.get("before") == "RUN-45", live)
check("dangle: the file written after the link is shown", dangle.get("after") == "RUN-46", live)
check("dangle: no stale status once it exists", dangle.get("status") == "", live)
check("dangle: opening the link again finds the same window", dangle.get("same_window") is True, live)
check("dangle: reading state is saved again (gate released)", dangle.get("record_at_new_target") is True, live)

undo = load("undo.json")
print(f"undo: {undo}")
# ⌘K is undoable: Edit ▸ Undo Mark All as Read brings the marks back (to what
# reopening the window shows: marks read since the last catch-up come back too).
check("undo: there were marks to mark read", (undo.get("unread_before") or 0) > 0, undo)
check("undo: ⌘K marked everything read", undo.get("unread_after_mark") == 0, undo)
check("undo: the Undo item names it and is enabled",
      undo.get("undo_title") == "Undo Mark All as Read" and undo.get("undo_enabled") is True, undo)
check("undo: undoing brings the marks back",
      (undo.get("unread_after_undo") or 0) >= (undo.get("unread_before") or 1)
      and (undo.get("page_marks_after_undo") or 0) > 0, undo)
check("undo: it can be redone", undo.get("redo_title") == "Redo Mark All as Read", undo)

nav = load("navigation.json")
print(f"navigation: {nav}")
# A readout: URL other than the reader page (a relative link opened in the web
# view) is not loaded: the document stays (3.4 showed a blank window).
check("navigation: the reader page stays", (nav.get("href") or "").startswith("readout://app/reader.html"), nav)
check("navigation: the document stays", (nav.get("blocks_after") or 0) > 0 and nav.get("blocks_after") == nav.get("blocks_before"), nav)
# The app's script reports the link a context menu opens on, resolved.
check("navigation: the context menu's link is known",
      nav.get("context_link_web") == "https://example.com/readout"
      and (nav.get("context_link_relative") or "").startswith("readout://app/"), nav)
# A relative link (readout://app/...): no link items (they navigated the web view or copied readout:// URLs).
check("navigation: no link items for a link into the page",
      nav.get("context_menu") == ["WKMenuItemIdentifierCopy", "-", "WKMenuItemIdentifierLookUp"], nav)
# A web link can still be copied; opening it stays a click.
check("navigation: a web link can be copied",
      nav.get("context_menu_web") == ["WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink", "-",
                                      "WKMenuItemIdentifierCopy", "-", "WKMenuItemIdentifierLookUp"], nav)

find = load("find-mode.json")
print(f"find-mode: {find}")
# Return in the find field must not switch find mode (a full re-layout) off and on again.
check("find mode switches on once and off once", find.get("calls") == [True, False], find)
check("find mode in a cold window is delivered once its page is up",
      find.get("cold_calls") == [True] and find.get("cold_ready") == [True], find)

col = live.get("collide") or {}
# Retargeted onto a file another window shows: that window keeps the path; the link's window stays owned.
check("collide: the link followed its new target", col.get("before") == "RUN-43" and col.get("after") == "RUN-44", live)
check("collide: the window already showing the target keeps its path", col.get("target_window_kept") is True, live)
check("collide: the link's window is still owned (saved on quit)", col.get("owned") is True, live)

bg = load("background-opens.json")
print(f"background-opens: {bg}")
# `readout -b` and `readout --hook` open behind the tab being read, never in front of it.
check("cli: every open arrived as a background request",
      sorted(bg.get("requests") or []) == sorted(["background.md", "plan.md", "hooked.md", "hooked.md"]), bg)
# A plan outside its project: the hook's cwd is where its code references resolve (U2).
hr = bg.get("hook_root") or {}
check("cli: the hook's project folder resolves the plan's code reference",
      (hr.get("resolved") or "").endswith("/project/src/app/feature.swift"), bg)
check("cli: the project folder is kept for the next launch", (hr.get("kept") or "").endswith("/project"), bg)
check("cli: rendering the plan again for its folder marks nothing", hr.get("marks") == 0, bg)
check("cli: readout -b opened the file", bg.get("opened") is True, bg)
bgc = bg.get("chrome") or {}
# readout -b adds a tab: with the tab bar showing, no folder in the subtitle (3.5 rule).
check("cli: the background tab shows a tab bar and no folder subtitle",
      bgc.get("tab_bar_visible") is True and bgc.get("subtitle") == "", bg)
# Open Recent lists documents that were in front, not every file opened behind.
check("cli: a document opened in the background is not in Open Recent", bg.get("in_recents") is False, bg)
check("cli: the document being read stays in front",
      bg.get("reading_before") not in (None, "", "background.md", "plan.md", "hooked.md") and bg.get("reading_after") == bg.get("reading_before"), bg)

# Where the unread changes are (U6): dots on the outline's sections and on the tab.
check("outline: sections with unread changes are marked",
      0 < len(undo.get("outline_unread") or []) < (undo.get("outline_entries") or 0), undo)
td = load("tab-dot.json")
print(f"tab-dot: {td}")
check("tabs: a tab behind with unread changes shows the dot",
      td.get("tab_bar_visible") is True and (td.get("behind_unread") or 0) > 0 and td.get("behind_dot") is True, td)
check("tabs: its outline marks the section added", td.get("behind_outline_unread") == ["Added later"], td)
# A tab opened behind and never looked at has the dot too (U10): the window in
# front may never have been key on the CI runner, which cannot activate Readout.
check("tabs: the tab in front has the dot exactly when it has unread changes or was never looked at",
      td.get("front_dot") == ((td.get("front_unread") or 0) > 0 or td.get("front_noted_recent") is False), td)
ht = bg.get("hook_tab") or {}
check("tabs: a tab opened behind, never looked at, shows the dot with nothing unread",
      ht.get("unread") == 0 and ht.get("noted_recent") is False and ht.get("dot") is True, bg)
# The tab bar moves the toolbar's edge without a resize: the inset follows it (A2).
tdi = td.get("inset") or {}
check("tabs: with the tab bar showing, the page's top inset is the toolbar's edge",
      (tdi.get("layout_gap") or 0) > 0 and tdi.get("obscured_top") == tdi.get("layout_gap"), td)
# Two documents titled alike in one tab group: their tabs name the files (A7).
check("tabs: documents with the same title name their files",
      td.get("dup_in_group") is True and sorted(td.get("dup_titles") or []) == ["Same plan — fix.md", "Same plan — refactor.md"], td)

menus = load("menus.json")
print(f"menus: {menus}")
edit_menu = menus.get("edit_menu") or []
for entry in ["undo: z", "redo: z", "cut: x", "paste: v", "delete:"]:
    check(f"edit menu has {entry}", entry in edit_menu, edit_menu)


def menu_items(items, path=()):
    for i in items:
        if i.get("separator"):
            continue
        yield path + (i.get("title"),), i
        yield from menu_items(i.get("items") or [], path + (i.get("title"),))


tree = list(menu_items(menus.get("menus") or []))
check("menus.json has the whole menu bar", len(tree) > 40, len(tree))
by_action = {i.get("action"): i for _, i in tree if i.get("action")}
close_all = by_action.get("closeAll:") or {}
check("File has Close All as the ⌥⌘W alternate of Close",
      close_all.get("key") == "⌥⌘w" and close_all.get("alternate") is True, close_all)
use_sel = by_action.get("useSelectionForFind:") or {}
check("Find has Use Selection for Find, without ⌘E", bool(use_sel) and "key" not in use_sel, use_sel)
check("⌘E stays Open in Editor", (by_action.get("openInEditor:") or {}).get("key") == "⌘e", by_action.get("openInEditor:"))
check("Edit has Speech: Start and Stop Speaking",
      "startSpeaking:" in by_action and "stopSpeaking:" in by_action, sorted(by_action))
what = by_action.get("showWhatChanged:") or {}
check("View has Show What Changed, without a key", bool(what) and "key" not in what, what)
check("Help opens the bundled shortcuts", "openHelp:" in by_action, sorted(by_action))

aux = load("aux-windows.json")
print(f"aux-windows: {aux}")
check("settings: never a tab", aux.get("settings_tabbing_disallowed") is True, aux)
check("welcome: never a tab, no minimize or zoom button",
      aux.get("welcome_tabbing_disallowed") is True and aux.get("welcome_minimize_hidden") is True
      and aux.get("welcome_zoom_hidden") is True, aux)
check("welcome: named, and not listed twice in the Window menu",
      bool(aux.get("welcome_title")) and aux.get("welcome_in_window_menu") is False, aux)

for name in ["window-light.png", "window-dark.png", "cjk-light.png"]:
    check(f"{name} captured", (OUT / name).exists() and (OUT / name).stat().st_size > 10000)

# The Chinese pass (-AppleLanguages '(zh-Hans)'): no menu title left in English.
# Latin text that is not English: the app's name, product names, file names;
# the Services submenu is filled by other apps.
LATIN_OK = re.compile(r"Readout|Agent|Markdown|GitHub|[\w.-]+\.md\b|[⌃⌥⇧⌘]+\S*")
zh = load("menus-zh.json")
zh_tree = list(menu_items(zh.get("menus") or []))
check("menus-zh.json has the whole menu bar", len(zh_tree) > 40, len(zh_tree))
english = [" ▸ ".join(path) for path, i in zh_tree
           if "服务" not in path[:-1] and i.get("action") != "makeKeyAndOrderFront:"
           and re.search(r"[A-Za-z]", LATIN_OK.sub("", i.get("title") or ""))]
check("zh-Hans: no English menu titles", not english, english)
check("zh-Hans: Settings and welcome captured",
      all((OUT / f).exists() for f in ["5-settings-zh.screen.png", "6-welcome-zh.screen.png"]))
zlog = OUT / "smoke-zh.log"
check("zh-Hans pass: no page errors", zlog.exists() and "Readout page error" not in zlog.read_text())

# Typesetting this WebKit supports (T6): reported, not asserted.
print(f"css-supports: {load('css-supports.json')}")

# The soft scroll edge under the toolbar (A1): the web view asks WebKit for the
# automatic content-inset fill, so its top scroll pocket is made with the
# automatic style (0; WebKit's default is the hard style), with no capture colour
# and no preference for a solid hard pocket. On main the fill is off.
edge = load("scroll-edge.json")
print(f"scroll-edge: {edge}")
check("scroll edge: the automatic content-inset fill is on",
      edge.get("fill_settable") is True and edge.get("automatic_fill") is True, edge)
props = (edge.get("pocket") or {}).get("properties") or {}
check("scroll edge: the top scroll pocket has the automatic style, no capture colour, no solid hard pocket",
      props.get("style") == "0" and props.get("captureColor") == "nil" and props.get("prefersSolidColorHardPocket") == "0", edge.get("pocket"))
# What it looks like: rows of a window shot just above the toolbar's edge with a
# dark code block 10 pt under it. A hard pocket paints them one flat colour (sd 0);
# the soft edge lets the block show through. Reported, not asserted: the runner's
# window is never key (Readout cannot be activated there) and its rows stay flat
# with the pocket configured as above; the look is checked on a Mac.
band = [r for r in edge.get("rows") or [] if -8 <= r.get("rel", 99) <= -1]
flat = bool(band) and all(r["sd"] < 0.5 for r in band) and max(r["mean"] for r in band) - min(r["mean"] for r in band) < 1
print(f"scroll edge band (key window: {edge.get('window_key')}): {'flat (hard)' if flat else 'not flat (soft)'} {band}")

landed = load("landed.json")
print(f"landed: {landed}")

credits = OUT / "Credits.html"
sys.path.insert(0, str(ROOT / "tools"))
from credits import production_packages  # noqa: E402
text = credits.read_text() if credits.exists() else ""
absent = [n for n in production_packages() if html.escape(n) not in text]
check("Credits.html in the app names every production dependency", credits.exists() and not absent, absent[:20])

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
    check("quicklook rendered == 36 blocks", m.group(2) == "36" and m.group(3) == "36", m.group(0))
# The preview is asked for, then applied: both logged (ql_open_ms comes from the second).
check("quicklook logs the request", "preview requested" in qrt, qrt[-500:])

tm = load("timings.json")
# Readout's own share of a warm open is part of it, and measured for every open.
check("warm open: Readout's share is measured and within the whole open",
      isinstance(tm.get("warm_open_to_applied_ms"), (int, float)) and isinstance(tm.get("warm_open_ms"), (int, float))
      and tm["warm_open_to_applied_ms"] <= tm["warm_open_ms"], tm)

print(f"{len(failures)} failing assertion(s)")
sys.exit(1 if failures else 0)
