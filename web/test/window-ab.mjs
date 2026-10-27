// Spike A/B (m16/proto-window): the go/no-go numbers for the windowed
// renderer against a 3.9.1 build, one build per process.
// Usage: node test/window-ab.mjs <build dir> [5mb] [huge] [scroll] [drift]
// Prints one JSON object. Scenarios match perf.test.mjs where it has them.
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { execSync } from 'node:child_process';
import { instrument, scrollPasses, summary, interactions, insertMiddle } from './window-scrollperf.mjs';

const dir = process.argv[2];
const want = new Set(process.argv.slice(3));
const all = !want.size;
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => {
  const p = join(dir, decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
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
function webProcesses() {
  const rows = execSync('ps -eo pid,ppid,comm', { encoding: 'utf8' }).trim().split('\n').slice(1).map(l => l.trim().split(/\s+/));
  const kids = new Map();
  for (const [pid, ppid] of rows) kids.set(ppid, [...(kids.get(ppid) || []), pid]);
  const mine = new Set(), queue = [String(process.pid)];
  while (queue.length) for (const k of kids.get(queue.pop()) || []) { mine.add(k); queue.push(k); }
  return rows.filter(r => mine.has(r[0]) && /WebProces/.test(r[2])).map(r => r[0]);
}
function privateMemoryMB(pid) {
  try {
    const t = readFileSync(`/proc/${pid}/smaps_rollup`, 'utf8');
    const kb = k => +(t.match(new RegExp(`^${k}:\\s+(\\d+)`, 'm'))?.[1] || 0);
    return Math.round((kb('Private_Dirty') + kb('Private_Clean')) / 1024);
  } catch { return null; }
}

const browser = await webkit.launch();
const errors = [];
async function openPage(inset = 0) {
  const before = new Set(webProcesses());
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  p.on('pageerror', e => errors.push(String(e).slice(0, 300)));
  await instrument(p);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => { window.__msgs.push(m); if (m.type === 'error') console.error(m.message); } } } };
  });
  p.on('console', m => { if (m.type() === 'error') errors.push(m.text().slice(0, 300)); });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(inset => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, topInset: inset }), inset);
  const pid = webProcesses().find(x => !before.has(x));
  return { p, pid };
}
const reset = ops => ({ version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
const out = {};

// Per-step drift while scrolling: 40 steps of `dy`, one per frame; how far the
// text under the middle of the window moved beyond the scroll (max and sum).
const scrollDrift = (p, from, dy) => p.evaluate(({ from, dy }) => new Promise(async resolve => {
  const settle = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300))));
  for (let k = 0; k < 2; k++) { window.scrollTo(0, from * document.scrollingElement.scrollHeight); await settle(); }
  let sum = 0, max = 0, steps = 0, el = null, top = 0, y0 = 0;
  const after = () => {
    if (el) {
      // The text should move by the reader's scroll alone (compensation scrolls are the page keeping it there); a step clamped at an end is not counted.
      const se = document.scrollingElement, clamped = y0 + dy < 0 || y0 + dy > se.scrollHeight - innerHeight;
      const d = clamped ? 0 : Math.abs(el.getBoundingClientRect().top - top + dy);
      sum += d; max = Math.max(max, d); steps++;
    }
    if (steps >= 40) return resolve({ sum: Math.round(sum), max: Math.round(max * 10) / 10 });
    el = document.elementFromPoint(450, 450).closest('.blk');
    top = el.getBoundingClientRect().top;
    y0 = document.scrollingElement.scrollTop;
    requestAnimationFrame(() => { window.scrollBy(0, dy); requestAnimationFrame(() => setTimeout(after, 0)); });
  };
  after();
}), { from, dy });

if (all || want.has('5mb')) {
  const { p, pid } = await openPage();
  const doc5 = chain(5_000_000);
  const t = await p.evaluate(d => new Promise(r => { const t0 = performance.now(); window.readout.apply(d); const s = performance.now() - t0; requestAnimationFrame(() => setTimeout(() => r({ sync: s, painted: performance.now() - t0 }), 0)); }), reset(doc5.ops));
  await p.waitForTimeout(1000);
  out.mb5_open_mb = privateMemoryMB(pid);
  await p.evaluate(n => window.readout.apply({ version: 90, reset: false, rewrite: false, ops: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
    marks: Array.from({ length: 200 }, (_, k) => ({ slot: Math.floor((k + 0.5) * n / 200), kind: 'inserted' })) }), doc5.ops.length);
  await p.waitForTimeout(500);
  const s = summary(await scrollPasses(p));
  await p.waitForTimeout(2000);
  out.mb5_blocks = doc5.ops.length;
  out.mb5_first_apply_ms = Math.round(t.sync);
  out.mb5_first_painted_ms = Math.round(t.painted);
  out.mb5_scrolled_mb = privateMemoryMB(pid);
  out.mb5_scroll = s;
  const act = await interactions(p);
  out.mb5_theme_ms = Math.round(act.theme);
  out.mb5_find_count = act.findCount;
  out.mb5_elements = await p.evaluate(() => document.getElementsByTagName('*').length);
  out.mb5_insert_middle_ms = Math.round(await insertMiddle(p, doc5.ops, doc5.ops.length + 1000) * 10) / 10;
  // Far inserts and removes, above (10%) and below (60%) a reader at 35%: how far the reader's text moves.
  await p.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight * 0.35));
  await p.waitForTimeout(800);
  out.mb5_far_edit_drift_px = await p.evaluate(async ({ n, base }) => {
    const settle = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 50))));
    let max = 0, s = base;
    for (const frac of [0.1, 0.6]) for (let i = 0; i < 6; i++) {
      const after = Math.floor(n * frac) + i * 7;
      const slots = [++s, ++s, ++s];
      const add = slots.map((x, k) => ({ op: 'insert', slot: x, after: k ? slots[k - 1] : after, kind: 'paragraph', html: `<p>Inserted ${x} by the agent far from the reader, long enough to wrap: ${'word '.repeat(40)}</p>` }));
      for (const ops of [add, slots.map(x => ({ op: 'remove', slot: x })), [{ op: 'replace', slot: after + 2, change: 'content', kind: 'paragraph', html: `<p>Rewritten ${'longer '.repeat(60)}</p>` }]]) {
        const el = document.elementFromPoint(450, 450).closest('.blk'), top = el.getBoundingClientRect().top;
        window.readout.apply({ version: 5000 + s + ops.length, reset: false, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
        await settle();
        max = Math.max(max, Math.abs(el.getBoundingClientRect().top - top));
      }
    }
    return Math.round(max * 10) / 10;
  }, { n: doc5.ops.length, base: doc5.ops.length + 5000 });
  out.mb5_drift_down = await scrollDrift(p, 0.3, 400);
  out.mb5_drift_up = await scrollDrift(p, 0.7, -400);
  await p.close();
}

if (all || want.has('huge')) {
  const esc = t => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const codeOp = (slot, n) => ({ op: 'insert', slot, after: slot - 1, kind: 'code',
    html: `<div class="code-block" data-lang="js"><pre><code>${esc(Array.from({ length: n }, (_, i) => `  const value${slot}_${i} = compute(${i}, "${'x'.repeat(i % 30)}"); // step ${i}`).join('\n'))}</code></pre></div>` });
  const paraOp = slot => ({ op: 'insert', slot, after: slot - 1, kind: 'paragraph', html: `<p>Paragraph ${slot} of the plan, with enough words to wrap over a line or two in the narrow column.</p>` });
  const headOp = slot => ({ op: 'insert', slot, after: slot - 1, kind: 'heading', anchor: `h${slot}`, html: `<h2 id="h${slot}">Section ${slot}</h2>` });
  const docOps = Array.from({ length: 3000 }, (_, k) => k === 1500 ? codeOp(k + 1, 28000) : k === 2 ? codeOp(k + 1, 3) : k % 20 === 0 ? headOp(k + 1) : paraOp(k + 1));
  const { p, pid } = await openPage(52);
  await p.evaluate(d => window.readout.apply(d), reset(docOps));
  await p.waitForTimeout(1500);
  const slot = 1501;
  const landed = await p.evaluate(slot => new Promise(async resolve => {
    window.scrollTo(0, 0);
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300))));
    const t0 = performance.now();
    window.readout.scrollToSlot(slot);
    const call = performance.now() - t0;
    const gaps = [];
    let last = t0, plain = null, blank = null;
    const frame = now => {
      gaps.push(now - last);
      last = now;
      if (plain === null) {
        const cb = document.querySelector(`.blk[data-slot="${slot}"] .code-block`);
        const r = cb.getBoundingClientRect();
        const lines = [...cb.querySelectorAll('pre .line')].filter(l => { const r = l.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight; });
        plain = lines.filter(l => l.textContent.trim() && !l.querySelector('span[style]')).length;
        const shown = Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(52, r.top));
        const covered = lines.reduce((a, l) => { const q = l.getBoundingClientRect(); return a + Math.max(0, Math.min(innerHeight, q.bottom) - Math.max(52, q.top)); }, 0);
        blank = Math.round(Math.max(0, shown - covered - 40));   // (the block's padding and tools)
        if (!lines.length && shown) plain = Math.round(shown / 20);
      }
      if (now - t0 < 3000) requestAnimationFrame(frame); else resolve({ longest: Math.max(...gaps), plain, blank, call, top: document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().top });
    };
    requestAnimationFrame(frame);
  }), slot);
  out.huge_land_longest_ms = Math.round(landed.longest);
  out.huge_land_call_ms = Math.round(landed.call);
  out.huge_land_plain_lines = landed.plain;
  out.huge_land_blank_px = landed.blank;
  out.huge_land_top = Math.round(landed.top);
  out.huge_scroll = summary(await scrollPasses(p, { inset: 52 }));
  out.huge_mb = privateMemoryMB(pid);
  const act = await interactions(p);
  out.huge_theme_ms = Math.round(act.theme);
  await p.close();
}

if (all || want.has('scroll')) {
  for (const [k, ops] of [['kb500', chain(500_000, true).ops], ['mb1', chain(1_000_000).ops]]) {
    const { p, pid } = await openPage(52);
    await p.evaluate(d => window.readout.apply(d), reset(ops));
    await p.waitForTimeout(1500);
    out[`${k}_scroll`] = summary(await scrollPasses(p, { inset: 52 }));
    out[`${k}_mb`] = privateMemoryMB(pid);
    out[`${k}_drift_up`] = await scrollDrift(p, 1, -400);
    out[`${k}_drift_down`] = await scrollDrift(p, 0.1, 400);
    await p.close();
  }
}

out.errors = errors.slice(0, 10);
console.log(JSON.stringify(out));
await browser.close();
server.close();
