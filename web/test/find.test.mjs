// Find in page (find.js): the app's find field searches the page's text, in
// a large document without laying out the blocks off screen.
// Usage: BROWSER=webkit node test/find.test.mjs  (requires web/build.mjs to have run)
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const engines = { webkit, chromium, firefox };
const engineName = (process.env.BROWSER || 'webkit').toLowerCase();
console.log(`engine: ${engineName}`);
const launchOpts = process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] } : {};
const browser = await engines[engineName].launch(launchOpts);
const errors = [];
let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}

async function open() {
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 10); t(); }));
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  return page;
}
const patch = (ops, version = 1, reset = true) => ({ version, reset, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
const blocks = htmls => htmls.map((html, i) => ({ op: 'insert', slot: i + 1, after: i, html, kind: 'paragraph' }));
// The count the page last told the app ("3 of 12").
const count = page => page.evaluate(() => { const m = window.__msgs.filter(m => m.type === 'found').pop(); return m ? `${m.current} of ${m.total}` : null; });
// A find, and the frame after it (the match is selected once its landing is painted).
const find = (page, text, back = false) => page.evaluate(([t, b]) => new Promise(r => {
  const n = window.readout.find(t, b);
  requestAnimationFrame(() => setTimeout(() => r(n), 0));
}), [text, back]);
const selected = page => page.evaluate(() => getSelection().toString());
const selectedSlot = page => page.evaluate(() => { const s = getSelection(); return s.rangeCount ? +s.getRangeAt(0).startContainer.parentElement.closest('.blk').dataset.slot : null; });

// ---------------------------------------------------------------- A 1 MB document

// The real-agent corpus patches chained into one document of 1 MB.
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
const ops = [];
for (let round = 0, bytes = 0; bytes < 1_000_000; round++) {
  for (const f of files) {
    for (const op of JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8')).ops) {
      if (op.op !== 'insert') continue;
      ops.push({ ...op, slot: ops.length + 1, after: ops.length, anchor: op.anchor ? `${op.anchor}-${round}-${ops.length + 1}` : undefined });
      bytes += op.html.length;
    }
    if (bytes >= 1_000_000) break;
  }
}
const far = Math.floor(ops.length * 0.85);
ops[far - 1] = { ...ops[far - 1], kind: 'paragraph', html: '<p>The Zebracórn lives far below.</p>' };
{
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), patch(ops));
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(500);
  // Blocks whose content WebKit has laid out (content-visibility skips the rest).
  const laidOut = () => page.evaluate(() => [...document.querySelectorAll('#ro-doc > .blk')]
    .filter(b => b.firstElementChild && b.firstElementChild.checkVisibility({ contentVisibilityAuto: true })).length);
  const before = await laidOut();
  // A word whose first match is on screen: nothing to jump to.
  const word = await page.evaluate(() => document.querySelector('#ro-doc > .blk p').textContent.match(/[A-Za-z]{5,}/)[0]);
  const n = await find(page, word);
  const after = await laidOut();
  const r = await page.evaluate(() => ({ cv: document.getElementById('ro-doc').classList.contains('cv'), y: document.scrollingElement.scrollTop }));
  check('finding in a 1 MB document lays out no block off screen', n > 0 && r.cv && r.y === 0 && after <= before + 2,
    JSON.stringify({ blocks: ops.length, before, after, n, ...r }));

  // A match in a block never laid out, far below: found, selected and on screen.
  const total = await find(page, 'ZEBRACORN');
  await page.waitForTimeout(1500);
  const land = await page.evaluate(() => {
    const s = getSelection();
    const r = s.getRangeAt(0).getBoundingClientRect();
    return { text: s.toString(), top: Math.round(r.top), h: innerHeight };
  });
  check('a match in a block not laid out yet is found and landed on',
    total === 1 && land.text === 'Zebracórn' && land.top > 0 && land.top < land.h - 20 && await selectedSlot(page) === far,
    JSON.stringify({ total, land, slot: await selectedSlot(page), far }));
  check('the find bar is told "1 of 1"', await count(page) === '1 of 1', await count(page));
  check('blocks off screen are still skipped after the landing', await laidOut() < 100, String(await laidOut()));
  await page.close();
}

// ---------------------------------------------------------------- The count, next and previous

{
  const page = await open();
  const paras = Array.from({ length: 40 }, (_, i) => `<p>para ${i + 1}${[5, 12, 35].includes(i + 1) ? ' needle' : ''}</p>`);
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  const seen = [];
  for (let i = 0; i < 4; i++) { await find(page, 'needle'); seen.push(`${await count(page)}@${await selectedSlot(page)}`); }
  await find(page, 'needle', true);
  seen.push(`${await count(page)}@${await selectedSlot(page)}`);
  check('Next counts on and wraps; Previous goes back', JSON.stringify(seen) === JSON.stringify(['1 of 3@5', '2 of 3@12', '3 of 3@35', '1 of 3@5', '3 of 3@35']), JSON.stringify(seen));
  check('the current match is selected (⌘C, Copy as Quote)', await selected(page) === 'needle', await selected(page));
  const nothing = await find(page, 'zzzzq');
  check('no match: 0 of 0, no marks', nothing === 0 && await count(page) === '0 of 0'
    && await page.evaluate(() => !CSS.highlights.has('ro-find-cur')), await count(page));
  await find(page, 'needle');
  const marks = await page.evaluate(() => ({ cur: CSS.highlights.get('ro-find-cur')?.size, near: CSS.highlights.get('ro-find')?.size }));
  await page.evaluate(() => window.readout.findEnd());
  const ended = await page.evaluate(() => ({ hl: CSS.highlights.size, sel: getSelection().toString() }));
  check('the matches in the blocks around the current one are marked (not those far off), and the marks go when the find bar closes (the selection stays)',
    marks.cur === 1 && marks.near === 1 && ended.hl === 0 && ended.sel === 'needle', JSON.stringify({ marks, ended }));
  // Return twice before the first landing is painted (and selected): on to the next match.
  await page.evaluate(() => { getSelection().removeAllRanges(); window.scrollTo(0, 0); window.readout.findEnd(); });
  await page.evaluate(() => { window.readout.find('needle'); window.readout.find('needle'); });
  await page.waitForTimeout(100);
  check('Return twice in one frame goes to the second match', await count(page) === '2 of 3' && await selectedSlot(page) === 12, `${await count(page)} ${await selectedSlot(page)}`);
  // A selection the reader made is where the next search starts.
  await page.evaluate(() => { const p = document.querySelector('.blk[data-slot="21"] p'); getSelection().selectAllChildren(p); });
  await find(page, 'needle');
  check('find starts from the reader\'s selection', await selectedSlot(page) === 35, String(await selectedSlot(page)));
  await page.close();
}

// ---------------------------------------------------------------- What counts as text

{
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), patch(blocks([
    '<p>Café au lait, NAÏVE résumé</p>',
    '<p>Ｗide and İstanbul and café decomposed</p>',
    '<p>这是<span class="em-dot">重</span><span class="em-dot">点</span>内容，读者</p>',
    '<p>ガイドを読む。カイドではない。</p>',
    '<p>Ὀδυσσεύς ΟΔΥΣΣΕΥΣ οδυσσευς</p>',
    '<p>math <span class="katex"><span class="katex-mathml"><math><semantics><annotation>zebra</annotation></semantics></math></span><span class="katex-html" aria-hidden="true">x</span></span></p>',
    '<div class="code-block" data-lang="sh"><pre><code>echo zebra</code></pre></div>',
    '<details><summary>Folded</summary><p>zebra inside</p></details>',
    '<p>zebra\n   spread   over\nlines</p>',
  ])));
  await page.waitForTimeout(300);
  const total = async q => { const n = await find(page, q); return n; };
  check('case and accents do not count', await total('cafe') === 2 && await total('naive') === 1 && await total('RESUME') === 1 && await total('istanbul') === 1,
    JSON.stringify([await total('cafe'), await total('naive'), await total('RESUME'), await total('istanbul')]));
  check('a decomposed accent is found and selected whole', await total('café decomposed') === 1 && await selected(page) === 'café decomposed', JSON.stringify(await selected(page)));
  check('Greek: final sigma is sigma, case and accents do not count', await total('ΟΔΥΣΣΕΥΣ') === 3 && await total('οδυσσευσ') === 3 && await total('ς') === 0 + await total('σ'),
    JSON.stringify([await total('ΟΔΥΣΣΕΥΣ'), await total('οδυσσευσ')]));
  check('Chinese is found, across emphasis marks', await total('重点内容') === 1 && await selected(page) === '重点内容' && await total('读者') === 1, await selected(page));
  check('Japanese is found, its voicing marks counting', await total('ガイド') === 1 && await selected(page) === 'ガイド' && await total('カイド') === 1 && await total('読む') === 1,
    JSON.stringify([await total('ガイド'), await total('カイド')]));
  // Controls are no text (a code block's tools, a button); neither is a formula's MathML.
  await page.evaluate(() => {
    document.querySelector('.cb-tools').append(Object.assign(document.createElement('span'), { textContent: 'zebra' }));
    document.querySelector('.blk[data-slot="1"] p').append(Object.assign(document.createElement('button'), { textContent: 'zebra' }));
  });
  const z = await total('zebra');
  check('controls and formulas\' MathML are not searched; code and a folded <details> are', z === 3, String(z));
  // Landing in a folded <details> opens it.
  await page.evaluate(() => getSelection().removeAllRanges());
  await page.evaluate(() => window.scrollTo(0, 0));
  const folded = await page.evaluate(() => !document.querySelector('details').open);
  await total('zebra inside');
  check('a match in a folded <details> opens it', folded && await page.evaluate(() => document.querySelector('details').open) && await selected(page) === 'zebra inside');
  check('spaces in the query match runs of white space', await total('zebra spread over lines') === 1);
  // Hidden blocks are not searched.
  await page.evaluate(() => { document.querySelector('.blk[data-slot="1"]').hidden = true; });
  await page.waitForTimeout(200);
  check('a hidden block is not searched', await total('cafe') === 1, String(await total('cafe')));
  await page.close();
}

// ---------------------------------------------------------------- Edits while the find bar is open

{
  const page = await open();
  const paras = Array.from({ length: 30 }, (_, i) => `<p>para ${i + 1}${[10, 20].includes(i + 1) ? ' needle' : ''}</p>`);
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  await find(page, 'needle');
  await find(page, 'needle');
  check('before the edit: 2 of 2 on block 20', await count(page) === '2 of 2' && await selectedSlot(page) === 20, await count(page));
  // The agent adds one above the current match and one at the end.
  await page.evaluate(p => window.readout.apply(p), patch([
    { op: 'insert', slot: 31, after: 3, html: '<p>a new needle</p>', kind: 'paragraph' },
    { op: 'insert', slot: 32, after: 30, html: '<p>needle at the end</p>', kind: 'paragraph' },
  ], 2, false));
  await page.waitForTimeout(400);
  check('an edit while finding updates the count, the current match kept', await count(page) === '3 of 4', await count(page));
  await find(page, 'needle');
  check('Next goes on from it', await count(page) === '4 of 4' && await selectedSlot(page) === 32, `${await count(page)} ${await selectedSlot(page)}`);
  // The current match's own block rewritten without it.
  await page.evaluate(p => window.readout.apply(p), patch([{ op: 'replace', slot: 32, change: 'content', html: '<p>gone</p>', kind: 'paragraph' }], 3, false));
  await page.waitForTimeout(400);
  check('its match removed: the count drops', /^\d of 3$/.test(await count(page)), await count(page));
  // After the find bar closed, edits tell the app nothing.
  await page.evaluate(() => window.readout.findEnd());
  const n = await page.evaluate(() => window.__msgs.length);
  await page.evaluate(p => window.readout.apply(p), patch([{ op: 'insert', slot: 33, after: 31, html: '<p>needle</p>', kind: 'paragraph' }], 4, false));
  await page.waitForTimeout(400);
  check('closed: no more counts', await page.evaluate(n => !window.__msgs.slice(n).some(m => m.type === 'found'), n));
  await page.close();
}

// ---------------------------------------------------------------- Return before the document arrives

{
  const page = await open();
  const nothing = await find(page, 'needle');
  const paras = Array.from({ length: 60 }, (_, i) => `<p>para ${i + 1}${[40, 50].includes(i + 1) ? ' needle' : ''}</p>`);
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.waitForTimeout(1500);
  const r = await page.evaluate(() => {
    const s = getSelection();
    const rect = s.rangeCount ? s.getRangeAt(0).getBoundingClientRect() : null;
    return { text: s.toString(), top: rect && Math.round(rect.top), h: innerHeight };
  });
  check('a search made before the document arrived lands on its first match when it does ("1 of 2" is selected and on screen)',
    nothing === 0 && await count(page) === '1 of 2' && r.text === 'needle' && await selectedSlot(page) === 40 && r.top > 0 && r.top < r.h,
    JSON.stringify({ nothing, count: await count(page), r }));
  await page.close();
}

check('no page errors', errors.length === 0, JSON.stringify(errors));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all passed');
process.exit(failures ? 1 : 0);
