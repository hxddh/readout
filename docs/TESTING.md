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

`App/SmokeTest.swift` (enabled by `READOUT_SMOKE_OUT`) opens the
`plan.md → plan-v2.md` fixtures in the built app, captures stats JSON, and
quits by itself. `verify.yml` runs it against the **signed Release app
copied to /Applications** — the exact bytes users install — and
`tools/smoke-assert.py` asserts:

- `1-initial`: blocks == 33, highlighted >= 2, math >= 3
- `2-after-edit`: blocks == 34, marks == 4, deletions == 1,
  |anchorShift| <= 2, mermaid >= 1
- `4-dark`: theme == "dark"
- the log contains no `Readout page error` and no `scheme handler: 404`
- Quick Look: `pluginkit` lists `io.github.hxddh.readout.quicklook` and the
  `qlmanage` log has no errors

CI prints the actual values before asserting. The thresholds come from the
`plan.md` fixtures; **a mismatch means the product regressed**.

## The one rule

**Never edit, delete or relax a test assertion to make CI green.** If you
believe an existing assertion is wrong, explain why in the PR's
`Test changes` section, one bullet per assertion. Assertion changes without
a reason are rejected.
