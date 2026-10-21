// The perf.test scroll and interaction measures for any build (3.8.0, 3.9.0, the fix):
// node exp/baseline.mjs <buildDir>   (cwd: web/, which has test/corpus/patches and test/scrollperf.mjs)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';
const { instrument, scrollPasses, summary, interactions, streamFrames, insertMiddle } = await import(resolve('test/scrollperf.mjs'));

const dir = process.argv[2];
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => { const p = join(dir, decodeURIComponent(req.url.split('?')[0])); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target, few = false) {
  const ops = []; let slot = 0, bytes = 0, codes = 0;
  for (let round = 0; bytes < target; round++) {
    for (const f of files) {
      for (const op of JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8')).ops) {
        if (op.op !== 'insert') continue;
        if (few && (op.kind === 'mermaid' || (op.kind === 'code' && codes++ % 15))) continue;
        ++slot; ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined }); bytes += op.html.length;
      }
      if (bytes >= target) break;
    }
  }
  return { ops, bytes };
}
const browser = await webkit.launch();
async function open(docOps, inset) {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await instrument(p);
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p.evaluate(i => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, ...(i ? { topInset: i } : {}) }), inset);
  await p.evaluate(d => new Promise(r => { window.readout.apply(d); requestAnimationFrame(() => setTimeout(r, 0)); }), { version: 1, reset: true, rewrite: false, ops: docOps, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(docOps.length > 10000 ? 3000 : 1500);
  return p;
}
const out = { build: dir.split('/').pop() };
const put = (k, v) => { out[`web_scroll_${k}_frame_p95_ms`] = v.p95; out[`web_scroll_${k}_frame_max_ms`] = v.max; out[`web_scroll_${k}_long_frames`] = v.long; out[`web_scroll_${k}_frames`] = v.frames; out[`blank_${k}`] = v.blankPx; out[`own_${k}`] = v.ownMax; };
const few = chain(500_000, true).ops;
{ const p = await open(few, 52); put('500kb', summary(await scrollPasses(p, { inset: 52 }))); await p.close(); }
{
  const p = await open(few, 52);
  const changed = few.filter((_, i) => i % 8 === 3);
  await p.evaluate(d => window.readout.apply(d), { version: 2, reset: false, rewrite: false, deletions: [], toc: [], tasks: { done: 0, total: 0 },
    ops: changed.map(o => ({ ...o, op: 'replace', change: 'modified', html: o.html.replace(/<\/(p|li|td|h\d)>/, ' (revised)</$1>') })),
    marks: changed.map((o, i) => ({ slot: o.slot, kind: i % 2 ? 'modified' : 'inserted' })) });
  await p.waitForTimeout(1000);
  put('500kb_marks', summary(await scrollPasses(p, { inset: 52 }))); await p.close();
}
const one = chain(1_000_000).ops;
{ const p = await open(one, 52); put('1mb', summary(await scrollPasses(p, { inset: 52 }))); const a = await interactions(p); out.web_select_1mb_ms = a.select; out.web_theme_1mb_ms = a.theme; out.web_drag_1mb_ms = a.drag; out.web_find_next_1mb_ms = a.findNext; await p.close(); }
const five = chain(5_000_000).ops;
{
  const p = await open(five, 0);
  put('5mb', summary(await scrollPasses(p)));
  const a = await interactions(p);
  out.web_select_5mb_ms = a.select; out.web_drag_5mb_ms = a.drag; out.web_theme_5mb_ms = a.theme; out.web_find_next_5mb_ms = a.findNext; out.find_selected_5mb = a.findSelected;
  const jumps = [];
  for (const frac of [0.3, 0.55, 0.8]) {
    await p.evaluate(() => window.scrollTo(0, 0)); await p.waitForTimeout(500);
    jumps.push(await p.evaluate(frac => new Promise(resolve => { const hs = document.querySelectorAll('#ro-doc .k-heading'); const h = hs[Math.floor(hs.length * frac)]; const t0 = performance.now(); window.readout.scrollToSlot(+h.dataset.slot); requestAnimationFrame(() => setTimeout(() => resolve(performance.now() - t0), 0)); }), frac));
    await p.waitForTimeout(1200);
  }
  out.web_toc_jump_5mb_ms = jumps.sort((x, y) => x - y)[1];
  out.web_insert_middle_5mb_ms = await insertMiddle(p, five, five.length + 1000);
  const s = summary({ ...await streamFrames(p, five.length), blank: [], own: [] });
  out.web_stream_frame_p95_5mb_ms = s.p95; out.web_stream_long_frames_5mb = s.long;
  await p.close();
}
console.log(JSON.stringify(out));
await browser.close(); server.close();
