# Readout Keyboard Shortcuts

A file is **waiting** when it has unread changes, or was opened in the background and you have not looked at it yet. Its tab has a dot, and the Dock icon's badge counts the waiting files.

## Reading

| Key | Action |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd> (also <kbd>⌘]</kbd> / <kbd>⌘[</kbd>) | Next / previous unread change (on an edited block, shows which words changed, until you move on), then the next waiting file |
| <kbd>D</kbd> | Show / hide the words that changed in edited blocks on screen (also **View ▸ Show What Changed**) |
| <kbd>⌘K</kbd> | Mark all as read (<kbd>⌘Z</kbd> undoes it) |
| <kbd>J</kbd> / <kbd>K</kbd> | Scroll down / up |
| <kbd>G</kbd> / <kbd>⇧G</kbd> (also <kbd>⌘↑</kbd> / <kbd>⌘↓</kbd>) | Jump to top / end |
| <kbd>Esc</kbd> | Close an open comparison or removed-text popup |
| <kbd>Tab</kbd> / <kbd>⇧Tab</kbd> | Next / previous link or file path |

**View ▸ Compare with Last Commit** marks the changes since the file's last git commit (<kbd>⌘Z</kbd> undoes it).

## Files

| Key | Action |
| --- | --- |
| <kbd>⌘O</kbd> | Open a Markdown file |
| <kbd>⌃⌥⌘R</kbd> | Open the latest agent file, waiting files first, from any app (turn off in Settings) |
| <kbd>⌘E</kbd> | Open in your editor, at the line you are reading (or the selection) |
| <kbd>⇧⌘R</kbd> | Reveal in Finder |
| <kbd>⌘C</kbd> | Copy as Markdown (formatted in rich-text apps) |
| <kbd>⇧⌘C</kbd> | Copy as Quote, with file and lines, for your agent |
| <kbd>⌥⌘C</kbd> | Copy the file's path |
| <kbd>⌘P</kbd> | Print |
| <kbd>⌘W</kbd> / <kbd>⌥⌘W</kbd> | Close / close all (a file opened from a link: back to the tab it was in) |

## Find and view

| Key | Action |
| --- | --- |
| <kbd>⌘F</kbd> | Find |
| <kbd>⌘G</kbd> / <kbd>⇧⌘G</kbd> | Find next / previous |
| <kbd>⌘+</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd> | Bigger / smaller / actual text size |
| <kbd>⌃⌘S</kbd> | Show / hide the sidebar |
| <kbd>⌃⌘F</kbd> | Full screen |
| <kbd>⌘,</kbd> | Settings |

Links to source files open in your editor at the line: `src/app.ts:42`, `src/app.ts:42:7`, or GitHub-style `src/app.ts#L42`. The editor is the file's default app (VS Code, Cursor, Zed, Xcode and Sublime Text open at the line), or the one chosen in Settings.
