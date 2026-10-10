// Renders fixture patches in WebKit (Playwright), checks anchor stability and writes screenshots.
// Usage: node test/render.mjs PATCHES.json OUT_DIR
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, mkdirSync } from 'node:fs';
import { extname, join } from 'node:path';

const [patchFile, outDir = 'test/out'] = process.argv.slice(2);
const patches = JSON.parse(readFileSync(patchFile, 'utf8'));
mkdirSync(outDir, { recursive: true });

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 820 }, deviceScaleFactor: 2 });
const errors = [];
page.on('pageerror', e => errors.push(String(e)));
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

const t0 = Date.now();
await page.evaluate(p => window.readout.apply(p), patches[0]);
const applyMs = Date.now() - t0;
await page.waitForTimeout(2500);
await page.screenshot({ path: `${outDir}/1-light-top.png` });
await page.screenshot({ path: `${outDir}/1-light-full.png`, fullPage: true });

let result = { applyMs, errors };
if (patches[1]) {
  // Scroll so that a block in the middle of the document is at the top, then apply the edit.
  const before = await page.evaluate(() => {
    const blocks = [...document.querySelectorAll('.blk')];
    const target = blocks.find(b => b.textContent.includes('写入流程')) || blocks[Math.floor(blocks.length / 2)];
    window.scrollBy(0, target.getBoundingClientRect().top - 30);
    return { slot: +target.dataset.slot, top: target.getBoundingClientRect().top };
  });
  await page.evaluate(p => window.readout.apply(p), patches[1]);
  const after = await page.evaluate(slot => document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().top, before.slot);
  result.anchorShift = after - before.top;
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${outDir}/2-after-edit.png` });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outDir}/3-marks-top.png` });
  result.marks = await page.evaluate(() => document.querySelectorAll('.m-inserted, .m-modified, .m-state').length);
  result.deletions = await page.evaluate(() => document.querySelectorAll('.del-mark').length);
}

await page.evaluate(() => window.readout.setAppearance({ dark: true }));
await page.waitForTimeout(1500);
await page.evaluate(() => window.scrollTo(0, 0));
await page.screenshot({ path: `${outDir}/4-dark-top.png` });
await page.evaluate(() => { const m = document.querySelector('.mermaid-block'); if (m) m.scrollIntoView({ block: 'center' }); });
await page.waitForTimeout(1200);
await page.screenshot({ path: `${outDir}/5-dark-mermaid.png` });
result.messages = await page.evaluate(() => window.__msgs.map(m => m.type));
result.highlighted = await page.evaluate(() => document.querySelectorAll('.code-block[data-hl="done"]').length);
result.math = await page.evaluate(() => document.querySelectorAll('.math.done, .math-block.done').length);
result.mermaid = await page.evaluate(() => document.querySelectorAll('.mermaid-block.done').length);
console.log(JSON.stringify(result, null, 2));
await browser.close();
server.close();
