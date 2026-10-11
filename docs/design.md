# Design notes

Readout has one job: make long, frequently rewritten Markdown from AI agents comfortable to read.

## Pipeline

1. **Watch.** An FSEvents stream on the file's parent directory, with file-level events. Agents usually write a temporary file and rename it over the target, which breaks watchers that hold a file descriptor; watching the directory survives that. Changes are debounced (80 ms trailing, at most 400 ms during continuous writes). Half-written files (empty, sharply shrunk within a second of the last write, or ending mid UTF-8 sequence) are retried before rendering.
2. **Parse.** cmark-gfm via swift-markdown, off the main thread. Inline math is protected from Markdown parsing first. The document becomes a flat list of blocks: top-level nodes, with every top-level list item as its own block. Rendered HTML per block is cached by exact source and context, so a re-parse only renders blocks that changed.
3. **Fingerprint.** Each block has a fingerprint of its normalized source: trailing whitespace and blank-line runs removed, list markers unified, ordered-list numbers and checkbox state excluded (agents renumber lists and tick boxes; neither is a content change).
4. **Diff.** Myers diff on fingerprints finds unchanged blocks. Between unchanged blocks, deletions and insertions are paired into edits by token-bigram Jaccard similarity (characters for CJK, words otherwise), keeping order. A one-for-one replacement of the same block kind is always treated as an edit. If less than 20% of the document survives, it is treated as rewritten.
5. **Identity.** Blocks carry a session-stable slot. Unchanged and edited blocks keep their slot; inserted blocks get a new one. The web view only ever receives insert / replace / remove operations keyed by slot.
6. **Anchor.** Before a patch, the renderer records the first visible block and the offset into it; after applying, it restores that in the same frame. Edited anchor blocks restore proportionally. A ResizeObserver compensates for blocks above the viewport that change height later (diagrams, math, images).

## Change marks

Marks are relative to what you have read, not to the previous write. A block counts as read once at least half of it has been visible for 800 ms while the window is focused. When nothing is unread, the current version becomes the new baseline, which is stored per file (fingerprints plus a short similarity excerpt, capped at 500 characters per block) and survives restarts. Scroll-only position saves never rewrite an unchanged baseline.

## Rendering

The page is a single WKWebView served from a custom `readout://` scheme. Shiki (JavaScript regex engine) highlights code lazily; KaTeX and Mermaid load only when a document needs them. A spare, fully initialised web view is kept warm so a new window renders immediately.

Reader chrome element ids always use the `ro-` prefix (`ro-doc`, `ro-rail`, `ro-notice`, `ro-caughtup`, `ro-empty`); document content must never create ids in that namespace. `Slugger` escapes any slug starting with `ro-` to `h-ro-…`, and fragment/link resolution is scoped to the document container so it can never land on chrome.

## Privacy

The page's Content-Security-Policy is the security boundary: it allows no `http:`/`https:` sources at all (`img-src`/`media-src`/`connect-src` cover only `readout:`, `self`, `data:`, `blob:`), so rendering a document can never send a network request no matter what markup it contains. `HTML.sanitize`/`gateRemoteMedia` is UX only — it turns common remote `<img>`/Markdown images into click-to-load placeholders.

Clicking an image placeholder posts `loadRemote`; the App downloads it with `RemoteFetcher` (ReadoutCore): an ephemeral, cookie-free `URLSession`, 15 s timeout, public hosts only (loopback, link-local, private and unique-local literals, local and single-label names, and non-canonical numeric hosts are refused, and every address a name resolves to must be public; checked before the request and on every redirect — a name that changes its answer between that check and the connection is the accepted residual risk), status, `image/*` and `Content-Length` checked on the headers before any body is accepted, and the 20 MB cap counted while streaming so an oversized body is cancelled as soon as it passes the cap. Bytes are kept in a 100 MB least-recently-used cache and served back over `readout://remote/<token>`. Video/audio placeholders open externally instead of proxying. Quick Look never enables remote loading and shows placeholders only.

## Focus and resume

The window subtitle and the sidebar footer show word count and estimated reading time (CJK characters count individually, Latin text counts words). "Show Only Changes" (⇧⌘K) hides every block already read; headings offer a hover link button that copies a `path#anchor` link to the section. The saved reading position is excerpt-anchored: the first 120 characters of the top block are stored alongside the baseline, so resume survives block-index shifts from agent edits (falling back to the legacy saved index for older records).
