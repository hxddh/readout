// Scroll measurement harness (investigation).
// node scroll.mjs <buildDir> [size] [marks 0|1] [reps]   (cwd: a web/ dir with test/corpus/patches)
// env: PASS_MS (per pass, default 10000), MODES (comma list: wheel,fling,inwheel,infling)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';

const [buildDir, sizeArg = '500000', marksArg = '0', repsArg = '1'] = process.argv.slice(2);
const SIZE = +sizeArg, MARKS = marksArg === '1', REPS = +repsArg;
const PASS_MS = +(process.env.PASS_MS || 10000);
const MODES = (process.env.MODES || 'wheel,fling,inwheel,infling').split(',');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join(buildDir, decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

// An agent-style document with few code blocks: the corpus (headings, prose,
// lists, tables, quotes, CJK) chained, one code block in 15 kept, no diagrams.
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target) {
  const ops = []; let slot = 0, bytes = 0, codes = 0;
  for (let round = 0; bytes < target; round++) for (const f of files) {
    const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
    for (const op of p.ops) {
      if (op.op !== 'insert' || op.kind === 'mermaid') continue;
      if (op.kind === 'code' && (codes++ % 15)) continue;
      ++slot;
      ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
      bytes += op.html.length;
    }
    if (bytes >= target) break;
  }
  return { ops, bytes };
}
const { ops, bytes } = chain(SIZE);
const doc = { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };

const browser = await webkit.launch();
const results = [];
for (let rep = 0; rep < REPS; rep++) {
  const page = await browser.newPage({ viewport: { width: 1000, height: 1000 } });
  const errs = [];
  page.on('pageerror', e => errs.push(String(e)));
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    // The page's own callbacks timed (not the harness's, tagged __h) and counted.
    const log = window.__cb = [];
    window.__cbOn = false;
    window.__ro = 0;
    const wrap = (kind, f) => {
      if (typeof f !== 'function' || f.__h) return f;
      const name = kind + ':' + (f.name || String(f).slice(0, 50).replace(/\s+/g, ' '));
      return function (...a) {
        const t = performance.now();
        try { return f.apply(this, a); } finally {
          if (window.__cbOn) { if (kind === 'ResizeObserver') window.__ro += a[0].length; const d = performance.now() - t; if (d > 2) log.push([Math.round(t), Math.round(d * 10) / 10, name]); }
        }
      };
    };
    const raf = window.requestAnimationFrame.bind(window); window.requestAnimationFrame = f => raf(wrap('raf', f));
    const st = window.setTimeout.bind(window); window.setTimeout = (f, ...a) => st(wrap('timeout', f), ...a);
    for (const O of ['IntersectionObserver', 'ResizeObserver', 'MutationObserver']) { const C = window[O]; window[O] = class extends C { constructor(f, o) { super(wrap(O, f), o); } }; }
    const ael = EventTarget.prototype.addEventListener; EventTarget.prototype.addEventListener = function (t, f, o) { return ael.call(this, t, (t === 'scroll' || t === 'wheel') ? wrap('ev-' + t, f) : f, o); };
  });
  await page.goto(`${base}/reader.html`);
  await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, topInset: 52 }));
  await page.evaluate(p => window.readout.apply(p), doc);
  await page.waitForTimeout(SIZE > 2e6 ? 4000 : 1500);
  if (MARKS) {
    // An agent edited: every 8th block is changed and marked, unread.
    const marked = ops.filter((_, i) => i % 8 === 3);
    const patch = { version: 2, reset: false, rewrite: false, deletions: [], toc: [], tasks: { done: 0, total: 0 },
      ops: marked.map(o => ({ ...o, op: 'replace', change: 'modified', html: o.html.replace(/<\/(p|li|td|h\d)>/, ' (revised)</$1>') })),
      marks: marked.map((o, i) => ({ slot: o.slot, kind: i % 2 ? 'modified' : 'inserted' })) };
    await page.evaluate(p => window.readout.apply(p), patch);
    await page.waitForTimeout(1000);
  }
  const info = await page.evaluate(() => ({ blocks: document.querySelectorAll('#ro-doc > .blk').length, cv: document.getElementById('ro-doc').classList.contains('cv'), h: document.scrollingElement.scrollHeight }));
  const passes = {};
  await page.mouse.move(500, 500);
  for (const mode of MODES) {
    // Each pass starts from a fresh place a third of the way down, so the blocks it passes were never laid out.
    const startY = await page.evaluate(i => { const y = Math.round(document.scrollingElement.scrollHeight * (0.1 + 0.2 * i)); window.scrollTo(0, y); return y; }, MODES.indexOf(mode));
    await page.waitForTimeout(1000);
    await page.evaluate(() => { window.__cb.length = 0; window.__ro = 0; window.__cbOn = true; });
    const run = page.evaluate(({ mode, PASS_MS }) => new Promise(resolve => {
      const se = document.scrollingElement;
      const inset = 52, vh = innerHeight;
      const gaps = [], blanks = [];
      let last = performance.now(), t0 = last, v = 0, flingAt = -1e9;
      // Viewport rows covered by blocks whose content WebKit skipped (content-visibility): shown blank.
      const blank = () => {
        let px = 0;
        const hit = document.elementFromPoint(500, inset + 2);
        let e = hit && hit.closest('#ro-doc > .blk');
        if (!e) return 0;
        for (; e; e = e.nextElementSibling) {
          if (!e.classList.contains('blk')) continue;
          const r = e.getBoundingClientRect();
          if (r.top >= vh) break;
          const c = e.firstElementChild;
          if (c && !c.checkVisibility({ contentVisibilityAuto: true })) px += Math.min(r.bottom, vh) - Math.max(r.top, inset);
        }
        return Math.max(0, px);
      };
      const frame = Object.assign(now => {
        const dt = now - last;
        gaps.push(dt); last = now;
        blanks.push(blank());
        if (se.scrollTop >= se.scrollHeight - vh - 1 || now - t0 > PASS_MS || window.__stop) return resolve({ gaps: gaps.slice(1), blanks: blanks.slice(1), secs: (now - t0) / 1000, dist: se.scrollTop });
        const s = Math.min(dt, 100) / 1000;
        if (mode === 'wheel') window.scrollBy(0, 2400 * s);          // a steady 2400 px/s
        else if (mode === 'fling') {                                   // flings: 9000 px/s, 0.35 s decay, every 1.2 s
          if (now - flingAt > 1200) { flingAt = now; v = 9000; }
          window.scrollBy(0, v * s); v *= Math.exp(-s / 0.35);
        }
        requestAnimationFrame(frame);
      }, { __h: true });
      requestAnimationFrame(frame);
    }), { mode, PASS_MS });
    if (mode.startsWith('in')) {
      // Real wheel events from the browser process (the platform's scrolling path).
      const t0 = Date.now();
      await page.evaluate(() => { window.__stop = false; });
      while (Date.now() - t0 < PASS_MS - 200) {
        if (mode === 'inwheel') { await page.mouse.wheel(0, 120); await new Promise(r => setTimeout(r, 50)); }
        else { for (let d = 260; d > 8; d *= 0.9) { await page.mouse.wheel(0, Math.round(d)); await new Promise(r => setTimeout(r, 16)); } }
      }
      await page.evaluate(() => { window.__stop = true; });
    }
    passes[mode] = await run;
    passes[mode].dist -= startY;
    passes[mode].cb = await page.evaluate(() => { window.__cbOn = false; window.__stop = false; return { log: window.__cb.slice(), ro: window.__ro }; });
  }
  await page.close();
  const sum = {};
  for (const [mode, r] of Object.entries(passes)) {
    const s = r.gaps.slice().sort((a, b) => a - b);
    const cb = r.cb.log;
    sum[mode] = { frames: r.gaps.length, secs: +r.secs.toFixed(1), distPx: Math.round(r.dist), long: r.gaps.filter(g => g > 50).length,
      p95: +s[Math.floor(s.length * 0.95)].toFixed(1), max: Math.round(s[s.length - 1]),
      cbTotal: Math.round(cb.reduce((a, c) => a + c[1], 0)), cbMax: cb.reduce((a, c) => Math.max(a, c[1]), 0), roEntries: r.cb.ro,
      cbTop: Object.entries(cb.reduce((m, c) => (m[c[2]] = (m[c[2]] || 0) + c[1], m), {})).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, v]) => `${Math.round(v)} ${k}`),
      blankFrames: r.blanks.filter(b => b > 0).length, blankMaxPx: Math.round(Math.max(0, ...r.blanks)), blankSumPx: Math.round(r.blanks.reduce((a, b) => a + b, 0)) };
  }
  results.push({ ...info, ...sum, errs: errs.length });
}
await browser.close(); server.close();
console.log(JSON.stringify({ build: buildDir.split('/').pop(), bytes, marks: MARKS, results }));
