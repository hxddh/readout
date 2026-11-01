# Readout 5 in pictures

Readout 5.0.0 is a native macOS Markdown reader for the plans, specs and reports your coding
agents write. This gallery shows the shipping app — not mockups — on macOS 26.3.1, captured at
2× Retina resolution. [Download Readout 5.0.0](https://github.com/hxddh/readout/releases/tag/v5.0.0).

## A plan that is still being written

![A plan open in Readout with the outline on the left, task progress in the title, and unread changes marked in the right margin](screenshots/01-live-reading-en.png)

Readout follows the file as an agent rewrites it. The paragraph you are reading stays in place;
if you are at the end, the view follows the agent like a terminal. The outline lists headings
and how many tasks in each section are done, the subtitle carries the overall count, and the
thin blue bars in the right margin are changes you have not read yet.

## See the words that changed

![An edited frontmatter block showing "in progress" struck through and "ready to ship" added, under a “Marked what changed since” notice](screenshots/02-what-changed-en.png)

Changes are marked block by block. On an edited block, Readout shows exactly which words changed
since you last read it — here the plan's status moved from *in progress* to *ready to ship*.
Press <kbd>D</kbd> to show or hide the comparison, <kbd>N</kbd> to go to the next change, and
<kbd>⌘K</kbd> to mark everything read (<kbd>⌘Z</kbd> brings the marks back). The history notice
above the document says which version you are comparing against.

## Compare with any earlier version

![The View menu's Compare with Earlier Version submenu listing two earlier versions with their times and block differences](screenshots/03-history-menu-en.png)

Readout 5 keeps each version of a document it sees, for 30 days. **View ▸ Compare with Earlier
Version** lists them, newest first, each with when it was seen and how much differs now
(`+6 −3 blocks`, `+13 −6 blocks`). Choose one to mark everything that changed since that version;
<kbd>⌘Z</kbd> returns to what you had read.

## Open an earlier version

![An earlier version of the plan open read-only in its own window, with the date in the title and a change marked in the margin](screenshots/04-earlier-version-en.png)

**View ▸ Open Earlier Version** opens a version read-only in a window of its own. The title says
when Readout saw it, and the page is marked against the version before it, so you can see what
changed in that version without touching the file on disk.

## Everything waiting, in one place

![The Unread Changes menu listing a changed report, a plan with 11 unread changes, and a notes file not looked at yet](screenshots/05-unread-changes-en.png)

**View ▸ Unread Changes** gathers every document waiting for you, newest first: documents open
with unread changes (`11 unread`), documents opened in the background that you have not looked at
yet, and files in your agent folders that changed since you last read them. Choosing one takes you
to its first change.

## Tabs that tell you where to look

![Three document tabs, each with a blue unread dot, above the plan](screenshots/06-tabs-en.png)

Open documents share one window as tabs, and a blue dot marks the tabs that have something new —
unread changes, or a file opened behind you that you have not looked at. <kbd>N</kbd> walks the
changes in the current document and then moves on to the next waiting document.

## Chinese and English, set properly

![A Chinese plan in the Chinese interface, with mixed Chinese and English text, a note and a task list](screenshots/07-chinese-reader-zh.png)

The typography is tuned for mixed Chinese and English: CJK punctuation, line breaking and a
column that follows the window. The interface is localized too — this is Readout with its
Chinese menus, sidebar and task count.

## Code, diagrams and math in the dark

![A dark-mode design note showing a Swift code block, a Mermaid flowchart and a KaTeX formula](screenshots/08-dark-diagram-en.png)

GitHub-flavoured Markdown is rendered properly: syntax highlighting (Shiki), Mermaid diagrams and
KaTeX math, in light or dark. Readout follows the system appearance; the same document keeps its
diagram colours and code highlighting when the theme changes.

## Set up once

![The Readout welcome window with agent folders checked and the command-line step still to do](screenshots/09-welcome-en.png)

The welcome window sets Readout up in one place: add the folders your agents write in and install
the `readout` command, each step checked once done. Claude Code's `~/.claude/plans` is watched by
default. New Markdown files in those folders open in the background, without taking focus from
your terminal.

## Also in 5.0

- Files open faster when Readout is already running: the spare page has its fonts ready before a
  document arrives.
- Code blocks longer than 3,000 lines fold after the first 3,000, with a button for the rest;
  Copy, Find and printing still use every line.
- Requires macOS 26. One universal app for Apple silicon and Intel Macs.

[Download Readout 5.0.0](https://github.com/hxddh/readout/releases/tag/v5.0.0) ·
[Source](https://github.com/hxddh/readout)
