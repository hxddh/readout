# Readout Keyboard Shortcuts

## Reading

| Key | Action |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd> (also <kbd>⌘]</kbd> / <kbd>⌘[</kbd>) | Next / previous unread change (on an edited block, shows which words changed, until you move on); with none left, the next document that has some, or that was opened behind and not looked at yet |
| <kbd>D</kbd> | Show which words changed in the edited blocks in view, top first; once all are shown, hide them (also **View ▸ Show What Changed**) |
| <kbd>⌘K</kbd> | Mark all as read (<kbd>⌘Z</kbd> undoes it) |
| <kbd>J</kbd> / <kbd>K</kbd> | Scroll down / up |
| <kbd>G</kbd> / <kbd>⇧G</kbd> (also <kbd>⌘↑</kbd> / <kbd>⌘↓</kbd>) | Jump to top / end |
| <kbd>Esc</kbd> | Close an open comparison or removed-text popup |
| <kbd>Tab</kbd> / <kbd>⇧Tab</kbd> | Next / previous link or file path |

**View ▸ Compare with Last Commit** marks what changed since the file's last git commit, for a file in a git repository (<kbd>⌘Z</kbd> undoes it). The Dock icon's badge counts the documents waiting for you: unread changes, or opened behind and not looked at yet.

## Files

| Key | Action |
| --- | --- |
| <kbd>⌘O</kbd> | Open a Markdown file |
| <kbd>⇧⌘O</kbd> | Open the latest agent file: an open one with unread changes, or opened behind and not looked at yet, comes first |
| <kbd>⌃⌥⌘R</kbd> | Open the latest agent file from anywhere (global; change or turn off in Settings) |
| <kbd>⌘E</kbd> | Open the file in your editor, at the line you are reading (or the selection) |
| <kbd>⇧⌘R</kbd> | Reveal in Finder |
| <kbd>⌘C</kbd> | Copy the selection as Markdown (whole blocks exactly as the file writes them); apps that take rich text get it formatted |
| <kbd>⇧⌘C</kbd> | Copy as Quote: the selected blocks' Markdown (with nothing selected, the block <kbd>N</kbd> went to) as a quote, with the file's lines and section |
| <kbd>⌥⌘C</kbd> | Copy the file's path |
| <kbd>⌘P</kbd> | Print |
| <kbd>⌘W</kbd> / <kbd>⌥⌘W</kbd> | Close / close all (a document opened from a link: back to the tab it was in) |

## Find and view

| Key | Action |
| --- | --- |
| <kbd>⌘F</kbd> | Find |
| <kbd>⌘G</kbd> / <kbd>⇧⌘G</kbd> | Find next / previous |
| <kbd>⌘+</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd> | Bigger / smaller / actual text size |
| <kbd>⌥⌘\</kbd> | Narrow / wide text |
| <kbd>⌃⌘S</kbd> | Show / hide the sidebar |
| <kbd>⌃⌘F</kbd> | Full screen |
| <kbd>⌘,</kbd> | Settings |

Links to source files open in the editor chosen in Settings, at the line: `src/app.ts:42`, `src/app.ts:42:7`, or GitHub-style `src/app.ts#L42`.
