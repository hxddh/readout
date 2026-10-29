// The first frame is final: once the page has painted a document, a place
// restored or a jump's landing, nothing it shows moves. For each case, from
// the first painted frame that shows it (the document not held for its
// code: enhance.js) for 1.5 s, the top on screen of the text the reader
// looks at (the block at the top, the block restored, the jump's target,
// find's match) and of every other block that frame shows. The shift is
// the largest distance any of them moved from where that frame showed it.
// A document opened shows no frame before the one that shows its place.
//
// (a) a 1 MB document (the corpus patches chained, as perf.test.mjs) opened
//     at the top, and opened with its place restored mid-document, on a
//     page just loaded; (b) places restored into a page that showed another
//     document (a pooled page taken), some with a diagram, a formula or
//     inline math on screen, and jumps onto those; (c) outline jumps, N and
//     find landing in a 5 MB document and in a code-heavy one (700 blocks
//     of 90-line code). The window's toolbar inset (52 px), a 900×900 window.
//
// Before the page kept its first frame (a9e7da3), in px (worst sample; the
// rest at most 0.4): a diagram on screen drawn after the frame, 894 (the
// diagram itself, or the blocks under it); inline math typeset after it, 12.
// A place restored into a page that showed another document: 6 frames of
// the document elsewhere (where the old place was) before its own.
//
// Usage: node test/shift.test.mjs   (after node build.mjs)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

// The most any case may shift, in px (rounding of a fractional position).
const MAX_SHIFT = 1;
const GATE = false;   // reported only, until the page keeps its first frame

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const BUILD = process.env.READOUT_WEB_BUILD || 'build/Web';
const server = http.createServer((req, res) => {
  const p = join(BUILD, decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
// The corpus patches' inserts chained into one document of `target` bytes; `from`: the file to start at.
function chain(target, from = 0) {
  const ops = [];
  let slot = 0, bytes = 0;
  const order = [...files.slice(from), ...files.slice(0, from)];
  for (let round = 0; bytes < target; round++) {
    for (const f of order) {
      const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
      for (const op of p.ops) {
        if (op.op !== 'insert') continue;
        ++slot;
        ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
        bytes += op.html.length;
      }
      if (bytes >= target) break;
    }
  }
  return ops;
}
const reset = (ops, version = 1, marks = []) => ({ version, reset: true, rewrite: false, ops, marks, deletions: [], toc: [], tasks: { done: 0, total: 0 } });
const esc = t => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const codeOp = (slot, n) => ({ op: 'insert', slot, after: slot - 1, kind: 'code',
  html: `<div class="code-block" data-lang="js"><pre><code>${esc(Array.from({ length: n }, (_, i) => `  const value${slot}_${i} = compute(${i}, "${'x'.repeat(i % 30)}"); // step ${i}`).join('\n'))}</code></pre></div>` });
const headOp = slot => ({ op: 'insert', slot, after: slot - 1, kind: 'heading', anchor: `h${slot}`, html: `<h2 id="h${slot}">Section ${slot}</h2>` });

const browser = await webkit.launch();
const errors = [];
let failures = 0;
const results = {};

async function newPage() {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(p, errors, `page ${Object.keys(results).length}: `);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  if (process.env.SHIFT_DEBUG) await p.addInitScript(() => { window.SHIFT_DEBUG = true; });
  await p.addInitScript(recorder);
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16, topInset: 52 }));
  // The highlighter up (as in a window: the app's warm-up), so a first paint waits for its code on screen.
  await p.evaluate(() => window.readout.warm());
  return p;
}

// In the page: shift(act, target) runs act(), then reads each frame as it
// is painted: in a resize observer made after the page's (its callback runs
// after the page's in the same frame, once the page has kept its place),
// watching an element that every frame resizes. (Read in a task after the
// frame instead, it would see the page as tasks run since have left it, not
// as painted.) target() is asked in each frame until the document shows and
// it is on screen: an element, or a function returning a rect (find's match).
// SHIFT_DEBUG=1: each frame's offsets and scroll position, the chunks whose
// size or class changed in a frame that shifted, and the page's trace.
function recorder() {
  window.shift = (act, target, ms = 1500) => new Promise(resolve => {
    const doc = document.getElementById('ro-doc');
    const inset = () => parseFloat(document.documentElement.style.getPropertyValue('--top-inset')) || 0;
    const rectOf = x => typeof x === 'function' ? x() : x && x.isConnected ? x.getBoundingClientRect() : null;
    const debug = !!window.SHIFT_DEBUG, log = [];
    const chunks = () => [...doc.children].map(c => `${c.className} ${Math.round(c.getBoundingClientRect().height)}`);
    // early: frames that showed the document before the first that shows the target.
    let tracked = null, first = 0, frames = 0, early = 0, was = null, done = false;
    const max = { px: 0, what: null, at: 0 };
    const probe = document.body.appendChild(document.createElement('div'));
    probe.style.cssText = 'position: fixed; top: 0; left: 0; width: 1px; height: 1px; visibility: hidden; pointer-events: none';
    const end = r => { done = true; observer.disconnect(); probe.remove(); resolve(r); };
    const read = () => {
      if (done) return;
      const now = performance.now();
      frames++;
      if (!tracked) {
        const t = !doc.classList.contains('hold') && target();
        const r = t && rectOf(t);
        if (!doc.classList.contains('hold') && !(r && r.bottom > inset() && r.top < innerHeight)) early++;
        else if (r) {
          first = now;
          tracked = [{ name: 'target', x: t, top: r.top }];
          // Every other block on screen (in the chunks on screen: one in a chunk skipped would be laid out to answer).
          const shown = r => r.bottom > inset() && r.top < innerHeight;
          for (const b of [...doc.children].filter(c => shown(c.getBoundingClientRect())).flatMap(c => [...c.children])) {
            const r = b.getBoundingClientRect();
            if (shown(r) && b !== t && b.classList.contains('blk')) tracked.push({ name: `slot ${b.dataset.slot} ${b.className}`, x: b, top: r.top });
          }
        }
      } else {
        const ds = tracked.map(t => { const r = rectOf(t.x); return r ? r.top - t.top : 0; });
        ds.forEach((d, i) => { if (Math.abs(d) > max.px) Object.assign(max, { px: Math.abs(d), what: tracked[i].name, at: Math.round(now - first) }); });
        if (debug && log.length < 200) {
          const cs = chunks(), moved = ds.some(d => Math.abs(d) >= 0.5);
          log.push(['F', Math.round(now - t0), Math.round(document.scrollingElement.scrollTop), ...ds.map(Math.round),
            ...(moved && was ? cs.map((c, i) => c !== was[i] ? `#${i}: ${was[i]} -> ${c}` : null).filter(Boolean).slice(0, 6) : [])]);
        }
      }
      if (debug) was = chunks();
      if (tracked && now - first >= ms) {
        end({ shift: Math.round(max.px * 10) / 10, what: max.what, at: max.at, firstFrame: Math.round(first - t0), frames, early,
          ...(debug ? { log, first: Math.round(first - t0), trace: window.readout.trace().filter(e => e.t >= t0).map(e => ({ ...e, t: Math.round(e.t - t0) })).slice(0, 60) } : {}) });
      } else if (!tracked && now - t0 > 8000) end({ shift: -1, what: 'never shown', frames });
    };
    const observer = new ResizeObserver(read);
    let w = 1;
    const tick = () => { if (done) return; probe.style.width = `${w = 3 - w}px`; requestAnimationFrame(tick); };
    const t0 = performance.now();
    act();
    observer.observe(probe);
    requestAnimationFrame(tick);
  });
  // The page still: nothing moved for 400 ms of frames, the main thread free.
  window.still = () => new Promise(resolve => {
    let y = -1, same = 0, t = performance.now();
    const tick = () => requestAnimationFrame(() => setTimeout(() => {
      const se = document.scrollingElement, now = performance.now();
      const key = se.scrollTop + se.scrollHeight * 1e6;
      same = key === y && now - t < 60 ? same + 1 : 0;
      y = key; t = now;
      if (same >= 8) resolve(); else tick();
    }, 0));
    tick();
  });
  // Block `slot`, its top: as find's match is, the target of a jump.
  window.blk = slot => () => document.querySelector(`#ro-doc .blk[data-slot="${slot}"]`);
}

// `rs`: the case's samples; it shifts as much as the worst of them. A
// document opened (`opens`) shows no frame before the one with its place.
function report(name, ...rs) {
  const r = rs.reduce((a, b) => (b.shift < 0 || a.shift < 0 ? (b.shift < 0 ? b : a) : b.shift > a.shift ? b : a));
  for (const x of rs) if (x.log && x.shift > MAX_SHIFT) console.log('  ', JSON.stringify({ first: x.first, log: x.log, trace: x.trace }));
  for (const x of rs) { delete x.log; delete x.trace; delete x.first; }
  const early = Math.max(...rs.map(x => x.opens ? x.early : 0));
  const bad = r.shift < 0 || r.shift > MAX_SHIFT || early > 0;
  console.log(`${GATE && bad ? 'FAIL' : bad ? 'shift' : 'ok'}: ${name}: ${r.shift} px [${rs.map(x => x.shift).join(', ')}] (first frame at ${r.firstFrame} ms${r.shift > 0 ? `; ${r.what}, ${r.at} ms after it` : ''}${early ? `; ${early} frames before it showed the document elsewhere` : ''})`);
  if (GATE && bad) failures++;
  results[name] = { ...r, samples: rs.map(x => x.shift) };
}

// What the app sends to restore a place: the block, its top `offset` px above the top of the view.
const restore = (p, ops, version, slot, offset) => p.evaluate(([d, a]) => window.shift(() => { window.readout.apply(d); window.readout.scrollToAnchor(a); },
  () => document.querySelector(`#ro-doc .blk[data-slot="${a.slot}"]`)), [reset(ops, version), { slot, offset, ratio: 0 }]).then(r => ({ ...r, opens: true }));

// Blocks drawn after they are set up: a diagram, a formula, a paragraph with
// inline math (and the chain to look for one in, from that corpus file on).
const drawn = [[3, o => o.kind === 'mermaid'], [9, o => o.kind === 'math'], [12, o => o.kind === 'paragraph' && /class="math/.test(o.html)]];

// ---- (a) open, (b) restore into a page that showed another document
const mb1 = chain(1_000_000);
const mid = ops => ops[Math.floor(ops.length * 0.5)].slot;
{
  const p = await newPage();
  // (The block at the top under the toolbar, in the frame that first shows the document.)
  report('open 1 MB at top', await p.evaluate(d => window.shift(() => window.readout.apply(d),
    () => { const a = window.readout.captureAnchor(); return a && document.querySelector(`#ro-doc .blk[data-slot="${a.slot}"]`); }), reset(mb1)));
  await p.close();
}
{
  const p = await newPage();
  report('open 1 MB, place restored mid-document', await restore(p, mb1, 1, mid(mb1), -120));
  await p.evaluate(() => window.still());
  // The next documents in the same page (other files, a pooled page taken), their places restored further down and up.
  const samples = [];
  for (const [k, f] of [[7, 0.7], [15, 0.3], [22, 0.85]]) {
    const other = chain(1_000_000, k);
    samples.push(await restore(p, other, 2 + samples.length, other[Math.floor(other.length * f)].slot, -40));
    await p.evaluate(() => window.still());
  }
  report('restore into a page that showed another document', ...samples);
  // Places restored with a diagram, a formula and inline math on screen
  // above them (drawn after the frame that shows them), each block 400 px
  // down the screen, in that page.
  const beside = [];
  for (const [k, test] of drawn) {
    const other = chain(1_000_000, k);
    const i = other.findIndex((o, j) => j > other.length * 0.3 && test(o));
    beside.push(await restore(p, other, 10 + beside.length, other[i + 1].slot, -400));
    await p.evaluate(() => window.still());
  }
  report('restore beside a diagram, a formula, inline math', ...beside);
  await p.close();
}
{
  // Jumps from the top onto the block before a diagram, a formula and
  // inline math (in a page that has drawn none: drawings are kept).
  const p = await newPage();
  const ops = chain(1_000_000, 3);
  await p.evaluate(d => window.readout.apply(d), reset(ops));
  const beside = [];
  for (const [, test] of drawn) {
    await p.evaluate(() => window.scrollTo(0, 0));
    await p.evaluate(() => window.still());
    const i = ops.findIndex((o, j) => j > ops.length * 0.3 && test(o));
    beside.push(await p.evaluate(slot => window.shift(() => window.readout.scrollToSlot(slot), window.blk(slot)), ops[i - 1].slot));
  }
  report('jump beside a diagram, a formula, inline math', ...beside);
  await p.close();
}

// ---- (c) jumps
async function jumps(p, label, ops, words) {
  const frames = () => p.evaluate(() => window.still());
  const top = async () => { await p.evaluate(() => window.scrollTo(0, 0)); await frames(); };
  // Outline clicks from the top onto the headings 30%, 55% and 80% down.
  const outline = [];
  for (const f of [0.3, 0.55, 0.8]) {
    await top();
    outline.push(await p.evaluate(f => {
      const hs = document.querySelectorAll('#ro-doc > .chunk > .blk.k-heading');
      const slot = +hs[Math.floor(hs.length * f)].dataset.slot;
      return window.shift(() => window.readout.scrollToSlot(slot), window.blk(slot));
    }, f));
  }
  report(`${label}: outline jump`, ...outline);
  // N from the top through the unread changes 30%, 55% and 80% down.
  await top();
  const marks = [0.3, 0.55, 0.8].map(f => ({ slot: ops[Math.floor(ops.length * f)].slot, kind: 'inserted' }));
  await p.evaluate(m => window.readout.apply({ version: 50, reset: false, rewrite: false, ops: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, marks: m }), marks);
  await frames();
  const n = [];
  for (const m of marks) { n.push(await p.evaluate(slot => window.shift(() => window.readout.nextChange(), window.blk(slot)), m.slot)); await frames(); }
  report(`${label}: N`, ...n);
  // Find landing from the top on words only one block has: the match itself.
  const found = [];
  for (const w of words) {
    await top();
    found.push(await p.evaluate(w => window.shift(() => window.readout.find(w), () => {
      const r = [...(CSS.highlights.get('ro-find-cur') || [])][0];
      if (!r || !r.startContainer.isConnected) return null;
      return () => { const g = document.createRange(); g.setStart(r.startContainer, r.startOffset); g.setEnd(r.endContainer, r.endOffset); return g.getBoundingClientRect(); };
    }), w));
    await p.evaluate(() => window.readout.findEnd());
  }
  report(`${label}: find landing`, ...found);
}
{
  const ops = chain(5_000_000);
  // Words of their own in paragraphs 40% and 65% down.
  for (const [f, w] of [[0.4, 'Quuxfirst'], [0.65, 'Quuxsecond']]) {
    const at = ops.findIndex((o, i) => i >= ops.length * f && o.kind === 'paragraph' && o.html.startsWith('<p>'));
    ops[at] = { ...ops[at], html: ops[at].html.replace('<p>', `<p>${w} `) };
  }
  const p = await newPage();
  await p.evaluate(d => new Promise(r => { window.readout.apply(d); requestAnimationFrame(() => setTimeout(r, 0)); }), reset(ops));
  await p.evaluate(() => window.still());
  await jumps(p, '5 MB', ops, ['Quuxfirst', 'Quuxsecond']);
  await p.close();
}
{
  const ops = Array.from({ length: 700 }, (_, k) => k % 10 === 0 ? headOp(k + 1) : codeOp(k + 1, 90));
  const p = await newPage();
  await p.evaluate(d => window.readout.apply(d), reset(ops));
  await p.evaluate(() => window.still());
  // Line 40 of the code blocks 40% and 65% down.
  await jumps(p, 'code-heavy', ops, ['value282_40', 'value456_40']);
  await p.close();
}

await browser.close();
server.close();
mkdirSync('test/out', { recursive: true });
writeFileSync('test/out/shift.json', JSON.stringify(results, null, 2));
for (const e of errors) { console.log(`FAIL: page error: ${e}`); failures++; }
if (failures) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log('shift: done');
