// perf.test's code-heavy shapes for any build: node exp/code.mjs <buildDir>  (cwd: web/)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';
import { execSync } from 'node:child_process';
const { instrument, scrollPasses, summary, interactions } = await import(resolve('test/scrollperf.mjs'));
const dir = process.argv[2];
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => { const p = join(dir, decodeURIComponent(req.url.split('?')[0])); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
function webProcesses() {
  const rows = execSync('ps -eo pid,ppid,comm', { encoding: 'utf8' }).trim().split('\n').slice(1).map(l => l.trim().split(/\s+/));
  const kids = new Map();
  for (const [pid, ppid] of rows) kids.set(ppid, [...(kids.get(ppid) || []), pid]);
  const mine = new Set(), queue = [String(process.pid)];
  while (queue.length) for (const k of kids.get(queue.pop()) || []) { mine.add(k); queue.push(k); }
  return rows.filter(r => mine.has(r[0]) && /WebProces/.test(r[2])).map(r => r[0]);
}
const mem = pid => { try { const t = readFileSync(`/proc/${pid}/smaps_rollup`, 'utf8'); const kb = k => +(t.match(new RegExp(`^${k}:\\s+(\\d+)`, 'm'))?.[1] || 0); return Math.round((kb('Private_Dirty') + kb('Private_Clean')) / 1024); } catch { return null; } };
const median = xs => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const esc = t => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const codeOp = (slot, n) => ({ op: 'insert', slot, after: slot - 1, kind: 'code',
  html: `<div class="code-block" data-lang="js"><pre><code>${esc(Array.from({ length: n }, (_, i) => `  const value${slot}_${i} = compute(${i}, "${'x'.repeat(i % 30)}"); // step ${i}`).join('\n'))}</code></pre></div>` });
const paraOp = slot => ({ op: 'insert', slot, after: slot - 1, kind: 'paragraph', html: `<p>Paragraph ${slot} of the plan, with enough words to wrap over a line or two in the narrow column.</p>` });
const headOp = slot => ({ op: 'insert', slot, after: slot - 1, kind: 'heading', anchor: `h${slot}`, html: `<h2 id="h${slot}">Section ${slot}</h2>` });
const browser = await webkit.launch();
async function run(name, docOps) {
  const before = new Set(webProcesses());
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await instrument(p);
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`${base}/reader.html`);
  const pid = webProcesses().find(x => !before.has(x));
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, topInset: 52 }));
  await p.evaluate(d => window.readout.apply(d), { version: 1, reset: true, rewrite: false, ops: docOps, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(1500);
  const jumped = [];
  for (const frac of [0.3, 0.55, 0.8]) {
    await p.evaluate(() => window.scrollTo(0, 0));
    await p.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    await p.waitForTimeout(300);
    jumped.push(await p.evaluate(frac => new Promise(resolve => { const hs = document.querySelectorAll('#ro-doc .blk.k-heading'); const t0 = performance.now(); window.readout.scrollToSlot(+hs[Math.floor(hs.length * frac)].dataset.slot); requestAnimationFrame(() => setTimeout(() => resolve(performance.now() - t0), 0)); }), frac));
    await p.waitForTimeout(1200);
  }
  const s = summary(await scrollPasses(p, { inset: 52 }));
  const mb = mem(pid);
  let a = {};
  try { a = await interactions(p); } catch (e) { a = { err: String(e).slice(0, 80) }; }
  await p.close();
  console.log(JSON.stringify({ build: dir.split('/').pop(), name, jump: Math.round(median(jumped)), theme: Math.round(a.theme), p95: s.p95, max: s.max, long: s.long, blank: s.blankPx, mb, err: a.err }));
}
for (let rep = 0; rep < 2; rep++) {
  await run('code_heavy', Array.from({ length: 700 }, (_, k) => k % 10 === 0 ? headOp(k + 1) : codeOp(k + 1, 90)));
  try { await run('one_huge', Array.from({ length: 3000 }, (_, k) => k === 1500 ? codeOp(k + 1, 28000) : k % 20 === 0 ? headOp(k + 1) : paraOp(k + 1))); } catch (e) { console.log(JSON.stringify({ build: dir.split('/').pop(), name: 'one_huge', crash: String(e).slice(0, 100) })); }
}
await browser.close(); server.close();
