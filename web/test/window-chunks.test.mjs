// Spike (m16/proto-window): chunks.test.mjs with the windowed renderer's parked chunks
// (their blocks out of the page: positions, order and counts asked of the page's model).
// Chunk accounting under random agent writes (chunks.js, patch.js, marks.js):
// a fixed set of seeded runs of patches away from the reader (blocks written,
// rewritten and removed, removal markers coming and going, the reader
// jumping around), with invariants checked after every patch:
//   1. the reader's text does not move (within 1 px);
//   2. a page whose changes are removals only is as tall skipped as laid out
//      at the end (within 2 px): a chunk laid out and skipped since loses
//      what it held (a written block counts at its estimate until laid out,
//      so this is checked on the removal runs);
//   3. no chunk holds more than 64 items, none is empty, and once the page
//      has been scrolled through and is quiet, none past its height cap;
//   4. the blocks are in the document's order;
//   5. a selection and focus the reader holds stay as they were.
// Also: long code (the height cap), the page becoming large in a patch, and
// writes on screen.
// Usage: node test/chunks.test.mjs  (requires web/build.mjs to have run;
// SEEDS=1,21 runs only those; READOUT_WEB_BUILD serves another build)
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
  window.readout.mountAll?.();
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
 * One seeded run: `start` blocks (paragraphs, headings, rules, code; with
 * `longCode`, some code blocks of 500 to 800 lines), every chunk laid out
 * once when `layAll`, then `rounds` patches of 1 to 4 changes each, at
 * least `guard` px from the screen (0: anywhere but the reader's own
 * block). `removals`: only removals, the heights compared at the end (a
 * comparison lays every chunk out: done each round it could hide a drift).
 * `hold`: in some rounds the reader holds a selection in one block and the
 * focus on another (what an agent writes must not move them). `grow`: no
 * removals until the page is past 260 blocks (from below 250: the page
 * becomes large in a patch).
 */
async function run(seed, rounds, { removals = false, layAll = false, start = 400, longCode = false, guard = 700, hold = false, grow = false } = {}) {
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
    if (k === 2) return { kind: 'code', html: '<div class="code-block" data-lang="text"><pre><code>' + Array.from({ length: longCode && ri(3) === 0 ? 500 + ri(300) : 1 + ri(40) }, (_, i) => 'code line ' + i).join('\n') + '</code></pre></div>' };
    return { kind: 'paragraph', html: `<p>p${slot} ` + 'word '.repeat(5 + ri(150)) + '</p>' };
  };
  const ops = [];
  for (let i = 0, prev = 0; i < start; i++) { const sl = next++; ops.push({ op: 'insert', slot: sl, after: prev, ...block(sl) }); order.push(sl); prev = sl; }
  await page.evaluate(p => window.readout.apply(p), { ...patch(1, ops), reset: true });
  await settled(page);
  if (layAll) {
    const H = await page.evaluate(() => document.scrollingElement.scrollHeight);
    for (let y = 0; y < H + 2000; y += 500) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(20); }
    await settled(page);
  }
  const h0 = removals ? await heights(page) : null;
  const where = sl => page.evaluate(sl => {
    const e = document.querySelector(`[data-slot="${sl}"]`);
    // Not in the page: in a parked chunk, away from the screen.
    if (!e) return window.readout.windowProbe?.().order.includes(sl) ? { top: 1e9, bottom: 1e9 } : null;
    const r = (e.checkVisibility({ contentVisibilityAuto: true }) ? e : e.parentElement).getBoundingClientRect();
    return { top: r.top, bottom: r.bottom };
  }, sl);
  const bad = [];
  let dels = [], delId = 1, v = 2, patches = 0, held = null, crossed = false, parkedSeen = 0;
  for (let round = 0; round < rounds; round++) {
    if (ri(4) === 0) { await page.evaluate(f => window.scrollTo(0, f * (document.scrollingElement.scrollHeight - innerHeight)), rnd()); await settled(page); await page.waitForTimeout(50); await settled(page); }
    // The reader takes hold of a selection and the focus on screen, or lets go.
    if (hold && ri(3) === 0) {
      held = await page.evaluate(take => {
        getSelection().removeAllRanges();
        document.activeElement?.blur();
        if (!take) return null;
        const on = [...document.querySelectorAll('#ro-doc > .chunk.near > .blk')].filter(b => { const r = b.getBoundingClientRect(); return r.bottom > 60 && r.top < innerHeight - 60; });
        if (on.length < 3) return null;
        const t = on[0].querySelector('p, li, code, h2')?.firstChild;
        if (t?.nodeType === 3 && t.length > 3) getSelection().setBaseAndExtent(t, 0, t, 3);
        const f = on.at(-1);
        f.tabIndex = -1;
        f.focus({ preventScroll: true });
        return { sel: getSelection().toString(), focus: f.dataset.slot };
      }, ri(2) === 0);
    }
    const anchor = await page.evaluate(() => {
      const a = window.readout.captureAnchor();
      if (!a) return null;
      return { slot: a.slot, top: document.querySelector(`[data-slot="${a.slot}"]`).getBoundingClientRect().top, y: scrollY };
    });
    if (!anchor || anchor.y <= 0) continue;
    const pops = [], desc = [];
    for (let k = 1 + ri(4); k > 0; k--) {
      const i = ri(order.length), sl = order[i];
      if (sl === anchor.slot || (held && String(sl) === held.focus)) continue;
      const w = await where(sl);
      if (!w || (guard && w.bottom > -guard && w.top < 700 + guard)) continue;
      const t = removals ? 1 : grow && order.length <= 260 ? 0 : ri(3);
      if (t === 0) { const ns = next++; pops.push({ op: 'insert', slot: ns, after: sl, ...block(ns) }); order.splice(i + 1, 0, ns); desc.push(`insert after ${sl}`); }
      else if (t === 1 && order.length > Math.min(300, start - 100)) {
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
    const cv0 = await page.evaluate(() => document.getElementById('ro-doc').classList.contains('cv'));
    await page.evaluate(p => window.readout.apply(p), patch(v++, pops, { deletions: dels }));
    patches++;
    await settled(page); await page.waitForTimeout(30); await settled(page);
    const top = await page.evaluate(sl => document.querySelector(`[data-slot="${sl}"]`)?.getBoundingClientRect().top, anchor.slot);
    const st = await page.evaluate(() => ({
      dom: window.readout.windowProbe().order,
      items: window.readout.windowProbe().counts,
      parked: window.readout.windowProbe().parked,
      cv: document.getElementById('ro-doc').classList.contains('cv'),
      sel: getSelection().toString(), focus: document.activeElement?.dataset?.slot,
    }));
    if (!cv0 && st.cv) crossed = true;
    const why = [];
    if (Math.abs(top - anchor.top) > 1) why.push(`the reader moved ${(top - anchor.top).toFixed(1)} px`);
    if (Math.max(...st.items) > 64 && !held) why.push(`a chunk of ${Math.max(...st.items)} items`);
    if (st.items.includes(0)) why.push('an empty chunk');
    if (JSON.stringify(st.dom) !== JSON.stringify(order)) why.push('blocks out of order');
    if (held && (st.sel !== held.sel || st.focus !== held.focus)) why.push(`the reader's selection or focus changed (${JSON.stringify([held, st.sel, st.focus])})`);
    parkedSeen = Math.max(parkedSeen, st.parked);
    if (why.length) bad.push(`round ${round} (${desc.join(', ')}): ${why.join('; ')}`);
  }
  await page.evaluate(() => { getSelection().removeAllRanges(); document.activeElement?.blur(); });
  if (removals) {
    const h = await heights(page);
    if (h0.skipped === h0.laid && Math.abs(h.skipped - h.laid) > 2) bad.push(`at the end ${h.skipped - h.laid} px taller skipped than laid out`);
  }
  if (grow && !crossed) bad.push('the page never became large');
  // Scrolled through and quiet: every chunk within its limits.
  const H = await page.evaluate(() => document.scrollingElement.scrollHeight);
  for (let y = 0; y < H + 2000; y += 500) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(20); }
  await page.waitForTimeout(2800);   // the rebalance (600 ms, again 2 s later)
  const over = await page.evaluate(() => window.readout.lazyHeld().overfull);
  if (over) bad.push(`${over} chunks past their limits once quiet`);
  const stats = await page.evaluate(() => { const w = window.readout.windowProbe?.(); return w && { parked: w.parked, mounts: w.mounts, parks: w.parks }; });
  await page.close();
  return { patches, bad, parkedSeen, stats };
}

const runs = [
  ...[1, 2, 3, 4, 5, 6, 7, 8].map(seed => ({ seed, rounds: 150, opts: { layAll: seed % 2 === 0 }, what: 'writes, rewrites and removals away from the reader' })),
  ...[11, 12, 13, 14].map(seed => ({ seed, rounds: 80, opts: { removals: true, layAll: true }, what: 'removals (markers coming and going) in a page laid out once' })),
  { seed: 21, rounds: 120, opts: { longCode: true, layAll: true }, what: 'writes with code blocks of 500 to 800 lines' },
  { seed: 22, rounds: 120, opts: { hold: true }, what: 'writes while the reader holds a selection and the focus' },
  { seed: 23, rounds: 80, opts: { start: 230, grow: true, layAll: true }, what: 'writes taking a page of 230 blocks past 250' },
  { seed: 24, rounds: 120, opts: { guard: 0 }, what: 'writes anywhere, the screen included' },
];
for (const { seed, rounds, opts, what } of runs) {
  if (process.env.SEEDS && !process.env.SEEDS.split(',').map(Number).includes(seed)) continue;
  const r = await run(seed, rounds, opts);
  check(`seed ${seed}: ${r.patches} patches of ${what}: the reader's place, the chunks' limits, the order${opts.removals ? ', the height' : ''}`,
    r.bad.length === 0 && r.patches > 20, JSON.stringify(r.bad.slice(0, 5)));
  console.log(`  parked chunks (most at once) ${r.parkedSeen}, window ${JSON.stringify(r.stats)}`);
}

await browser.close();
server.close();
if (errors.length) { failures++; console.log('page errors:', errors.slice(0, 5)); }
console.log(failures ? `${failures} chunk checks failed` : 'all chunk checks passed');
process.exit(failures ? 1 : 0);
