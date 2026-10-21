// Microbench: cost of layouts caused by relevancy vs inline content-visibility toggles.
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
const [buildDir, size = '500000'] = process.argv.slice(2);
const server = http.createServer((req, res) => { const p = join(buildDir, req.url.split('?')[0]); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' }[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
const ops = []; let slot = 0, bytes = 0;
for (let r = 0; bytes < +size; r++) for (const f of files) { for (const op of JSON.parse(readFileSync(`test/corpus/patches/${f}`)).ops) { if (op.op !== 'insert' || op.kind === 'mermaid' || op.kind === 'code') continue; ++slot; ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? op.anchor + '-' + slot : undefined }); bytes += op.html.length; } if (bytes >= +size) break; }
const b = await webkit.launch(); const page = await b.newPage({ viewport: { width: 1000, height: 1000 } });
await page.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  window.__obs = []; for (const O of ['IntersectionObserver', 'ResizeObserver']) { const C = window[O]; window[O] = class extends C { constructor(f, o) { super(f, o); window.__obs.push([O, this]); } }; } });
await page.goto(`http://127.0.0.1:${server.address().port}/reader.html`);
await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, topInset: 52 }));
await page.evaluate(p => window.readout.apply(p), { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
await page.waitForTimeout(3000);
const V = process.env.V || '';
if (V.includes('noRO')) await page.evaluate(() => { for (const [k, o] of window.__obs) if (k === 'ResizeObserver') o.disconnect(); });
if (V.includes('noIO')) await page.evaluate(() => { for (const [k, o] of window.__obs) if (k === 'IntersectionObserver') o.disconnect(); });
if (V.includes('noCV')) await page.evaluate(() => document.getElementById('ro-doc').classList.remove('cv'));
await page.waitForTimeout(1000);
const r = await page.evaluate(() => new Promise(async resolve => {
  // Rendering cost of a frame: from the rAF callback to a task queued in it (runs after the frame's rendering).
  const frameCost = before => new Promise(r => requestAnimationFrame(() => { before && before(); const t = performance.now(); setTimeout(() => r(+(performance.now() - t).toFixed(1)), 0); }));
  const out = { idle: [], step300: [], step1000: [] };
  for (let i = 0; i < 8; i++) out.idle.push(await frameCost());
  for (let i = 0; i < 12; i++) out.step300.push(await frameCost(() => window.scrollBy(0, 300)));
  for (let i = 0; i < 12; i++) out.step1000.push(await frameCost(() => window.scrollBy(0, 1000)));
  resolve(out);
}));
console.log(JSON.stringify(r));
await b.close(); server.close();
