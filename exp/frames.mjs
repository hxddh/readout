// The 5 MB document's scroll passes for a build, with what was on screen in each frame over 200 ms:
// node exp/frames.mjs <buildDir>   (cwd: web/)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';
const { instrument, scrollPasses, summary } = await import(resolve('test/scrollperf.mjs'));
const dir = process.argv[2];
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => { const p = join(dir, decodeURIComponent(req.url.split('?')[0])); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target) {
  const ops = []; let slot = 0, bytes = 0;
  for (let round = 0; bytes < target; round++) for (const f of files) {
    for (const op of JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8')).ops) {
      if (op.op !== 'insert') continue;
      ++slot; ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined }); bytes += op.html.length;
    }
    if (bytes >= target) break;
  }
  return ops;
}
const browser = await webkit.launch();
const five = chain(5_000_000);
for (let rep = 0; rep < 3; rep++) {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await instrument(p);
  await p.addInitScript(() => {
    window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    // Each frame: when, where, and the chunks changed (added/removed) since the last.
    window.__fr = []; window.__mut = 0;
    const raf = window.requestAnimationFrame.bind(window);
    let last = 0;
    const tick = Object.assign(now => {
      const d = document.getElementById('ro-doc');
      if (last && now - last > 200) {
        const hit = document.elementFromPoint(450, 450)?.closest('.chunk');
        window.__fr.push({ gap: Math.round(now - last), y: Math.round(scrollY), mut: window.__mut, chunk: hit ? [hit.childElementCount, Math.round(hit.getBoundingClientRect().height), [...hit.children].map(b => b.className.match(/k-(\w+)/)?.[1]).join(',')] : null,
          near: d ? d.querySelectorAll(':scope > .chunk.near').length : 0, chunks: d ? d.childElementCount : 0 });
      }
      window.__mut = 0; last = now; raf(tick);
    }, { __h: true });
    raf(tick);
    addEventListener('DOMContentLoaded', () => { new MutationObserver(rs => { for (const r of rs) window.__mut += r.addedNodes.length + r.removedNodes.length; }).observe(document.getElementById('ro-doc'), { childList: true }); });
  });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  await p.evaluate(d => new Promise(r => { window.readout.apply(d); requestAnimationFrame(() => setTimeout(r, 0)); }), { version: 1, reset: true, rewrite: false, ops: five, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(3000);
  await p.evaluate(() => { window.__fr.length = 0; });
  const s = summary(await scrollPasses(p));
  const fr = await p.evaluate(() => window.__fr);
  console.log(JSON.stringify({ build: dir.split('/').pop(), rep, max: s.max, long: s.long, p95: s.p95, own: s.ownMax, slow: fr }));
  await p.close();
}
await browser.close(); server.close();
