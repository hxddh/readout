# Testing Readout

Three layers, each catching what the others cannot:

## 1. ReadoutCore unit tests (Linux)

Pure Swift: parsing, block diff, session state, stats, anchors.
Run: `swift test --package-path Packages/ReadoutCore`
Runs in CI as **Core tests (Linux)**. Also runs on macOS inside verify for
good measure, but Linux is the gate.

## 2. Web patch-engine tests (WebKit)

`web/test/apply.test.mjs` drives `reader.html` through insert order, anchor
stability, follow semantics, fragment scroll and the changes-only filter.
It runs in **WebKit — the engine that ships in WKWebView** — via Playwright.
`BROWSER` selects the engine (`webkit` default, `chromium`/`firefox`
available for debugging engine-specific behavior).

```sh
cd web && npm ci && npm run build
npm test                                  # WebKit (default)
BROWSER=chromium npm test                 # Chromium, for comparison only
```

`playwright` is pinned to an exact version in `web/package.json`; CI
installs WebKit with `npx playwright install --with-deps webkit`.

## 3. Signed-product smoke test

`tools/smoke-run.py` launches the built app on a copy of `plan.md` and
plays the agent: it rewrites the file (temp file + rename) shortly after the
app opens it (`plan-early.md`) and again mid-session (`plan-v2.md`). The app
side, `App/SmokeTest.swift` (enabled by `READOUT_SMOKE_OUT`), is read-only: it
captures stats JSON and screenshots into the output directory, signals the
harness through marker files, and quits by itself. The app never writes the
document; `verify.yml` fails if document-writing smoke code returns to the
sources or the signed binary. `verify.yml` runs it against the **signed
Release app copied to /Applications** — the exact bytes users install — and
`tools/smoke-assert.py` asserts:

- `1-initial`: blocks == 33, highlighted >= 2, math >= 3
- `2-after-edit`: blocks == 34, marks == 4, deletions == 1,
  |anchorShift| <= 2, mermaid >= 1
- `4-dark`: theme == "dark"
- the log contains no `Readout page error` and no `scheme handler: 404`
- Quick Look: `pluginkit` lists `io.github.hxddh.readout.quicklook`, the
  `qlmanage` log has no errors, and the extension's log line reports the
  preview was applied with 34 of 34 blocks rendered (proof of content, not
  just registration; `qlmanage -t` cannot prove this because a preview
  extension does not produce thumbnails)

CI prints the actual values before asserting. The thresholds come from the
`plan.md` fixtures; **a mismatch means the product regressed**.

## 4. Rendering baselines (real agent corpus)

`web/test/corpus/` holds 30 real documents written by coding agents (plans,
specs, reports, AGENTS.md / CLAUDE.md files; 20 English, 10 Chinese or
mixed), each a byte-for-byte copy pinned to a commit of a permissively
licensed repository. `SOURCES.md` lists source, license and agent evidence.

- `CorpusTests` (Core) renders every document to patch JSON
  (`corpus/patches/`) and fails when parser output changes. Regenerate with
  `READOUT_UPDATE_CORPUS=1 swift test --package-path Packages/ReadoutCore --filter CorpusTests`.
- `npm run corpus` (web, CI job "Rendering baselines (WebKit)") renders each
  patch light and dark with code, math and diagrams settled, and compares:
  - `corpus/snapshots/<doc>-<theme>.json`: every block's slot, position,
    height, a hash of its text, and a fingerprint of the computed styles and
    sizes of everything inside it. Exact; a failure names the changed blocks.
  - `corpus/screenshots/<doc>-<theme>.png`: pixels of the first 1200 px,
    with a small anti-aliasing tolerance. Full-page pixel baselines would
    add ~100 MB per rendering change, so the snapshot covers the rest.
- On failure CI uploads `corpus-actual`: actual baselines, diff images and
  full-page screenshots of every document.

Baselines come from CI's WebKit, not a developer machine (fonts differ).
The test raises Shiki's per-line tokenizing guard so a starved CI machine
cannot cut highlighting short and render the same page two ways.
To accept an intended rendering change: download `corpus-actual`, copy
`actual/snapshots` and `actual/screenshots` over `web/test/corpus/`, review
each changed image, and say why in the PR.

## The one rule

**Never edit, delete or relax a test assertion to make CI green.** If you
believe an existing assertion is wrong, explain why in the PR's
`Test changes` section, one bullet per assertion. Assertion changes without
a reason are rejected.
