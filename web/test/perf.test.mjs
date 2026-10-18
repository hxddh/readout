// Page-side performance of a large document, in WebKit.
//
// Builds a ~1 MB document by chaining the real-agent corpus patches, then
// measures: the first apply (synchronous, and until painted), a 20-block update patch on top of it, and frame
// pacing while scrolling through the whole page; and, on a fresh warmed page,
// the first apply of a small document whose code block is on screen. Writes the numbers to
// test/out/perf-web.json; tools/perf-assert.py checks them against
// tools/perf-budgets.json.
//
// Usage: node test/perf.test.mjs
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

// Chain corpus patches into one document of at least TARGET bytes of HTML.
const TARGET = 1_000_000;
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
const ops = [];
let slot = 0, bytes = 0;
for (let round = 0; bytes < TARGET; round++) {
  for (const f of files) {
    const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
    const map = new Map();
    for (const op of p.ops) {
      if (op.op !== 'insert') continue;
      map.set(op.slot, ++slot);
      ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
      bytes += op.html.length;
    }
    if (bytes >= TARGET) break;
  }
}
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
// text: the apply plus the layout it causes. Two frames pass after the
// scroll, so the layout it causes is done and not counted in the update.
const updates = [];
const twoFrames = () => page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
for (let i = 0; i < 3; i++) {
  await page.evaluate(y => window.scrollTo(0, y), 20000 + i * 5000);
  await twoFrames();
  const patch = { ...edit, version: 2 + i, ops: edit.ops.map(o => ({ ...o, html: o.html.replace('(revised)', `(revised ${i + 1})`) })) };
  updates.push(await page.evaluate(p => {
    const t0 = performance.now();
    window.readout.apply(p);
    void document.scrollingElement.scrollHeight;
    return performance.now() - t0;
  }, patch));
  await page.waitForTimeout(300);
}

// Scroll through the whole page in 600 even steps, one per frame, and record
// frame gaps (each step lands on content not yet laid out). Headless WebKit
// on a shared CI machine paces frames unevenly, so these are reported, not
// gated (tools/perf-budgets.json).
await page.evaluate(() => window.scrollTo(0, 0));
await page.waitForTimeout(500);
const scroll = await page.evaluate(() => new Promise(resolve => {
  const gaps = [];
  const steps = 600;
  const stride = Math.ceil((document.scrollingElement.scrollHeight - innerHeight) / steps);
  let last = performance.now();
  const frame = now => {
    gaps.push(now - last);
    last = now;
    if (gaps.length > steps) return resolve({ gaps, stride });
    window.scrollBy(0, stride);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}));
const gaps = scroll.gaps.slice(1);
const sorted = gaps.slice().sort((a, b) => a - b);

// The first code block of a warm open: a fresh page warmed as the app's
// spare page is (its grammars preloaded and compiled in idle time), then a
// small document with a TypeScript block on screen, highlighted inside the
// synchronous first apply.
const firstHighlight = await (async () => {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(() => { window.readout.warm(); window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }); });
  const warmed = await p.evaluate(() => new Promise(r => {
    const end = performance.now() + 20000;
    const t = () => performance.getEntriesByName('readout-hl-warm').length ? r(true) : performance.now() > end ? r(false) : setTimeout(t, 50);
    t();
  }));
  await p.waitForTimeout(200);
  const code = 'import { readFile } from "node:fs/promises";\n\n// Load the plan and count its open tasks.\nexport async function openTasks(path: string): Promise<number> {\n  const text = await readFile(path, "utf8");\n  return text.split("\\n").filter(l => /^- \\[ \\]/.test(l)).length;\n}';
  const r = await p.evaluate(code => {
    const t0 = performance.now();
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ops: [
      { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'plan', html: '<h1 id="plan">Plan</h1>' },
      { op: 'insert', slot: 2, after: 1, kind: 'paragraph', html: '<p>Count the open tasks:</p>' },
      { op: 'insert', slot: 3, after: 2, kind: 'code', html: `<div class="code-block" data-lang="ts"><pre><code>${code.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</code></pre></div>` },
    ] });
    return { ms: performance.now() - t0, hl: document.querySelector('.code-block').dataset.hl };
  }, code);
  await p.close();
  return { ...r, warmed };
})();
if (!firstHighlight.warmed || firstHighlight.hl !== 'done') errors.push(`first highlight not measured: ${JSON.stringify(firstHighlight)}`);

const result = {
  web_doc_bytes: bytes,
  web_doc_blocks: ops.length,
  web_first_apply_1mb_ms: Math.round(firstApply.sync),
  web_first_apply_1mb_painted_ms: Math.round(firstApply.painted),
  web_update_20_blocks_1mb_ms: Math.round(median(updates) * 10) / 10,
  web_first_highlight_warm_ms: Math.round(firstHighlight.ms),
  web_scroll_frames: gaps.length,
  web_scroll_stride_px: scroll.stride,
  web_scroll_frame_p95_ms: Math.round(sorted[Math.floor(sorted.length * 0.95)] * 10) / 10,
  web_scroll_frame_max_ms: Math.round(sorted[sorted.length - 1]),
  web_scroll_long_frames: gaps.filter(g => g > 50).length,
  errors,
};
mkdirSync('test/out', { recursive: true });
writeFileSync('test/out/perf-web.json', JSON.stringify(result, null, 1) + '\n');
console.log(JSON.stringify(result, null, 1));
await browser.close();
server.close();
process.exit(errors.length ? 1 : 0);
