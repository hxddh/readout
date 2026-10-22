// The 5 MB document's scroll passes for a build, with what was on screen in each frame over 200 ms:
// node exp/frames.mjs <buildDir>   (cwd: web/)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';
const { instrument, scrollPasses, summary } = await import(resolve('test/scrollperf.mjs'));
const dir = process.argv[2];
const STEPS = (process.env.STEPS || 'edit,jump,find,marks').split(',');
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
for (let rep = 0; rep < +(process.env.REPS || 2); rep++) {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await instrument(p);
  await p.addInitScript(() => {
    window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    // Each frame: when, where, and the chunks changed (added/removed) since the last.
    window.__fr = []; window.__mut = 0; window.__cls = 0;
    const raf = window.requestAnimationFrame.bind(window);
    let last = 0;
    const tick = Object.assign(now => {
      const d = document.getElementById('ro-doc');
      if (last && now - last > 200) {
        const hit = document.elementFromPoint(450, 450)?.closest('.chunk');
        window.__fr.push({ gap: Math.round(now - last), y: Math.round(scrollY), mut: window.__mut, chunk: hit ? [hit.childElementCount, Math.round(hit.getBoundingClientRect().height), [...hit.children].map(b => b.className.match(/k-(\w+)/)?.[1]).join(',')] : null,
          near: d ? d.querySelectorAll(':scope > .chunk.near').length : 0, chunks: d ? d.childElementCount : 0, cls: window.__cls, trace: window.readout?.trace ? window.readout.trace().filter(t => t.t > last - 50).map(t => t.type + (t.delta != null ? ':' + t.delta : '')).join(' ') : '' });
      }
      window.__mut = 0; window.__cls = 0; last = now; raf(tick);
    }, { __h: true });
    raf(tick);
    addEventListener('DOMContentLoaded', () => { new MutationObserver(rs => { for (const r of rs) window.__mut += r.addedNodes.length + r.removedNodes.length; }).observe(document.getElementById('ro-doc'), { childList: true }); new MutationObserver(rs => { window.__cls += rs.length; }).observe(document.getElementById('ro-doc'), { attributes: true, attributeFilter: ['class'], subtree: false }); new MutationObserver(rs => { for (const r of rs) if (r.target.parentElement?.id === 'ro-doc') window.__cls += 1000; }).observe(document.getElementById('ro-doc'), { attributes: true, attributeFilter: ['class', 'style'], subtree: true }); });
  });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  await p.evaluate(d => new Promise(r => { window.readout.apply(d); requestAnimationFrame(() => setTimeout(r, 0)); }), { version: 1, reset: true, rewrite: false, ops: five, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(3000);
  const frames = () => p.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  if (STEPS.includes('edit')) {
    await p.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight / 2)); await frames(); await p.waitForTimeout(500);
    const above = await p.evaluate(() => { const b = [...document.querySelectorAll('#ro-doc .blk')]; return +b[b.indexOf(document.elementFromPoint(450, 300).closest('.blk')) - 50].dataset.slot; });
    const aboveOp = five.find(o => o.slot === above);
    for (let i = 0; i < 6; i++) {
      const html = aboveOp.html.replace(/<\/(p|li|h\d)>/, ` grows ${'x '.repeat((i % 3 + 1) * 25)}</$1>`);
      await p.evaluate(x => window.readout.apply(x), { version: 100 + i, reset: false, rewrite: false, ops: [{ op: 'replace', slot: above, change: 'content', kind: aboveOp.kind, html }], marks: [{ slot: above, kind: 'modified' }], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
      await frames(); await p.waitForTimeout(200);
    }
  }
  if (STEPS.includes('jump')) for (const frac of [0.3, 0.55, 0.8]) {
    await p.evaluate(() => window.scrollTo(0, 0)); await frames(); await p.waitForTimeout(300);
    await p.evaluate(frac => { const hs = document.querySelectorAll('#ro-doc > .chunk > .blk.k-heading'); window.readout.scrollToSlot(+hs[Math.floor(hs.length * frac)].dataset.slot); }, frac);
    await p.waitForTimeout(1200);
  }
  if (STEPS.includes('find')) {
    await p.evaluate(() => window.scrollTo(0, 0)); await frames(); await p.waitForTimeout(300);
    await p.evaluate(() => window.readout.find('e')); await p.waitForTimeout(1500);
    for (let i = 0; i < 3; i++) { await p.evaluate(() => window.readout.find('e')); await frames(); await p.waitForTimeout(500); }
    await p.evaluate(() => window.readout.findEnd());
  }
  if (STEPS.includes('marks')) {
    await p.evaluate(n => window.readout.apply({ version: 90, reset: false, rewrite: false, ops: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, marks: Array.from({ length: 200 }, (_, k) => ({ slot: Math.floor((k + 0.5) * n / 200), kind: 'inserted' })) }), five.length);
    await p.waitForTimeout(500);
  }
  await p.evaluate(() => { window.__fr.length = 0; });
  const s = summary(await scrollPasses(p));
  const fr = await p.evaluate(() => window.__fr);
  console.log(JSON.stringify({ build: dir.split('/').pop(), steps: STEPS.join(), rep, max: s.max, long: s.long, p95: s.p95, own: s.ownMax, slow: fr.map(f => ({ ...f, chunk: f.chunk && [f.chunk[0], f.chunk[1]] })) }));
  await p.close();
}
await browser.close(); server.close();
