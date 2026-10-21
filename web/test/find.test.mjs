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
const selectedSlot = page => page.evaluate(() => { const s = getSelection(); const n = s.rangeCount ? s.getRangeAt(0).startContainer : null; const b = n && (n.nodeType === 1 ? n : n.parentElement)?.closest('.blk'); return b ? +b.dataset.slot : null; });

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
  // A selection the reader made is where the next search starts (Next from the current match, 12, would go to 35).
  check('(on block 12)', await selectedSlot(page) === 12, String(await selectedSlot(page)));
  await page.evaluate(() => { const p = document.querySelector('.blk[data-slot="2"] p'); getSelection().selectAllChildren(p); });
  await find(page, 'needle');
  check('find starts from the reader\'s selection', await selectedSlot(page) === 5, String(await selectedSlot(page)));
  // So does a click (the caret): from block 30, the next is 35 (from the current match, 5: 12).
  await page.evaluate(() => { const t = document.querySelector('.blk[data-slot="30"] p').firstChild; getSelection().collapse(t, 2); });
  await find(page, 'needle');
  check('find starts from where the reader clicked', await selectedSlot(page) === 35, String(await selectedSlot(page)));
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
// An agent's edit never moves the reader or takes their selection: the count
// and the marks follow it, and that is all.

// Where the page is and what is selected: "count@slot sel=… y=…".
const state = async page => {
  const r = await page.evaluate(() => ({ text: getSelection().toString(), y: Math.round(scrollY) }));
  return `${await count(page)}@${await selectedSlot(page)} sel=${r.text} y=${r.y}`;
};
const edit = (page, ops, v) => page.evaluate(p => window.readout.apply(p), patch(ops, v, false));
const settle = page => page.waitForTimeout(400);
const paras80 = Array.from({ length: 80 }, (_, i) => `<p>para ${i + 1}${[5, 40, 70].includes(i + 1) ? ' needle' : ''}</p>`);

{
  const page = await open();
  const paras = Array.from({ length: 30 }, (_, i) => `<p>para ${i + 1}${[10, 20].includes(i + 1) ? ' needle' : ''}</p>`);
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  await find(page, 'needle');
  await find(page, 'needle');
  check('before the edit: 2 of 2 on block 20', await count(page) === '2 of 2' && await selectedSlot(page) === 20, await count(page));
  // The agent adds one above the current match and one at the end.
  await edit(page, [
    { op: 'insert', slot: 31, after: 3, html: '<p>a new needle</p>', kind: 'paragraph' },
    { op: 'insert', slot: 32, after: 30, html: '<p>needle at the end</p>', kind: 'paragraph' },
  ], 2);
  await settle(page);
  check('an edit while finding updates the count, the current match kept', await count(page) === '3 of 4' && await selectedSlot(page) === 20, await count(page));
  await find(page, 'needle');
  check('Next goes on from it', await count(page) === '4 of 4' && await selectedSlot(page) === 32, `${await count(page)} ${await selectedSlot(page)}`);
  // After the find bar closed, edits tell the app nothing.
  await page.evaluate(() => window.readout.findEnd());
  const n = await page.evaluate(() => window.__msgs.length);
  await edit(page, [{ op: 'insert', slot: 33, after: 31, html: '<p>needle</p>', kind: 'paragraph' }], 3);
  await settle(page);
  check('closed: no more counts', await page.evaluate(n => !window.__msgs.slice(n).some(m => m.type === 'found'), n));
  await page.close();
}

// A reset with the same blocks (a file truncated and written again): the place and the count stay.
{
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras80)));
  await find(page, 'needle'); await find(page, 'needle');
  const before = await state(page);
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras80), 2, true));
  await settle(page);
  check('a reset with the same blocks keeps the place, the count and the match', before.startsWith('2 of 3@40') && await state(page) === before, JSON.stringify([before, await state(page)]));
  await page.close();
}

// The current match's block drawn again or edited while the reader is elsewhere, with their own selection.
{
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras80)));
  await find(page, 'needle'); await find(page, 'needle');   // 2 of 3, block 40
  await page.evaluate(() => { window.scrollTo(0, document.scrollingElement.scrollHeight); getSelection().selectAllChildren(document.querySelector('.blk[data-slot="78"] p')); });
  await settle(page);
  const before = await state(page);
  await edit(page, [{ op: 'replace', slot: 40, change: 'silent', html: '<p>para 40 needle</p>', kind: 'paragraph' }], 2);
  await settle(page);
  const redrawn = await state(page);
  await edit(page, [{ op: 'replace', slot: 40, change: 'content', html: '<p>para 40 needle and more</p>', kind: 'paragraph' }], 3);
  await settle(page);
  check('the current block drawn again or edited: the reader stays where they are, their selection kept',
    before === '2 of 3@78 sel=para 78 y=' + before.split('y=')[1] && redrawn === before && await state(page) === before, JSON.stringify([before, redrawn, await state(page)]));
  // Without a selection of their own, scrolled away: find's selection comes back, the page does not move.
  await page.evaluate(() => { window.readout.findEnd(); getSelection().removeAllRanges(); window.scrollTo(0, 0); });
  await find(page, 'needle'); await find(page, 'needle');   // block 40
  await page.evaluate(() => window.scrollTo(0, 0));
  await settle(page);
  await edit(page, [{ op: 'replace', slot: 40, change: 'content', html: '<p>para 40 needle again</p>', kind: 'paragraph' }], 4);
  await settle(page);
  check('the current block rewritten: its match selected again where it is, the page not moved', await state(page) === '2 of 3@40 sel=needle y=0', await state(page));
  await page.close();
}

// An edit before the match in its own block: the same match stays current.
{
  const page = await open();
  const paras = paras80.slice();
  paras[9] = '<p>needle one needle two</p>';
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  await find(page, 'needle'); await find(page, 'needle'); await find(page, 'needle');   // the second in block 10
  const before = await state(page);
  await edit(page, [{ op: 'replace', slot: 10, change: 'content', html: '<p>more words: needle one needle two</p>', kind: 'paragraph' }], 2);
  await settle(page);
  check('an edit before the match in its block keeps it current', before.startsWith('3 of 5@10 sel=needle') && (await state(page)).startsWith('3 of 5@10 sel=needle'), JSON.stringify([before, await state(page)]));
  await find(page, 'needle');
  check('… and Next goes on from it', await count(page) === '4 of 5' && await selectedSlot(page) === 40, await state(page));
  await page.close();
}

// A match written earlier in the current block: the current one stays the current one.
{
  const page = await open();
  const paras = paras80.slice();
  paras[9] = '<p>alpha needle</p>';
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  await find(page, 'needle'); await find(page, 'needle');   // block 10
  await edit(page, [{ op: 'replace', slot: 10, change: 'content', html: '<p>needle alpha needle</p>', kind: 'paragraph' }], 2);
  await settle(page);
  const r = await page.evaluate(() => { const s = getSelection(); return { off: s.rangeCount ? s.getRangeAt(0).startOffset : -1, cur: CSS.highlights.get('ro-find-cur') && [...CSS.highlights.get('ro-find-cur')][0].startOffset }; });
  await find(page, 'needle');
  check('a match written before the current one in its block: the current mark and the selection stay on it, and Next moves on',
    r.off === 13 && r.cur === 13 && await count(page) === '4 of 5' && await selectedSlot(page) === 40, JSON.stringify({ r, count: await count(page), slot: await selectedSlot(page) }));
  await page.close();
}

// "Not found", then the agent writes a match: counted, not landed on.
{
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras80)));
  const nothing = await find(page, 'zzunique');
  await page.evaluate(() => { window.scrollTo(0, 0); getSelection().removeAllRanges(); });
  await edit(page, [{ op: 'replace', slot: 75, change: 'content', html: '<p>zzunique</p>', kind: 'paragraph' }], 2);
  await settle(page);
  check('a match an edit brings after "Not found" is counted, not landed on', nothing === 0 && await state(page) === '0 of 1@null sel= y=0', await state(page));
  await find(page, 'zzunique');
  check('… and Return goes to it', await count(page) === '1 of 1' && await selectedSlot(page) === 75, await state(page));
  // A search made before the document arrives: the same.
  const page2 = await open();
  const none = await find(page2, 'needle');
  await page2.evaluate(p => window.readout.apply(p), patch(blocks(paras80)));
  await settle(page2);
  check('a search made before the document arrived counts its matches when it does', none === 0 && await count(page2) === '0 of 3', await count(page2));
  await page.close(); await page2.close();
}

// The current match's block removed: the count follows; Next goes to the match after where it was.
{
  const page = await open();
  const paras = Array.from({ length: 30 }, (_, i) => `<p>para ${i + 1}${[3, 30].includes(i + 1) ? ' needle' : ''}</p>`);
  paras[1] = '<p>needle a needle b needle c</p>';
  paras[4] = '<p>needle</p>'; paras[5] = '<p>needle</p>';
  await page.evaluate(p => window.readout.apply(p), patch(blocks(paras)));
  await page.evaluate(() => window.scrollTo(0, 0));
  await find(page, 'needle'); await find(page, 'needle'); await find(page, 'needle');   // the third in block 2
  const third = await state(page);
  await edit(page, [{ op: 'remove', slot: 2 }], 2);
  await settle(page);
  const removed = await state(page);
  await find(page, 'needle');
  check('the block of the current match removed: the count follows, and Next lands on the first match after it',
    third.startsWith('3 of 7@2') && removed.startsWith('1 of 4@') && removed.endsWith(third.split(' ').pop()) && (await state(page)).startsWith('1 of 4@3 sel=needle'),
    JSON.stringify([third, removed, await state(page)]));
  // ⌘G within 100 ms of its block going: from where it was.
  await find(page, 'needle'); await find(page, 'needle');   // block 6
  await page.evaluate(p => { window.readout.apply(p); window.readout.find('needle'); }, patch([{ op: 'remove', slot: 6 }], 3, false));
  await page.waitForTimeout(100);
  check('⌘G right after the current block went: the match after it', await count(page) === '3 of 3' && await selectedSlot(page) === 30, await state(page));
  // The last block, holding the current match, removed: Next goes around to the first.
  await edit(page, [{ op: 'remove', slot: 30 }], 4);
  await settle(page);
  await find(page, 'needle');
  check('the last block removed with the current match: Next goes around to the first match', (await state(page)).startsWith('1 of 2@3 sel=needle'), await state(page));
  await page.close();
}

check('no page errors', errors.length === 0, JSON.stringify(errors));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all passed');
process.exit(failures ? 1 : 0);
