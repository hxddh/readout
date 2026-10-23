# Testing Readout

Three layers, each catching what the others cannot:

## 1. ReadoutCore unit tests (Linux)

Pure Swift: parsing, block diff, session state, stats, anchors.
Run: `swift test --package-path Packages/ReadoutCore`
Runs in CI as **Core tests (Linux)**. Also runs on macOS inside verify for
good measure, but Linux is the gate.

## 2. Web patch-engine tests (WebKit)

`web/test/apply.test.mjs` drives `reader.html` through insert order, anchor
stability, follow semantics, and fragment scroll.
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

`web/test/copy.test.mjs` also copies random selections and parses each copy
again with ReadoutCore (`readout-dump`, built with `swift build`, or the
binary in `READOUT_DUMP`; with neither, it fails and says how to set it): the copy must read as the selection did.
`COPY_FUZZ` sets the selections per document (default 8).

`web/test/chunks.test.mjs` runs seeded random agent writes away from the
reader (blocks written, rewritten and removed, removal markers coming and
going, the reader jumping around) and checks after every patch that the
reader's text did not move, the chunks' limits and the blocks' order; on
the runs of removals only, in a page laid out once, that the page is as tall
skipped as laid out. `SEEDS=1,2` runs other seeds; `READOUT_WEB_BUILD`
serves another build (to see a check fail on an older one).

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
- `zh-punct.json`: the fixture's Chinese paragraph draws “ ” ‘ ’ — … in
  PingFang SC (reader.css's `local()` face loads in WKWebView), not in the
  system font
- Quick Look: `pluginkit` lists `io.github.hxddh.readout.quicklook`, the
  `qlmanage` log has no errors, and the extension's log line reports the
  preview was applied with 36 of 36 blocks rendered (proof of content, not
  just registration; `qlmanage -t` cannot prove this because a preview
  extension does not produce thumbnails), for two previews in a row (the
  second may take the spare page the first left). The extension has no
  `Web/` of its own: it serves the page from the app's `Contents/Resources/Web`

CI prints the actual values before asserting. The thresholds come from the
`plan.md` fixtures; **a mismatch means the product regressed**.

## 4. Rendering baselines (real agent corpus)

`web/test/corpus/` holds 30 real documents written by coding agents (plans,
specs, reports, AGENTS.md / CLAUDE.md files; 20 English, 10 Chinese or
mixed), each a byte-for-byte copy pinned to a commit of a permissively
licensed repository. `SOURCES.md` lists source, license and agent evidence.
One more, `31-readout-typesetting-cases.md`, is synthetic: written for these
baselines, for constructs the real documents lack (code in an alert, a
console transcript, CJK emphasis, short table cells).

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

## 5. Speed budgets

`tools/perf-budgets.json` lists each measured metric with a `target` (the
goal from the release plan) and a `guard` (the regression limit CI enforces).
`tools/perf-assert.py WHERE FILE...` fails when a gated metric is missing or
over its guard; metrics with `"guard": null` are printed but not gated.

| Where | Measured by | Metrics |
| --- | --- | --- |
| mac (Verify signed product) | `PerformanceBudgetTests` in a release build, written to the file named by `READOUT_PERF_OUT`; `tools/smoke-run.py` timings from the signed app; the Quick Look extension's log | update_100kb, update_1mb, word_diff_100kb (the word-level comparison of 20 edited blocks); cold_start_ms and its launch phases (the job's first launch), cold_window_visible_ms and cold_start_second_ms (the second launch: spawn to the first window on screen, and to its document painted; the first launch's window is reported as cold_window_visible_first_boot_ms), cold_apply_ms (the second launch: the first is the first time WebKit runs on the VM; its value is reported as cold_apply_first_boot_ms, with the page's split cold_page_setappearance_ms, cold_page_blocks_ms, cold_page_layout_ms), warm_open_ms, write_to_update_ms; ql_open_ms, ql_second_open_ms (reported) |
| linux-webkit (Web tests) | `node web/test/perf.test.mjs` → `web/test/out/perf-web.json` | web_first_apply_1mb_ms (the synchronous first apply, which reads no layout), web_first_apply_1mb_painted_ms (until the frame showing it is painted), web_update_20_blocks_1mb_ms (including the layout it causes), web_find_open_1mb_ms (the find bar's first search: every block's text read without layout, the matches counted, one on screen landed on), web_find_refresh_1mb_ms (with a search on, the count and marks after a one-block edit; reported), web_find_one_letter_5mb_ms (Return in a find for "e" in the 5 MB document, about 300,000 matches: the two frames after it), web_scroll_up_jump_px, web_diagram_draw_1mb_ms and web_diagram_draw_1mb_longest_frame_ms (a flowchart appended at the end of a 1 MB page: until drawn, and the longest frame meanwhile), web_first_highlight_warm_ms and web_first_highlight_cold_ts_ms (a TypeScript block on a warmed page, and on one not warmed), web_first_highlight_warm_py_yaml_ms and web_warm_first_paint_plain_blocks (a Python and a YAML block on the warmed page: that apply, and how many of them it painted plain; guard 0), web_tab_private_mb (a warmed tab's private memory with a small plan, Linux smaps), web_stream_append_5mb_ms (an agent streaming at the end of a 5 MB document the reader follows, per patch including its layout; reported); scrolling (`web/test/scrollperf.mjs`: a 500 KB agent document with few code blocks, static and with change marks, the 1 MB and the 5 MB documents, each scrolled down through parts not seen yet at 2400 px/s, in flings and by the browser's own wheel events): web_scroll_*_frame_p95_ms, web_scroll_*_frame_max_ms, web_scroll_*_long_frames (frame gaps over 50 ms), web_scroll_blank_px (viewport rows over content WebKit skipped, summed over every frame: must be 0), web_scroll_own_longest_ms (the page's own longest callback while scrolling); web_select_1mb_ms and web_select_5mb_ms (a selection change to its painted frame), web_drag_5mb_ms (20 of them), web_theme_1mb_ms and web_theme_5mb_ms (the dark/light switch), web_find_next_5mb_ms and web_find_next_1mb_selected_ms (Return until the match is shown selected), web_insert_middle_5mb_ms (three blocks inserted in the middle, far from the reader, and removed), web_stream_frame_p95_5mb_ms and web_stream_long_frames_5mb (frame gaps while an agent writes a patch every 100 ms at the end the reader follows); web_n_jump_5mb_ms (N to the next of 200 changes in the 5 MB document) and web_scroll_5mb_own_per_frame_ms (the page's own work per scroll frame there); code-heavy documents (700 blocks of 90-line code, and one 28,000-line code block among 3,000 paragraphs): web_code_heavy_* and web_one_huge_code_* (outline jump, theme switch, scroll p95/max and long frames, blank px, private memory after scrolling; the theme switch is gated as *_theme_over_raw, its time over the same switch by the data-theme attribute alone, the two alternated in the same page, five pairs, the median ratio, and as *_elements, the elements it restyles; its time is reported only) |

Run locally:

```sh
READOUT_PERF_OUT=/tmp/perf-core.json swift test -c release --package-path Packages/ReadoutCore --filter PerformanceBudgetTests
cd web && npm run build && node test/perf.test.mjs
tools/perf-assert.py linux-webkit web/test/out/perf-web.json
```

Local numbers are not comparable with CI's machines; the guards apply to CI.
Lower a guard when a metric improves; never raise one to make CI pass, and
explain any change in `_comment` and the PR.

## The one rule

**Never edit, delete or relax a test assertion to make CI green.** If you
believe an existing assertion is wrong, explain why in the PR's
`Test changes` section, one bullet per assertion. Assertion changes without
a reason are rejected.
