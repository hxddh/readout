// macOS-only probe (temporary CI job): the page with the real system fonts
// (SF Pro, SF Mono, PingFang SC). Writes crops and numbers to test/out/mac-probe.
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { extname, join } from 'node:path';
const OUT = 'test/out/mac-probe'; mkdirSync(OUT, { recursive: true });
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => { const p = join('build/Web', decodeURIComponent(req.url.split('?')[0])); if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await webkit.launch();
const result = {};
async function open(width, dark = false, scale = 2) {
  const p = await browser.newPage({ viewport: { width, height: 1000 }, deviceScaleFactor: scale });
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`${base}/reader.html`);
  for (let i = 0; i < 300 && !(await p.evaluate(() => window.readout && window.__msgs.some(m => m.type === 'ready'))); i++) await p.waitForTimeout(50);
  await p.evaluate(d => window.readout.setAppearance({ dark: d, accent: '#0a84ff', fontSize: 16 }), dark);
  return p;
}
const doc = name => JSON.parse(readFileSync(`test/corpus/patches/${name}.json`, 'utf8'));
async function crop(p, snippet, height, file) {
  await p.evaluate(s => { const b = [...document.querySelectorAll('#ro-doc .blk')].find(e => e.textContent.includes(s)); b.scrollIntoView({ block: 'start' }); window.scrollBy(0, -16); }, snippet);
  await p.waitForTimeout(500);
  const t = await p.evaluate(s => [...document.querySelectorAll('#ro-doc .blk')].find(e => e.textContent.includes(s)).getBoundingClientRect().top, snippet);
  await p.screenshot({ path: `${OUT}/${file}`, clip: { x: 0, y: Math.max(0, t - 12), width: p.viewportSize().width, height } });
}
// 1. Crops with the real fonts.
for (const dark of [false, true]) {
  const theme = dark ? 'dark' : 'light';
  let p = await open(900, dark);
  await p.evaluate(x => window.readout.apply(x), doc('18-phase0-bench-report')); await p.waitForTimeout(800);
  await crop(p, 'This is Phase 0 work item 7', 260, `18-code-${theme}.png`); await p.close();
  p = await open(900, dark);
  await p.evaluate(x => window.readout.apply(x), doc('22-project-prompts-design-zh')); await p.waitForTimeout(800);
  await crop(p, '概述', 330, `22-headings-code-${theme}.png`);
  await crop(p, '采用抽象基类模式', 260, `22-leadin-${theme}.png`); await p.close();
}
// 2. CJK heading weight: h2/h3 as the CSS asks (650) against forced 400 and 600, pixel ink compared.
{
  const p = await open(900);
  await p.evaluate(x => window.readout.apply(x), doc('22-project-prompts-design-zh')); await p.waitForTimeout(800);
  const ink = async (sel, w) => p.evaluate(async ([sel, w]) => {
    const h = document.querySelector(sel); if (w) h.style.fontWeight = w; else h.style.removeProperty('font-weight');
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    const c = document.createElement('canvas'); const g = c.getContext('2d'); const cs = getComputedStyle(h);
    g.font = `${w || cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;   // the same face the text uses
    const m = g.measureText(h.textContent);
    c.width = Math.ceil(m.width) + 4; c.height = 60; g.font = `${w || cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`; g.fillText(h.textContent, 2, 40);
    const d = g.getImageData(0, 0, c.width, c.height).data; let a = 0; for (let i = 3; i < d.length; i += 4) a += d[i];
    return { weight: cs.fontWeight, family: cs.fontFamily, ink: a, width: m.width };
  }, [sel, w]);
  result.headings = {};
  for (const sel of ['.k-heading h2', '.k-heading h3', '.k-heading h1']) {
    result.headings[sel] = { css: await ink(sel, null), w400: await ink(sel, '400'), w600: await ink(sel, '600'), w700: await ink(sel, '700') };
  }
  await p.close();
}
// 3. Inline code x-height against the text, Latin and Chinese; characters per line at 39 rem.
{
  const p = await open(1600);
  const latin = 'Agents write long plans and reports, and the reader keeps them readable: a line of text that the eye can follow back to its start without losing its place, in a window of any size and at any text size the reader chooses. '.repeat(3);
  const han = '在现有全局提示词存储的基础上，增加项目级别的提示词存储功能。项目提示词存储在项目根目录的文件中，实现团队共享和项目特定的提示词管理，并保持阅读的节奏。'.repeat(3);
  const ops = [['paragraph', `<p id="m-latin">${latin}</p>`, false], ['paragraph', `<p id="m-han">${han}</p>`, true],
    ['paragraph', '<p id="x-l">Text with <code id="x-lc">src/app.ts</code> in it.</p>', false], ['paragraph', '<p id="x-z">中文里的 <code id="x-zc">src/app.ts</code> 代码。</p>', true]]
    .map(([kind, html, cjk], i) => ({ op: 'insert', slot: i + 1, after: i, kind, html, cjk }));
  await p.evaluate(x => window.readout.apply(x), { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p.waitForTimeout(500);
  result.measure = await p.evaluate(() => {
    const per = id => { const el = document.getElementById(id), lines = new Map(); const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let t; (t = w.nextNode());) for (let i = 0; i < t.data.length; i++) { const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + 1); const b = r.getClientRects()[0]; if (!b) continue; const k = Math.round(b.top / 4); lines.set(k, (lines.get(k) || 0) + 1); }
      const n = [...lines.values()]; n.pop(); return n.reduce((a, b) => a + b, 0) / n.length; };
    const ex = el => { const s = document.createElement('span'); s.style.cssText = 'display:inline-block;width:0;height:1ex'; el.appendChild(s); const h = s.getBoundingClientRect().height; s.remove(); return h; };
    const code = document.getElementById('x-lc');
    return { column: document.getElementById('m-latin').getBoundingClientRect().width, latinPerLine: per('m-latin'), hanPerLine: per('m-han'),
      xLatin: ex(code) / ex(code.parentElement), xHan: ex(document.getElementById('x-zc')) / ex(document.getElementById('x-zc').parentElement),
      codeFont: getComputedStyle(code).fontFamily, bodyFont: getComputedStyle(code.parentElement).fontFamily, ua: navigator.userAgent };
  });
  // 3.9's column, for comparison.
  await p.addStyleTag({ content: ':root { --measure: 42.5rem !important; }' });
  result.measure.latinPerLineAt42_5rem = await p.evaluate(() => { const el = document.getElementById('m-latin'), lines = new Map(); const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let t; (t = w.nextNode());) for (let i = 0; i < t.data.length; i++) { const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + 1); const b = r.getClientRects()[0]; if (!b) continue; const k = Math.round(b.top / 4); lines.set(k, (lines.get(k) || 0) + 1); }
    const n = [...lines.values()]; n.pop(); return n.reduce((a, b) => a + b, 0) / n.length; });
  await p.close();
}
writeFileSync(`${OUT}/result.json`, JSON.stringify(result, null, 1));
console.log(JSON.stringify(result, null, 1));
await browser.close(); server.close();
