<p align="center"><img src="tools/icon/readout-1024.png" width="128" alt=""></p>

<h1 align="center">Readout</h1>

<p align="center">A fast, native Markdown reader for what your AI agents write.<br>
<a href="README.zh-CN.md">中文说明</a></p>

---

<p align="center"><img src="docs/screenshot.png" width="720" alt="A Readout window: an agent's plan with its outline in the sidebar and unread changes marked in the margin"></p>

Agents write plans, specs, reports and explanations as long Markdown files, and they keep rewriting them. Readout is a read-only viewer built for that: it opens instantly, renders cleanly, follows the file as the agent writes, and shows you exactly what changed since you last looked.

## What it does

- **Live, without losing your place.** Readout watches the file (including atomic save-and-rename writes). Updates are applied block by block, so the paragraph you are reading stays put. If you are at the end, it follows the agent like a terminal.
- **Shows what changed.** New and edited blocks get a thin bar in the margin; press <kbd>N</kbd> to go to the next one, and on an edited block it shows which words changed since you read it (or click the bar). Removed text leaves a small marker that opens to show it in full. Marks fade once you have actually read them. Press <kbd>⌘K</kbd> to mark everything read (<kbd>⌘Z</kbd> brings the marks back). Readout remembers what you had read, even across launches. For a file in a git repository, **View → Compare with Last Commit** marks what changed since the last commit (<kbd>⌘Z</kbd> undoes it).
- **Renders properly.** GitHub-flavoured Markdown: tables, task lists, alerts, typography tuned for mixed Chinese and English (a column that follows the window, up to about 175 characters, or the whole window with **View → Text Width → Wide**), syntax highlighting (Shiki), math (KaTeX) and Mermaid diagrams. Code references like `src/app/main.swift:42`, and links such as `[main](src/app/main.swift#L42)`, open in your editor at that line (the file's default app, when it is VS Code, Cursor, Zed, Xcode or Sublime Text, or the editor chosen in Settings). A link to another Markdown document opens it as the next tab; <kbd>⌘W</kbd> takes you back.
- **Outline with progress.** The sidebar lists headings and how many tasks in each section are done. It shows by itself when the window is wide enough and hides when it narrows; Show/Hide Sidebar overrides that for the window.
- **Task progress and section links.** The window subtitle shows task progress; Control-click a heading to copy a link to its section.
- **Opens what your agents write.** Add the folders your agents write to in Settings (Claude Code's `~/.claude/plans` is added automatically). A new Markdown document an agent creates there opens in Readout on its own, in the background, without taking focus from your terminal (edits to files that were already there, such as a README, do not). Press <kbd>⌃⌥⌘R</kbd> anywhere to open the most recently written one. The Dock icon's badge counts the files *waiting* for you: with unread changes, or opened in the background and not looked at yet. Using Codex? Add your project folder in Settings. To have Readout running whenever an agent writes, add it in **System Settings → General → Login Items**; opened at login, it shows no welcome window.
- **Quick Look.** Press Space on a `.md` file in Finder (it works once Readout has been opened from Applications).
- **Read-only by design.** Readout never writes to your files, and a click in a document never runs anything: a link to an app, a script or an installer shows it in Finder, and links out open only for the web and mail.

## Install

Download `Readout-x.y.z.dmg` from [Releases](https://github.com/hxddh/readout/releases), open it and drag Readout to Applications. Requires macOS 26 or later; one universal app for Apple silicon and Intel Macs.

Every release is ad-hoc signed, not notarized, so macOS refuses to open it the first time. Open **System Settings → Privacy & Security**, find the message about Readout and click **Open Anyway**. You need to do this once per release. For the same reason macOS asks again after each update before Readout may read files in Documents, Desktop or Downloads, and before it may ask Xcode to open a file at a line (Apple Events): it ties those permissions to the app's signature, which an ad-hoc signature changes with every build. Notarized releases will keep them.

To check a download, put `SHA256SUMS` from the release next to the DMG and ZIP and run `shasum -a 256 -c SHA256SUMS` (only the DMG: `grep dmg SHA256SUMS | shasum -a 256 -c`).

Readout checks GitHub Releases for new versions (**Readout → Check for Updates…**). **Download Update** hands the new DMG to your browser, which downloads it; Readout installs nothing itself. When a weekly check finds a new version, the Readout menu says so; choosing it offers the same.

## Privacy

Rendering a document sends no network requests at all: remote images and media render as placeholder buttons naming the host. Only when you click does Readout itself download the image — without cookies, and never from your own machine or local network — and show it; once one is loaded, the other placeholders from that host offer to load them all with one more click, and an image you loaded shows again without asking while Readout runs. Video and audio open in your browser instead. The only automatic network access is the weekly update check, which you can turn off in settings.

## Command line (optional)

Readout needs no setup for agents: the folders in Settings are enough. If you also want a `readout` command, choose **Readout → Install Command Line Tool…**, which shows (and copies) the command that links `~/.local/bin/readout` to the script inside the app. It is this:

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/Readout.app/Contents/Resources/readout ~/.local/bin/readout
```

(`~/.local/bin` must be on your `PATH`.) Then `readout plan.md` opens a file, `readout plan.md#risks` opens it at a section, `readout ~/.claude/plans` opens the newest Markdown file in a folder, and `readout -b plan.md` opens it in the background, as a tab behind the one you are reading, without switching apps. `readout --version` prints the version.

For a Claude Code hook instead of a watched folder (no `readout` link needed), add this to `~/.claude/settings.json`; it opens every Markdown file Claude Code writes or edits in the background:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          { "type": "command", "command": "/Applications/Readout.app/Contents/Resources/readout --hook" }
        ]
      }
    ]
  }
}
```

The hook also passes the folder Claude Code works in, so file paths in a plan kept in `~/.claude/plans` link to the files in that project.

The same command works as a [Cursor hook](https://cursor.com/docs/hooks) (`afterFileEdit`, in `~/.cursor/hooks.json`; the first workspace folder is the project):

```json
{
  "version": 1,
  "hooks": {
    "afterFileEdit": [
      { "command": "/Applications/Readout.app/Contents/Resources/readout --hook" }
    ]
  }
}
```

and as a [Gemini CLI hook](https://geminicli.com/docs/hooks/reference.md) (`AfterTool` on its [file tools](https://geminicli.com/docs/tools/file-system), in `~/.gemini/settings.json`):

```json
{
  "hooks": {
    "AfterTool": [
      {
        "matcher": "write_file|replace",
        "hooks": [
          { "type": "command", "command": "/Applications/Readout.app/Contents/Resources/readout --hook" }
        ]
      }
    ]
  }
}
```

### The `readout-open:` URL

`readout -b` and `readout --hook` open files through a URL, which other tools can use too:

```
readout-open://open?path=<absolute path>&background=1&anchor=<section>&root=<folder>
```

Every value is percent-encoded. `path` is required: a Markdown file, or a folder to open its newest Markdown file. `background=1` opens it behind the document you are reading, without bringing Readout forward. `anchor` scrolls to a section (a heading's slug, as in `plan.md#risks`). `root`, an existing absolute folder, is the project the document's relative paths belong to: code references, links and images in that document are also looked up there, and Readout keeps the folder for the file.

Any app or web page can open such a URL (browsers ask you first), as it can ask Finder to open a file, so Readout does not trust it more than that: `root` only changes which files that document's paths point to, never what Readout may read, and nothing is sent anywhere. (A marker only the `readout` script sets would not prove where a URL came from: any caller could add it.)

## Keyboard

| Key | Action |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd> | Next / previous unread change (on an edited block, shows which words changed), then the next waiting file |
| <kbd>D</kbd> | Show / hide the words that changed in edited blocks on screen |
| <kbd>⌘K</kbd> | Mark all as read (<kbd>⌘Z</kbd> undoes it) |
| <kbd>⌃⌥⌘R</kbd> | Open the latest agent file, from any app |
| <kbd>⌘E</kbd> | Open in your editor, at the line you are reading |
| <kbd>⇧⌘C</kbd> | Copy as Quote, with file and lines, for your agent |

Every shortcut is in **Help → Readout Help**, in Readout, offline.

## How it works

The native side parses Markdown with cmark-gfm (via swift-markdown) into a flat list of blocks, fingerprints each block, and diffs new versions against old ones (Myers diff on fingerprints, then similarity pairing for edits). Every block keeps a stable identity across versions, so the web view receives small patches instead of a new page, and the reading anchor is restored in the same frame. The design notes are in [docs/design.md](docs/design.md).

## Building

```sh
brew install xcodegen node
make app        # builds web assets, generates the Xcode project and builds Readout.app
make test       # core tests
```

The core package (`Packages/ReadoutCore`) builds and tests on Linux too.

## License

MIT
