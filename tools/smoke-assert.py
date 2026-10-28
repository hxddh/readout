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


# 3.7: the fixtures gained two paragraphs (Chinese emphasis and quotes, a
# Japanese line) for the typesetting shots: 33/34 blocks became 35/36.
# The spare page warms its grammars up in its own WebContent process, never the window's.
procs = load("processes.json")
check("the spare page runs in a web process of its own", procs.get("window_pid", -1) > 0 and procs.get("spare_pid", -1) > 0 and procs["window_pid"] != procs["spare_pid"], procs)

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
# Emptied and written back at once, byte for byte: the empty read is read
# again and, the same bytes as shown, changes nothing (DocumentLoader); the
# page ends showing all of it, at the reader's place, without the empty notice.
fast = load("refill-fast.json")
print(f"refill-fast: {fast}")
check("refill-fast: the whole document is shown after an immediate identical rewrite",
      fast.get("blocks") is not None and fast.get("blocks") == fast.get("blocksBefore") and fast.get("emptyNotice") is False, fast)
fshift = fast.get("shift")
check("refill-fast: the reading position is kept (|shift| <= 4)", isinstance(fshift, (int, float)) and abs(fshift) <= 4, fast)
rshift = refill.get("shift")
check("refill: the reading position is restored (|shift| <= 4)",
      isinstance(rshift, (int, float)) and abs(rshift) <= 4, refill)
# A heading's context menu copies the full path with the anchor (3.9 E9:
# no hover § button; a paragraph's menu has no such item).
prefix = refill.get("link_prefix") or "?"
copied = refill.get("copied_link") or ""
check("copy link to section copies the full path#anchor",
      prefix.startswith("/") and copied.startswith(prefix) and len(copied) > len(prefix), refill)
check("copy link to section is in a heading's context menu only, no hover button",
      refill.get("section_link_on_paragraph") is False and refill.get("hover_link_buttons") == 0, refill)

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
old = live.get("old_format") or {}
check("old format: a record saved before 3.6 is ignored, its position too", old.get("ignored") is True, live)
check("old format: a current record and its newer position load", old.get("current_loads") is True, live)
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
# Tab reaches links, as it reaches paths in code spans (U6, 3.8).
check("navigation: Tab reaches links", nav.get("tab_focuses_links") is True, nav)
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

find = load("find.json")
print(f"find: {find}")
# The page finds (3.9): Return selects a match and the field says which of how many; Return again goes on.
first = re.fullmatch(r"(\d+) of (\d+)", find.get("first") or "")
second = re.fullmatch(r"(\d+) of (\d+)", find.get("second") or "")
check("find: Return lands on a match, the field showing which of how many",
      first is not None and 1 <= int(first[1]) <= int(first[2]), find)
check("find: the match is selected (Copy, Copy as Quote)",
      (find.get("selected") or "").lower() == (find.get("word") or "").lower() != "", find)
check("find: Return again goes on to the next match",
      second is not None and first is not None and second[2] == first[2]
      and (int(second[1]) == int(first[1]) % int(first[2]) + 1), find)
check("find: Escape takes the marks and the count away",
      find.get("after_escape") == "" and find.get("marks_after_escape") == 0, find)
check("find: a search cleared before the document was in the page never runs", find.get("cold_cleared") == "", find)
check("find: a window whose document was not in its page yet finds once it is", find.get("cold") == "1 of 1", find)

col = live.get("collide") or {}
# Retargeted onto a file another window shows: that window keeps the path; the link's window stays owned.
check("collide: the link followed its new target", col.get("before") == "RUN-43" and col.get("after") == "RUN-44", live)
check("collide: the window already showing the target keeps its path", col.get("target_window_kept") is True, live)
check("collide: the link's window is still owned (saved on quit)", col.get("owned") is True, live)

bg = load("background-opens.json")
print(f"background-opens: {bg}")
# `readout -b` and `readout --hook` open behind the tab being read, never in front of it.
check("cli: every open arrived as a background request",
      sorted(bg.get("requests") or []) == sorted(["background.md", "plan.md", "hooked.md", "hooked.md", "cursor.md"]), bg)
# Cursor's afterFileEdit hook (top-level file_path, workspace_roots; U7, 3.8): opened, the workspace as its project.
bcur = bg.get("cursor") or {}
check("cli: Cursor's hook opens the file, its first workspace root as the project",
      bcur.get("opened") is True and (bcur.get("root") or "").endswith("/project"), bg)
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
# Two documents titled alike in one tab group: their tabs name the files (A7),
# first, where a narrow tab does not truncate them (U5, 3.8).
check("tabs: documents with the same title name their files, first",
      td.get("dup_in_group") is True and sorted(td.get("dup_titles") or []) == ["fix.md — Same plan", "refactor.md — Same plan"], td)

# A plan outside its project (3.7): the subtitle names the project, the tab's tooltip its folder.
hc = bg.get("hook_chrome") or {}
check("plans know their project: subtitle and tooltip name it",
      hc.get("subtitle") == "project" and "/project" in (hc.get("tab_tooltip") or "") and "\n" in (hc.get("tab_tooltip") or ""), hc)

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
latest = by_action.get("openLatest:") or {}
check("File ▸ Open Latest Agent File has ⌃⌥⌘R, and nothing has ⇧⌘O (S3, 3.9)",
      latest.get("key") == "⌃⌥⌘r" and not any((i.get("key") or "").lower() == "⇧⌘o" for _, i in tree), latest)
close_all = by_action.get("closeAll:") or {}
check("File has Close All as the ⌥⌘W alternate of Close",
      close_all.get("key") == "⌥⌘w" and close_all.get("alternate") is True, close_all)
# 3.9 (S8, S9): no Use Selection for Find, no Window ▸ Welcome, and none of
# what macOS adds to an Edit menu (AutoFill, Start Dictation, Emoji & Symbols).
check("Find has no Use Selection for Find; Window has no Welcome",
      "useSelectionForFind:" not in by_action and "showWelcome:" not in by_action, sorted(by_action))
added = [" ▸ ".join(path) for path, i in tree if path[0] == "Edit"
         and (i.get("action") in ("startDictation:", "orderFrontCharacterPalette:") or (i.get("action") or "").startswith("_handleInsertFrom"))]
check("Edit has no AutoFill, Start Dictation or Emoji & Symbols", not added, added)
edit_top = [i for i in next((m.get("items") or [] for m in menus.get("menus") or [] if m.get("title") == "Edit"), [])]
check("Edit ends with Speech, no separator left over",
      bool(edit_top) and edit_top[-1].get("title") == "Speech", [i.get("title") or "-" for i in edit_top])
check("⌘E stays Open in Editor", (by_action.get("openInEditor:") or {}).get("key") == "⌘e", by_action.get("openInEditor:"))
check("Edit has Speech: Start and Stop Speaking",
      "startSpeaking:" in by_action and "stopSpeaking:" in by_action, sorted(by_action))
quote = by_action.get("copyAsQuote:") or {}
check("Edit has Copy as Quote on ⇧⌘C, and no other item has that key",
      quote.get("key") == "⇧⌘c" and sum(1 for _, i in tree if (i.get("key") or "").lower() == "⇧⌘c") == 1, quote)
what = by_action.get("showWhatChanged:") or {}
check("View has Show What Changed, without a key", bool(what) and "key" not in what, what)
compare = next((i for path, i in tree if i.get("action") == "compareWithLastCommit:" and path[0] == "View"), {})
check("View has Compare with Last Commit, without a key", compare.get("title") == "Compare with Last Commit" and "key" not in compare, compare)
check("Help opens the bundled shortcuts", "openHelp:" in by_action, sorted(by_action))
# 3.9 S1: Show Only Changes is gone, and ⇧⌘K with it.
check("View has no Show Only Changes, and nothing is on ⇧⌘K",
      "toggleChangesOnly:" not in by_action and not any((i.get("key") or "").lower() == "⇧⌘k" for _, i in tree), sorted(by_action))

aux = load("aux-windows.json")
print(f"aux-windows: {aux}")
check("settings: never a tab", aux.get("settings_tabbing_disallowed") is True, aux)
check("welcome: never a tab, no minimize or zoom button",
      aux.get("welcome_tabbing_disallowed") is True and aux.get("welcome_minimize_hidden") is True
      and aux.get("welcome_zoom_hidden") is True, aux)
check("welcome: named, and not listed in the Window menu",
      bool(aux.get("welcome_title")) and aux.get("welcome_in_window_menu") is False, aux)
check("Open Latest Agent File with nothing written: the welcome window, no alert (S2)",
      aux.get("open_latest_none_welcome") is True and aux.get("open_latest_none_modal") is False, aux)
check("About: Acknowledgements.md is in the app", aux.get("acknowledgements_bundled") is True, aux)

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

# 3.8 T3: a Chinese block draws “ ” ‘ ’ — … in PingFang (reader.css's
# ro-zh-punct face, local("PingFangSC-Regular")), not in the system font's
# narrow Latin forms: the face loads in WKWebView, and the six characters
# are as wide in the block as in PingFang SC and not as in the system font.
punct = load("zh-punct.json")
print(f"zh-punct: {punct}")
pw = punct.get("width") or {}
regular = [f for f in punct.get("faces") or [] if str(f.get("weight", "")).startswith("1 ")]
check("zh punctuation: a Chinese block uses the ro-zh-punct face first",
      punct.get("found") is True and str(punct.get("family", "")).replace('"', "").startswith("ro-zh-punct,"), punct)
check("zh punctuation: local() PingFang loads in WKWebView",
      len(regular) == 1 and regular[0].get("status") == "loaded" and punct.get("check") is True, punct)
check("zh punctuation: drawn in PingFang SC, not the system font",
      all(isinstance(pw.get(k), (int, float)) for k in ("block", "pingfang", "system"))
      and abs(pw["block"] - pw["pingfang"]) < 0.5 and abs(pw["block"] - pw["system"]) >= 0.5, pw)

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
# A/B (A1): a second shot at the same scroll position with the fill flag off.
# Whether the pixels differ is reported, not asserted (the runner's window is
# never key); that the comparison ran, with the flag off and back on, is.
ab = edge.get("ab") or {}
print(f"scroll edge A/B (flag on vs off): identical={ab.get('identical')} window={ab.get('window')} band={ab.get('band')}")
check("scroll edge A/B: shot with the fill flag off and compared, the flag on again",
      isinstance(ab.get("identical"), bool) and ab.get("automatic_fill_off") is False and ab.get("automatic_fill_restored") is True
      and isinstance((ab.get("band") or {}).get("differing_pixels"), int), ab)

landed = load("landed.json")
print(f"landed: {landed}")
# Next Change: focus lands on a change and the page says which one, for VoiceOver (U16).
first = (landed.get("landed") or [{}])[0]
check("next change: where it landed is reported (n of m, kind)",
      1 <= (first.get("index") or 0) <= (first.get("total") or 0) == landed.get("unread")
      and first.get("kind") in ("railAdded", "railEdited", "railRemoved", "railTask"), landed)

# Copy as Quote (3.7): the selected blocks' Markdown as a blockquote, then
# the file's lines and section; enabled only while text is selected.
cq = load("copy-quote.json")
print(f"copy-quote: {cq}")
cq_lines = (cq.get("text") or "").split("\n")
check("Copy as Quote: enabled with a selection, not without",
      cq.get("enabled") is True and cq.get("enabled_after_deselect") is False, cq)
check("Copy as Quote: a blockquote of the blocks, then '— <path>#L<a>-L<b> (§ <section>)'",
      len(cq_lines) >= 3 and all(l.startswith(">") for l in cq_lines[:-1])
      and re.fullmatch(re.escape("— " + (cq.get("path") or "?")) + r"#L(\d+)-L(\d+) \(§ .+\)", cq_lines[-1]) is not None, cq)
# No text selected, the keyboard on a block (where N lands; U4, 3.8): enabled, and that block is quoted.
cqf = (cq.get("focused_text") or "").split("\n")
check("Copy as Quote: with no text selected, the block with the keyboard's focus",
      cq.get("focused_slot") is not None and cq.get("enabled_focused") is True and len(cqf) >= 2
      and all(l.startswith(">") for l in cqf[:-1])
      and re.fullmatch(re.escape("— " + (cq.get("path") or "?")) + r"#L(\d+)(-L\d+)?( \(§ .+\))?", cqf[-1]) is not None, cq)

# ⌘C (3.8): Markdown as plain text, clean HTML as rich text.
cm = load("copy-markdown.json")
print(f"copy-markdown: {cm}")
cm_text = cm.get("text") or ""
check("Copy (⌘C): the task items' Markdown as plain text",
      cm.get("sent") is True and re.match(r"^- \[[ x]\] .+\n- \[[ x]\] ", cm_text) is not None, cm)
check("Select All then Copy: the document's Markdown, from its front matter",
      cm.get("select_all_sent") is True and (cm.get("select_all_text") or "").startswith("---\ntitle: "), cm)
check("Copy (⌘C): clean HTML as rich text (no page controls or state)",
      "<li" in (cm.get("html") or "") and not re.search(r"data-slot|tabindex|<button|class=", cm.get("html") or ""), cm)

# N on to the next document with unread changes (3.7): the tab behind with
# unread changes comes forward at its first change; with none left anywhere
# N stays (a beep). The Dock badge counts the documents showing unread changes.
cd = load("cross-document.json")
print(f"cross-document: {cd}")
# A document opened behind and not looked at yet waits as one with unread
# changes does (U2, 3.8): N goes on to it as it shows (no first change), and
# the Dock badge counts the tabs' dots. The CI window is never key: nothing was looked at.
cu = cd.get("unseen") or {}
check("cross-document N: goes on to a document not looked at yet, as it shows",
      cu.get("to") not in (None, "", cd.get("unseen_from")) and cu.get("unread") == 0 and cu.get("looked_at") is False
      and cu.get("landed") == [] and (cu.get("notice") or "").startswith("Next unread: ")
      and "Next unread" not in (cu.get("subtitle") or ""), cd)
check("Dock badge: the documents whose tabs show the dot (unread, or not looked at yet)",
      cd.get("badge_before") == str(cd.get("attention_before")) and (cd.get("attention_before") or 0) > (cd.get("showing_unread_before") or 0), cd)
check("Dock badge: once every document was looked at, those with unread changes",
      cd.get("badge_looked_at") == (str(cd["showing_unread_looked_at"]) if cd.get("showing_unread_looked_at") else ""), cd)
check("cross-document N: goes on to the tab with unread changes, at its first change",
      cd.get("to") == "background.md" and cd.get("from") != cd.get("to") and (cd.get("to_had_unread") or 0) > 0
      and len(cd.get("landed") or []) >= 1 and (cd["landed"][0].get("index") == 1), cd)
# Passing messages are the page's notice; the subtitle keeps lasting state (E6, 3.9).
check("cross-document N: says where it went in the notice, not the subtitle",
      "Opened with readout -b" in (cd.get("to_notice") or "") and "Next unread" not in (cd.get("to_subtitle") or ""), cd)
check("cross-document N: nowhere to go once nothing is unread anywhere", cd.get("went_with_none_left") is False, cd)
check("Dock badge: the number of documents showing unread changes once all were looked at, none at 0",
      (cd.get("showing_unread_before") or 0) >= 1
      and cd.get("badge_after_read") == (str(cd["showing_unread_after_read"]) if cd.get("showing_unread_after_read") else "")
      and cd.get("badge_none") == "", cd)

# Window restoration (3.7): what a reader window keeps for the next launch
# comes back as it was (relaunching is checked on a Mac); a gone file does not.
rs = load("restoration.json")
print(f"restoration: {rs}")
rm = rs.get("main") or {}
rh = rs.get("hooked") or {}
check("restoration: the file and the project come back from the encoded state",
      rm.get("path") and rm.get("path") == rm.get("expected_path")
      and rh.get("path") == rh.get("expected_path") and rh.get("root") and rh.get("root") == rh.get("expected_root"), rs)
check("restoration: a window whose file is gone does not come back", rs.get("gone_restored") is False, rs)
check("restoration: reader windows are restorable, each with its own identifier, none holding the frame name",
      rs.get("restorable") is True and rs.get("identifiers_unique") is True and rs.get("frame_autosave_names") == [], rs)
check("restoration: Welcome and Settings are not restorable",
      not {"Welcome", "Settings"} & set(rs.get("others_restorable") or []), rs)
# Two tabs restored through ReaderRestoration as at launch (U1, a 3.7
# regression): looked at before the quit, the tab not in front has no dot and
# is not "waiting" for Open Latest Agent File, and keeps that for the next launch.
rt = load("restored-tabs.json")
print(f"restored-tabs: {rt}")
rtt = rt.get("tabs") or []
check("restoration: a two-tab group comes back as one window, the selected tab in front",
      rt.get("restored") == 2 and rt.get("same_group") is True and rt.get("selected_first") is True, rt)
check("restoration: restored tabs looked at before come back without the dot",
      len(rtt) == 2 and all(t.get("dot") is False and t.get("waiting") is False and t.get("looked_at") is True
                            and t.get("seen_kept") is True for t in rtt) and rtt[1].get("key") is False, rt)

# First open marked against the last commit (3.7).
gb = load("git-baseline.json")
print(f"git-baseline: {gb}")
def page(name):
    try:
        return json.loads((gb.get(name) or {}).get("page") or "{}")
    except ValueError:
        return {}
gt, gu = page("tracked"), page("untracked")
check("git: a committed file changed since is marked against the commit, and the notice says so",
      gb.get("tools") is True and (gb["tracked"].get("unread") or 0) >= 2 and (gt.get("marks") or 0) >= 2
      and gt.get("notice") == "Changes since the last commit", gb)
check("git: an untracked file opens unmarked, without the notice",
      (gb.get("untracked") or {}).get("unread") == 0 and gu.get("marks") == 0 and gu.get("notice") == "", gb)
# View ▸ Compare with Last Commit (N1, 3.8): with everything read, what changed
# since the commit is marked again, with the notice; Undo brings back what was read.
gc, gcu = gb.get("compare_tracked") or {}, gb.get("compare_untracked") or {}
check("compare: enabled in a repository, not outside one",
      gc.get("enabled") is True and gcu.get("enabled") is True and gb.get("compare_enabled_outside") is False, gb)
check("compare: a read document is marked against the last commit again, with the notice",
      gc.get("unread_read") == 0 and (gc.get("unread_compared") or 0) >= 2 and (gc.get("marks_compared") or 0) >= 2
      and gc.get("notice") == "Changes since the last commit", gb)
check("compare: Undo brings back what was read",
      gc.get("undo_title") == "Undo Compare with Last Commit" and gc.get("unread_undone") == 0 and gc.get("marks_undone") == 0
      and gc.get("notice_undone") == "", gb)
check("compare: an untracked file says there is nothing to compare with, in the notice",
      gcu.get("unread_compared") == 0 and gcu.get("notice") == "Not in the last commit" and gcu.get("subtitle") != "Not in the last commit", gb)

# ⌘P before the document has loaded (3.7 review): printed once it is, the
# document and not the empty page; asked twice meanwhile, printed once.
ep = load("early-print.json")
print(f"early-print: {ep}")
check("print before the first load prints the document once it is applied",
      ep.get("opened") is True and ep.get("loaded_when_asked") is False and len(ep.get("printed") or []) == 1
      and (ep["printed"][0] or 0) >= 1 and ep["printed"][0] == ep.get("page_blocks"), ep)

ack = OUT / "Acknowledgements.md"
sys.path.insert(0, str(ROOT / "tools"))
from credits import production_packages, unescape  # noqa: E402
text = unescape(ack.read_text()) if ack.exists() else ""
absent = [n for n in production_packages() if n not in text]
check("Acknowledgements.md in the app names every production dependency", ack.exists() and not absent, absent[:20])

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
# F6: a second preview (on the spare page the first left, when the extension
# kept running) renders the same document in full.
previews = re.findall(r"preview (applied|timed out): rendered (-?\d+) of (\d+) blocks", qrt)
check("quicklook second preview applied, 36 blocks", len(previews) >= 2 and previews[1] == ("applied", "36", "36"), previews)
# The preview is asked for, then applied: both logged (ql_open_ms comes from the second).
check("quicklook logs the request", "preview requested" in qrt, qrt[-500:])
# P9: the web view is made before the document is parsed, and its page's
# ready is logged (ql_page_ready_ms), both before the apply.
iv, ip, ia = qrt.find("preview view created"), qrt.find("preview page ready"), qrt.find("preview applied")
check("quicklook creates its web view first and logs its page ready before the apply",
      0 <= iv < ip and (ia < 0 or ip < ia), qrt[-800:])
check("quicklook page-ready time reported", isinstance(load("ql-timings.json").get("ql_page_ready_ms"), int))

tm = load("timings.json")
# Readout's own share of a warm open is part of it, and measured for every open.
check("warm open: Readout's share is measured and within the whole open",
      isinstance(tm.get("warm_open_to_applied_ms"), (int, float)) and isinstance(tm.get("warm_open_ms"), (int, float))
      and tm["warm_open_to_applied_ms"] <= tm["warm_open_ms"], tm)

# P5: the cold start in phases, in the order they happen, from the process
# start (sysctl); Readout's own segments measured. 3.9.1: no spare page before
# the first window (made in willFinishLaunching, 3.9.0's spare held up the
# rest of the launch and the window): the first window makes its own page,
# and the spare for the next open is made once that page has painted.
lp = tm.get("launch_phases_ms") or {}
order = ["will_finish_launching", "did_finish_launching", "open_requested", "window_init", "page_ready", "apply", "paint", "spare_created"]
print(f"launch phases (ms since process start): {lp}; cold_page_ready_ms {tm.get('cold_page_ready_ms')}, cold_apply_ms {tm.get('cold_apply_ms')}")
check("cold start: every launch phase measured, in order",
      all(isinstance(lp.get(k), (int, float)) for k in order + ["did_load"])
      and all(0 <= lp[a] <= lp[b] for a, b in zip(order, order[1:])) and lp["did_load"] <= lp["apply"], lp)
check("cold start: the first window is on screen after it is made and before its document is painted",
      all(isinstance(lp.get(k), (int, float)) for k in ("window_init", "window_visible", "paint"))
      and lp["window_init"] <= lp["window_visible"] <= lp["paint"]
      and all(isinstance(tm.get(k), (int, float)) for k in ("cold_window_visible_ms", "cold_window_visible_first_boot_ms")), tm)
check("cold start: Readout's segments measured",
      all(isinstance(tm.get(k), (int, float)) for k in ("cold_page_ready_ms", "cold_apply_ms", "cold_window_to_load_ms", "cold_dfl_to_window_ms")), tm)

# cold_apply_ms is the second launch's (owner decision 2026-10-21: the job's
# first launch is the first time WebKit runs on the VM); the first launch ran,
# painted and is still reported, and the page's split of the measured one is in.
lp2 = tm.get("launch_phases_second_ms") or {}
check("cold apply: measured on a second launch, after a first one that painted",
      isinstance(tm.get("cold_apply_first_boot_ms"), (int, float)) and isinstance(tm.get("cold_apply_ms"), (int, float))
      and all(isinstance(lp2.get(k), (int, float)) for k in order + ["did_load"]) and isinstance(lp.get("paint"), (int, float)), tm)
boot_kept = load("boot/sentinel.json")
check("first launch: a preference and a baseline that were there before it are still there after",
      boot_kept.get("preference") is True and boot_kept.get("baseline") is True, boot_kept)
check("cold start: how long the page made a call wait after its first paint is measured, both launches",
      all(isinstance(tm.get(k), (int, float)) for k in ("cold_post_paint_input_delay_ms", "cold_post_paint_input_delay_first_boot_ms")), tm)
check("cold apply: the page's split reported (setAppearance, block work, layout)",
      all(isinstance(tm.get(f"cold_page_{k}_ms"), (int, float)) for k in ("setappearance", "blocks", "layout")), tm)

print(f"{len(failures)} failing assertion(s)")
sys.exit(1 if failures else 0)
