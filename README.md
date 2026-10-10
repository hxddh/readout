<p align="center"><img src="tools/icon-1024.png" width="128" alt=""></p>

<h1 align="center">Readout</h1>

<p align="center">A fast, native Markdown reader for what your AI agents write.<br>
<a href="README.zh-CN.md">中文说明</a></p>

---

Agents write plans, specs, reports and explanations as long Markdown files, and they keep rewriting them. Readout is a read-only viewer built for that: it opens instantly, renders cleanly, follows the file as the agent writes, and shows you exactly what changed since you last looked.

## What it does

- **Live, without losing your place.** Readout watches the file (including atomic save-and-rename writes). Updates are applied block by block, so the paragraph you are reading stays put. If you are at the end, it follows the agent like a terminal.
- **Shows what changed.** New and edited blocks get a thin bar in the margin; removed text leaves a small marker you can open. Marks fade once you have actually read them. Press <kbd>N</kbd> for the next change, <kbd>⌘K</kbd> to mark everything read. Readout remembers what you had read, even across launches.
- **Renders properly.** GitHub-flavoured Markdown: tables, task lists, alerts, typography tuned for mixed Chinese and English, syntax highlighting (Shiki), math (KaTeX) and Mermaid diagrams. Code references like `src/app/main.swift:42` open in your editor.
- **Outline with progress.** The sidebar lists headings and how many tasks in each section are done.
- **One shortcut to the latest file.** Add the folders your agents write to (Claude Code's `~/.claude/plans` is added automatically) and press <kbd>⌥⌘R</kbd> anywhere to open the newest Markdown file.
- **Quick Look.** Press Space on a `.md` file in Finder.
- **Read-only by design.** Readout never writes to your files.

## Install

Download `Readout-x.y.z.dmg` from [Releases](https://github.com/hxddh/readout/releases), open it and drag Readout to Applications. Requires macOS 26 or later.

If the build you downloaded is not notarized, macOS will refuse to open it the first time. Open **System Settings → Privacy & Security**, find the message about Readout and click **Open Anyway**.

Readout checks GitHub Releases for new versions (**Readout → Check for Updates…**).

## Command line and agent hooks

Choose **Readout → Install Command Line Tool…** to get `readout`:

```sh
readout plan.md          # open and bring Readout forward
readout -b plan.md       # open without switching apps
```

To have Claude Code open Markdown files in Readout as soon as it writes them, add a hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "readout --hook" }]
      }
    ]
  }
}
```

`readout --hook` reads the hook payload, and opens `tool_input.file_path` in the background only when it is a Markdown file.

## Keyboard

| Key | Action |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd> (also <kbd>⌘]</kbd> / <kbd>⌘[</kbd>) | Next / previous unread change |
| <kbd>⌘K</kbd> | Mark all as read |
| <kbd>⌘F</kbd>, <kbd>⌘G</kbd> | Find, find next |
| <kbd>⌘+</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd> | Text size |
| <kbd>⌥⌘\</kbd> | Narrow / wide text |
| <kbd>⌃⌘S</kbd> | Toggle sidebar |
| <kbd>⌘E</kbd> | Open the file in your editor |
| <kbd>J</kbd> / <kbd>K</kbd>, <kbd>G</kbd> / <kbd>⇧G</kbd> | Scroll, jump to top / end |

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
