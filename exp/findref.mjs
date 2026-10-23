// perf.test's find refresh for any build: node exp/findref.mjs <buildDir> (cwd web/)
// Page-side performance of a large document, in WebKit.
//
// Builds a ~1 MB document by chaining the real-agent corpus patches, then
// measures: the first apply (synchronous, and until painted), a 20-block update patch on top of it,
// the find bar's first search, an edit and Next while finding (to the painted frame), and how far the text jumps scrolling up from the end; in a ~5 MB document,
// an edit above the reader, outline jumps, Return in a one-letter find, and an agent streaming at its end
// while the reader follows; on a fresh warmed page, the first apply of a small
// document whose code block is on screen, then of one with a Python and a YAML
// block (both coloured in that apply), then a small plan's private memory;
// on a fresh page not warmed, how long its first TypeScript block takes to
// highlight; scrolling 500 KB (with and without change marks), 1 MB and
// 5 MB documents (frame gaps, the page's own longest callback, blank area),
// a selection change, a mouse drag, the dark/light switch and find Next, an
// agent streaming at 5 MB (frame gaps) and inserting in its middle. Writes the numbers to
// test/out/perf-web.json; tools/perf-assert.py checks them against
// tools/perf-budgets.json.
//
// Usage: node test/perf.test.mjs
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { execSync } from 'node:child_process';
const collectPageErrors = (page, errors) => page.on('pageerror', e => errors.push(String(e)));


const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join(process.argv[2], decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

// Chain corpus patches into one document of at least `target` bytes of HTML.
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
// `few`: an agent's plan or report with few code blocks (one in 15 kept, no diagrams).
function chain(target, few = false) {
  const ops = [];
  let slot = 0, bytes = 0, codes = 0;
  for (let round = 0; bytes < target; round++) {
    for (const f of files) {
      const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
      for (const op of p.ops) {
        if (op.op !== 'insert') continue;
        if (few && (op.kind === 'mermaid' || (op.kind === 'code' && codes++ % 15))) continue;
        ++slot;
        ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
        bytes += op.html.length;
      }
      if (bytes >= target) break;
    }
  }
  return { ops, bytes };
}
const { ops, bytes } = chain(1_000_000);
const big = { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
const paragraphs = ops.filter(o => o.kind === 'paragraph');
const step = Math.floor(paragraphs.length / 20);
const edit = {
  version: 2, reset: false, rewrite: false,
  ops: paragraphs.filter((_, i) => i % step === 0).slice(0, 20)
    .map(o => ({ ...o, op: 'replace', change: 'modified', html: o.html.replace('</p>', ' (revised)</p>') })),
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
};
edit.marks = edit.ops.map(o => ({ slot: o.slot, kind: 'modified' }));

const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
const errors = [];
collectPageErrors(page, errors);
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

const median = xs => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];

// First apply of the whole document, timed in the page: the apply itself
// (which reads no layout: the first frame lays out only what is on screen),
// and until the frame that shows it has been painted (the moment the page
// reports 'painted': a task queued from the frame's animation callbacks runs
// after its paint). Nothing is measured in between: forcing a layout there
// would lay out every block, which the page no longer does.
const firstApply = await page.evaluate(p => new Promise(resolve => {
  const t0 = performance.now();
  window.readout.apply(p);
  const sync = performance.now() - t0;
  requestAnimationFrame(() => setTimeout(() => resolve({ sync, painted: performance.now() - t0 }), 0));
}), big);
await page.waitForTimeout(1500);

// A 20-block update in the middle of reading, three times, each with new
// text: the apply plus the layout it causes. The page settles after the
// scroll first, so what the scroll causes is not counted in the update: the
// blocks it brings on screen laid out at their real heights, the resize
// observer keeping the place (a scroll of its own, then the page laid out
// again), the code on screen highlighted. Two frames were not enough: right
// after them a layout of the whole page (70-130 ms on CI) was still due, and
// the first read of the update paid it, in every first update and in about
// one run in ten in the second too, which made the median.
const updates = [];
const settled = () => page.evaluate(() => new Promise(resolve => {
  // Eight 50 ms timers in a row on time (the main thread free for 400 ms), then two frames.
  let quiet = 0, due = performance.now() + 50;
  const tick = () => {
    quiet = performance.now() - due < 10 ? quiet + 1 : 0;
    if (quiet >= 8) return requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0)));
    due = performance.now() + 50;
    setTimeout(tick, 50);
  };
  setTimeout(tick, 50);
}));
for (let i = 0; i < 3; i++) {
  await page.evaluate(y => window.scrollTo(0, y), 20000 + i * 5000);
  await settled();
  const patch = { ...edit, version: 2 + i, ops: edit.ops.map(o => ({ ...o, html: o.html.replace('(revised)', `(revised ${i + 1})`) })) };
  updates.push(await page.evaluate(p => {
    const t0 = performance.now();
    window.readout.apply(p);
    void document.scrollingElement.scrollHeight;
    return performance.now() - t0;
  }, patch));
  await page.waitForTimeout(300);
}

// The find bar's first search in the 1 MB document (⌘F, a word, Return): it
// reads every block's text (no layout), counts the matches and selects the
// first one, on screen (going to one off screen is an outline jump's cost:
// web_toc_jump_5mb_ms). 3.8 laid out the whole document as the find bar
// opened, and again as it closed. Three times, from nothing found before.
const findOpen = [];
for (let i = 0; i < 3; i++) {
  findOpen.push(await page.evaluate(() => {
    getSelection().removeAllRanges();
    const blk = document.elementFromPoint(450, 450).closest('.blk');
    const word = [blk, blk.nextElementSibling, blk.previousElementSibling].map(b => b && b.textContent.match(/[A-Za-z]{6,}/)).find(Boolean)[0];
    const t0 = performance.now();
    const n = window.readout.find(word);
    const ms = performance.now() - t0;
    window.readout.findEnd();
    return n > 0 ? ms : -1;
  }));
  await settled();
}
if (findOpen.some(ms => ms < 0)) errors.push(`find found nothing: ${findOpen}`);
// While the find bar is open: an agent's one-block edit, five times, and
// Return (Next) seven times. Each timed to the painted frame (a task queued
// from a frame's animation callbacks runs after its paint): the edit, the
// longest frame in the half second after it (the apply's frame, then the
// page searching again for the count and the marks: find.js refresh, 100 ms
// later; its own time is web_find_refresh_1mb_ms); Next, the call until the
// frame showing the match it lands on (the match is selected in the next
// frame, reported in the samples). 3.9.0: every Return and every edit set
// the highlights again, which repaints all 300 near marks.
await page.evaluate(() => {
  // fn(), then the frames painted until `ms` after it (two at least): [the call, from it to the first frame, each frame after].
  window.painted = (fn, ms) => new Promise(resolve => {
    const t0 = performance.now();
    fn();
    const ts = [t0, performance.now()];
    const tick = () => requestAnimationFrame(() => setTimeout(() => {
      ts.push(performance.now());
      if (ts.length < 4 || ts.at(-1) - t0 < ms) return tick();
      resolve(ts.slice(1).map((t, i) => t - ts[i]));
    }, 0));
    tick();
  });
  window.readout.find('the');
});
await page.waitForTimeout(500);
const findRefresh = [], findRefreshFrame = [];
for (let i = 0; i < 5; i++) {
  const o = paragraphs[i * 7 + 3];
  const gaps = await page.evaluate(p => window.painted(() => window.readout.apply(p), 500), { version: 50 + i, reset: false, rewrite: false,
    ops: [{ ...o, op: 'replace', change: 'content', html: o.html.replace('</p>', ` the edit ${i}</p>`) }], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  findRefreshFrame.push(Math.max(gaps[0] + gaps[1], ...gaps.slice(2)));
  (globalThis.__gaps ||= []).push(gaps.slice(0, 10).map(Math.round));
  findRefresh.push(await page.evaluate(() => performance.getEntriesByName('readout-find-refresh').pop()?.detail ?? -1));
  await page.waitForTimeout(200);
}

console.log(JSON.stringify({ build: process.argv[2].split('/').pop(), gaps: globalThis.__gaps, frame: findRefreshFrame.map(Math.round), refresh: findRefresh.map(Math.round), errors: errors.length }));
await browser.close(); server.close(); process.exit(0);
