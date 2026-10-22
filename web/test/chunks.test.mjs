// Chunk accounting under random agent writes (chunks.js, patch.js, marks.js):
// a fixed set of seeded runs of patches away from the reader (blocks written,
// rewritten and removed, removal markers coming and going, the reader
// jumping around), with invariants checked after every patch:
//   1. the reader's text does not move (within 1 px);
//   2. a page whose changes are removals only is as tall skipped as laid out
//      (within 2 px): a chunk laid out and skipped since loses what it held
//      (a written block counts at its estimate until laid out, so this is
//      checked on the removal runs);
//   3. no chunk holds more than 64 items, none is empty, and once the page
//      has been scrolled through and is quiet, none past its height cap;
//   4. the blocks are in the document's order.
// Usage: node test/chunks.test.mjs  (requires web/build.mjs to have run;
// READOUT_WEB_BUILD serves another build)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const dir = process.env.READOUT_WEB_BUILD || 'build/Web';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' };
const server = http.createServer((req, res) => {
  const p = join(dir, decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await webkit.launch();
const errors = [];
let failures = 0;
const check = (name, ok, detail = '') => { if (ok) console.log(`ok: ${name}`); else { failures++; console.log(`FAIL: ${name} ${detail}`); } };

async function openPage() {
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  for (let i = 0; i < 200 && !await page.evaluate(() => !!window.readout && window.__msgs.some(m => m.type === 'ready')); i++) await page.waitForTimeout(25);
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  return page;
}
const settled = async page => {
  for (let i = 0; i < 100; i++) {
    const still = await page.evaluate(() => new Promise(r => {
      const at = () => JSON.stringify([document.scrollingElement.scrollTop, document.scrollingElement.scrollHeight]);
      const a = at();
      requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(() => r(at() === a))));
    }));
    if (still) return;
  }
};
const patch = (version, ops, extra = {}) => ({ version, reset: false, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ...extra });
// The page's height as it is, and with every chunk laid out (not skipped, no stale size).
const heights = page => page.evaluate(() => {
  const st = document.createElement('style');
  st.textContent = '#ro-doc.cv > .chunk, #ro-doc.cv > .chunk:not(.near), #ro-doc.cv > .chunk.stale:not(.near) { content-visibility: visible !important; height: auto !important; }';
  const skipped = document.scrollingElement.scrollHeight;
  document.head.appendChild(st);
  const laid = document.scrollingElement.scrollHeight;
  st.remove();
  void document.scrollingElement.scrollHeight;
  return { skipped, laid };
});

/**
 * One seeded run: 400 blocks (paragraphs, headings, rules, code), every
 * chunk laid out once when `layAll`, then `rounds` patches of 1 to 4 changes
 * each, all at least a screen from the reader. `removals`: only removals.
 */
async function run(seed, rounds, { removals = false, layAll = false } = {}) {
  let s = seed;
  const rnd = () => (s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const ri = n => Math.floor(rnd() * n);
  const page = await openPage();
  let next = 1;
  const order = [];
  const block = slot => {
    const k = ri(10);
    if (k === 0) return { kind: 'heading', html: `<h2 id="h${slot}">Heading ${slot}</h2>`, anchor: `h${slot}` };
    if (k === 1) return { kind: 'rule', html: '<hr>' };
    if (k === 2) return { kind: 'code', html: '<div class="code-block" data-lang="text"><pre><code>' + Array.from({ length: 1 + ri(40) }, (_, i) => 'code line ' + i).join('\n') + '</code></pre></div>' };
    return { kind: 'paragraph', html: `<p>p${slot} ` + 'word '.repeat(5 + ri(150)) + '</p>' };
  };
  const ops = [];
  for (let i = 0, prev = 0; i < 400; i++) { const sl = next++; ops.push({ op: 'insert', slot: sl, after: prev, ...block(sl) }); order.push(sl); prev = sl; }
  await page.evaluate(p => window.readout.apply(p), { ...patch(1, ops), reset: true });
  await settled(page);
  if (layAll) {
    const H = await page.evaluate(() => document.scrollingElement.scrollHeight);
    for (let y = 0; y < H + 2000; y += 500) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(20); }
    await settled(page);
  }
  const where = sl => page.evaluate(sl => {
    const e = document.querySelector(`[data-slot="${sl}"]`);
    if (!e) return null;
    const r = (e.checkVisibility({ contentVisibilityAuto: true }) ? e : e.parentElement).getBoundingClientRect();
    return { top: r.top, bottom: r.bottom };
  }, sl);
  const bad = [];
  let dels = [], delId = 1, v = 2, patches = 0;
  for (let round = 0; round < rounds; round++) {
    if (ri(4) === 0) { await page.evaluate(f => window.scrollTo(0, f * (document.scrollingElement.scrollHeight - innerHeight)), rnd()); await settled(page); await page.waitForTimeout(50); await settled(page); }
    const anchor = await page.evaluate(() => {
      const a = window.readout.captureAnchor();
      if (!a) return null;
      return { slot: a.slot, top: document.querySelector(`[data-slot="${a.slot}"]`).getBoundingClientRect().top, y: scrollY };
    });
    if (!anchor || anchor.y <= 0) continue;
    const pops = [], desc = [];
    for (let k = 1 + ri(4); k > 0; k--) {
      const i = ri(order.length), sl = order[i];
      const w = await where(sl);
      if (!w || (w.bottom > -700 && w.top < 1400)) continue;
      const t = removals ? 1 : ri(3);
      if (t === 0) { const ns = next++; pops.push({ op: 'insert', slot: ns, after: sl, ...block(ns) }); order.splice(i + 1, 0, ns); desc.push(`insert after ${sl}`); }
      else if (t === 1 && sl !== anchor.slot && order.length > 300) {
        pops.push({ op: 'remove', slot: sl });
        order.splice(i, 1);
        if (ri(2)) dels.push({ id: delId++, after: order[i - 1] || 0, count: 1, preview: 'x' });
        desc.push(`remove ${sl}`);
      }
      else if (t === 2) { pops.push({ op: 'replace', slot: sl, change: 'content', ...block(sl) }); desc.push(`replace ${sl}`); }
    }
    dels = dels.filter(d => d.after === 0 || order.includes(d.after));
    if (ri(5) === 0 && dels.length) dels.splice(ri(dels.length), 1);
    if (!pops.length) continue;
    const h0 = removals ? await heights(page) : null;
    const around = () => process.env.DEBUG && page.evaluate(sls => sls.map(sl => { const e = document.querySelector(`[data-slot="${sl}"]`); if (!e) return [sl, 'gone']; const c = e.parentElement; return [sl, e.className, [...c.children].indexOf(e), c.childElementCount, c.className, e.previousElementSibling?.className, e.nextElementSibling?.className, c.nextElementSibling?.firstElementChild?.className]; }), pops.map(o => o.slot).flatMap(sl => { const i = order.indexOf(sl); return [order[i - 1], sl, order[i], order[i + 1]].filter(Boolean); }));
    const dbg0 = await around();
    await page.evaluate(p => window.readout.apply(p), patch(v++, pops, { deletions: dels }));
    patches++;
    await settled(page); await page.waitForTimeout(30); await settled(page);
    const top = await page.evaluate(sl => document.querySelector(`[data-slot="${sl}"]`)?.getBoundingClientRect().top, anchor.slot);
    const st = await page.evaluate(() => ({
      dom: [...document.querySelectorAll('#ro-doc > .chunk > .blk')].map(e => +e.dataset.slot),
      items: [...document.querySelectorAll('#ro-doc > .chunk')].map(c => c.childElementCount),
    }));
    const h = removals ? await heights(page) : null;
    const why = [];
    if (Math.abs(top - anchor.top) > 1) why.push(`the reader moved ${(top - anchor.top).toFixed(1)} px`);
    if (removals && h0.skipped === h0.laid && Math.abs(h.skipped - h.laid) > 2) why.push(`${h.skipped - h.laid} px taller skipped than laid out`);
    if (Math.max(...st.items) > 64 || st.items.includes(0)) why.push(`chunk items ${Math.max(...st.items)}, empty ${st.items.includes(0)}`);
    if (JSON.stringify(st.dom) !== JSON.stringify(order)) why.push('blocks out of order');
    if (why.length) bad.push(`round ${round} (${desc.join(', ')}): ${why.join('; ')}`);
    if (why.length && process.env.DEBUG) console.log(JSON.stringify({ dbg0, dbg1: await around(), dels: dels.slice(-3) }));
  }
  // Scrolled through and quiet: every chunk within its limits.
  const H = await page.evaluate(() => document.scrollingElement.scrollHeight);
  for (let y = 0; y < H + 2000; y += 500) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(20); }
  await page.waitForTimeout(2800);   // the rebalance (600 ms, again 2 s later)
  const over = await page.evaluate(() => window.readout.lazyHeld().overfull);
  if (over) bad.push(`${over} chunks past their limits once quiet`);
  await page.close();
  return { patches, bad };
}

for (const seed of process.env.SEEDS ? [] : [1, 2, 3, 4, 5, 6, 7, 8]) {
  const r = await run(seed, 150, { layAll: seed % 2 === 0 });
  check(`seed ${seed}: ${r.patches} patches of writes, rewrites and removals away from the reader keep its place, the chunks' limits and the order`,
    r.bad.length === 0 && r.patches > 40, JSON.stringify(r.bad.slice(0, 5)));
}
for (const seed of process.env.SEEDS ? process.env.SEEDS.split(',').map(Number) : [11, 12, 13, 14]) {
  const r = await run(seed, 80, { removals: true, layAll: true });
  check(`seed ${seed}: ${r.patches} patches of removals (markers coming and going) in a page laid out once: as tall skipped as laid out, the reader still`,
    r.bad.length === 0 && r.patches > 20, JSON.stringify(r.bad.slice(0, 5)));
}

await browser.close();
server.close();
if (errors.length) { failures++; console.log('page errors:', errors.slice(0, 5)); }
console.log(failures ? `${failures} chunk checks failed` : 'all chunk checks passed');
process.exit(failures ? 1 : 0);
