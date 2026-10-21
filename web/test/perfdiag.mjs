// Mini harness: perf.test.mjs's first apply + the 20-block updates, instrumented.
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target) { const ops = []; let slot = 0, bytes = 0;
  for (let round = 0; bytes < target; round++) { for (const f of files) { const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
    for (const op of p.ops) { if (op.op !== 'insert') continue; ++slot; ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined }); bytes += op.html.length; }
    if (bytes >= target) break; } } return { ops, bytes }; }
const { ops } = chain(1_000_000);
const big = { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
const paragraphs = ops.filter(o => o.kind === 'paragraph'); const step = Math.floor(paragraphs.length / 20);
const edit = { version: 2, reset: false, rewrite: false, ops: paragraphs.filter((_, i) => i % step === 0).slice(0, 20).map(o => ({ ...o, op: 'replace', change: 'modified', html: o.html.replace('</p>', ' (revised)</p>') })), marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
edit.marks = edit.ops.map(o => ({ slot: o.slot, kind: 'modified' }));
const WAIT = +(process.env.WAIT || 1500), INSTR = !!process.env.INSTR;
const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
await page.addInitScript(instr => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  if (instr) { window.__ev = []; new MutationObserver(ms => { for (const m of ms) if (m.target.classList?.contains('code-block')) window.__ev.push([Math.round(performance.now()), 'hl:' + m.target.dataset.hl + ':' + m.target.dataset.lang]); })
    .observe(document, { subtree: true, attributes: true, attributeFilter: ['data-hl'] });
    const L = new PerformanceObserver(l => { for (const e of l.getEntries()) if (e.name.includes('.js')) window.__ev.push([Math.round(e.responseEnd), 'fetched ' + e.name.split('/').pop()]); }); try { L.observe({ entryTypes: ['resource'] }); } catch {} } }, INSTR);
await page.goto(`${base}/reader.html`);
await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
await page.evaluate(p => new Promise(resolve => { window.readout.apply(p); requestAnimationFrame(() => setTimeout(resolve, 0)); }), big);
await page.waitForTimeout(WAIT);
const twoFrames = () => page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
const out = [];
for (let i = 0; i < 3; i++) {
  await page.evaluate(y => window.scrollTo(0, y), 20000 + i * 5000);
  await twoFrames();
  const patch = { ...edit, version: 2 + i, ops: edit.ops.map(o => ({ ...o, html: o.html.replace('(revised)', `(revised ${i + 1})`) })) };
  out.push(await page.evaluate(([p, diag]) => { let pre = 0; if (diag) { const a = performance.now(); void document.scrollingElement.scrollHeight; document.querySelector('#ro-doc > .blk').getBoundingClientRect(); pre = Math.round(performance.now() - a); } const t0 = performance.now(); window.readout.apply(p); const t1 = performance.now(); void document.scrollingElement.scrollHeight; const t2 = performance.now();
    const near = [...document.querySelectorAll('.code-block')].filter(c => { const r = c.getBoundingClientRect(); return r.bottom > -innerHeight && r.top < 2 * innerHeight; }).map(c => c.dataset.lang + ':' + c.dataset.hl).join(','); (window.__ev || []).push([Math.round(t0), 'UPDATE near=[' + near + '] apply ' + Math.round(t1 - t0) + ' layout ' + Math.round(t2 - t1)]); const ph = window.__ph.map((x, i, a) => i ? x[0] + '=' + (x[1] - a[i-1][1]).toFixed(1) : '').filter(Boolean).join(' '); return [Math.round(t1 - t0), Math.round(t2 - t1), pre, ph]; }, [patch, !!process.env.DIAG]));
  await page.waitForTimeout(300);
}
const ev = INSTR ? await page.evaluate(() => window.__ev) : [];
const loaded = await page.evaluate(() => [...document.querySelectorAll('.code-block')].reduce((a, c) => (a[c.dataset.hl] = (a[c.dataset.hl] || 0) + 1, a), {}));
console.log(JSON.stringify({ updates: out, median: out.map(x => x[0] + x[1]).sort((a, b) => a - b)[1], hl: loaded }));
if (INSTR) for (const e of ev) console.log(e.join(' '));
await browser.close(); server.close();
