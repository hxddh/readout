<p align="center"><img src="tools/icon/readout-1024.png" width="128" alt=""></p>

<h1 align="center">Readout</h1>

<p align="center">A fast, native Markdown reader for what your AI agents write.<br>
<a href="README.zh-CN.md">中文说明</a></p>

---

Agents write plans, specs, reports and explanations as long Markdown files, and they keep rewriting them. Readout is a read-only viewer built for that: it opens instantly, renders cleanly, follows the file as the agent writes, and shows you exactly what changed since you last looked.

## What it does

- **Live, without losing your place.** Readout watches the file (including atomic save-and-rename writes). Updates are applied block by block, so the paragraph you are reading stays put. If you are at the end, it follows the agent like a terminal.
- **Shows what changed.** New and edited blocks get a thin bar in the margin; click an edited block's bar to see which words changed since you read it. Removed text leaves a small marker that opens to show it in full. Marks fade once you have actually read them. Press <kbd>N</kbd> for the next change, <kbd>⌘K</kbd> to mark everything read. Readout remembers what you had read, even across launches.
- **Renders properly.** GitHub-flavoured Markdown: tables, task lists, alerts, typography tuned for mixed Chinese and English, syntax highlighting (Shiki), math (KaTeX) and Mermaid diagrams. Code references like `src/app/main.swift:42` open in your editor.
- **Outline with progress.** The sidebar lists headings and how many tasks in each section are done.
- **Focus on what's new.** Filter the document to unread changes only (<kbd>⇧⌘K</kbd>), see task progress in the window subtitle, and copy a link to any section by hovering its heading.
- **Opens what your agents write.** Add the folders your agents write to in Settings (Claude Code's `~/.claude/plans` is added automatically). A new Markdown document an agent creates there opens in Readout on its own, in the background, without taking focus from your terminal (edits to files that were already there, such as a README, do not). Press <kbd>⌃⌥⌘R</kbd> anywhere to open the most recently written one. Using Codex? Add your project folder in Settings.
- **Quick Look.** Press Space on a `.md` file in Finder.
- **Read-only by design.** Readout never writes to your files.

## Install

Download `Readout-x.y.z.dmg` from [Releases](https://github.com/hxddh/readout/releases), open it and drag Readout to Applications. Requires macOS 26 or later.

If the build you downloaded is not notarized, macOS will refuse to open it the first time. Open **System Settings → Privacy & Security**, find the message about Readout and click **Open Anyway**.

Readout checks GitHub Releases for new versions (**Readout → Check for Updates…**).

## Privacy

Rendering a document sends no network requests at all: remote images and media render as placeholder buttons naming the host. Only when you click does Readout itself download the image — without cookies, and never from your own machine or local network — and show it; video and audio open in your browser instead. The only automatic network access is the weekly update check, which you can turn off in settings.

## Command line (optional)

Readout needs no setup for agents: the folders in Settings are enough. If you also want a `readout` command, link the script inside the app:

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/Readout.app/Contents/Resources/readout ~/.local/bin/readout
```

(`~/.local/bin` must be on your `PATH`.) Then `readout plan.md` opens a file and `readout -b plan.md` opens it in the background, as a tab behind the one you are reading, without switching apps.

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

## Keyboard

| Key | Action |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd> (also <kbd>⌘]</kbd> / <kbd>⌘[</kbd>) | Next / previous unread change |
| <kbd>D</kbd> | Show which words changed in the edited blocks in view, top first; once all are shown, hide them |
| <kbd>⌘K</kbd> | Mark all as read |
| <kbd>⇧⌘K</kbd> | Show only changes |
| <kbd>⇧⌘O</kbd> | Open the latest agent file |
| <kbd>⌃⌥⌘R</kbd> | Open the latest agent file from anywhere (global; change or turn off in Settings) |
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
