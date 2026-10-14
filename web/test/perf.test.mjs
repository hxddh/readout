// Page-side performance of a large document, in WebKit.
//
// Builds a ~1 MB document by chaining the real-agent corpus patches, then
// measures: the first apply, a 20-block update patch on top of it, and frame
// pacing while scrolling through the whole page. Writes the numbers to
// test/out/perf-web.json; tools/perf-assert.py checks them against
// tools/perf-budgets.json.
//
// Usage: node test/perf.test.mjs
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';

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
// WebKit reports a ResizeObserver loop when observed blocks change size again
// while it delivers (here: content-visibility blocks laid out by the forced
// layout this test adds after each apply). It is a notice, not a failure.
page.on('pageerror', e => { if (!/ResizeObserver loop/.test(String(e))) errors.push(String(e)); });
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

const median = xs => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];

// First apply of the whole document, timed in the page: the apply, then
// style and layout of the page (forced by reading its height), which the
// browser would otherwise do before the first paint; and until the frame
// that shows it has been painted (the moment the page reports 'painted':
// a task queued from the frame's animation callbacks runs after its paint).
const firstApply = await page.evaluate(p => new Promise(resolve => {
  const t0 = performance.now();
  window.readout.apply(p);
  const sync = performance.now() - t0;
  void document.scrollingElement.scrollHeight;
  const laidOut = performance.now() - t0;
  requestAnimationFrame(() => setTimeout(() => resolve({ sync, laidOut, painted: performance.now() - t0 }), 0));
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

const result = {
  web_doc_bytes: bytes,
  web_doc_blocks: ops.length,
  web_first_apply_1mb_ms: Math.round(firstApply.laidOut),
  web_first_apply_1mb_sync_ms: Math.round(firstApply.sync),
  web_first_apply_1mb_painted_ms: Math.round(firstApply.painted),
  web_update_20_blocks_1mb_ms: Math.round(median(updates) * 10) / 10,
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
