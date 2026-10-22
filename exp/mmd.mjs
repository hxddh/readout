import { webkit } from 'playwright';
import http from 'node:http'; import { readFileSync, existsSync, readdirSync } from 'node:fs'; import { extname, join } from 'node:path';
const ROOT = process.argv[2] || 'build/Web';
const server = http.createServer((req, res) => { const p = join(ROOT, decodeURIComponent(req.url.split('?')[0])); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' }[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const flow = JSON.parse(readFileSync('../exp/flow.json', 'utf8'));
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target) { const ops = []; let slot = 0, bytes = 0; for (let round = 0; bytes < target; round++) for (const f of files) { for (const op of JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8')).ops) { if (op.op !== 'insert' || op.kind === 'mermaid') continue; ++slot; ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined }); bytes += op.html.length; } if (bytes >= target) break; } return ops; }
const b = await webkit.launch();
for (const size of (process.env.SIZES || '5000000').split(',').map(Number)) {
  const p = await b.newPage({ viewport: { width: 900, height: 900 } });
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`http://127.0.0.1:${server.address().port}/reader.html`); await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  const ops = chain(size);
  await p.evaluate(d => window.readout.apply(d), { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(2000);
  for (let k = 0; k < 3; k++) { await p.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight)); await p.waitForTimeout(1500); }
  await p.waitForTimeout(4000);   // the flowchart warm-up done
  const r = await p.evaluate(async op => {
    const gaps = []; let last = performance.now(); let on = true;
    const tick = now => { gaps.push(Math.round(now - last)); last = now; if (on) requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    const t0 = performance.now();
    window.readout.apply({ version: 2, reset: false, rewrite: false, ops: [op], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
    while (!document.querySelector('.mermaid-block.done, .mermaid-error') && performance.now() - t0 < 30000) await new Promise(r => setTimeout(r, 10));
    const ms = performance.now() - t0;
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    on = false;
    return { ms: Math.round(ms), maxGap: Math.max(...gaps), gaps: gaps.filter(g => g > 50), err: document.querySelector('.mermaid-error')?.textContent };
  }, { ...flow, slot: ops.length + 1, after: ops.length });
  console.log(ROOT.split('/').slice(-2).join('/'), size, JSON.stringify(r));
  await p.close();
}
await b.close(); server.close();
