// Agent workflow 3.7, page side: Copy as Quote's selection, N on to another
// document (first change, "nothing" from N), the notice the app shows, and
// reading while focus is in the window's outline or find field.
// Usage: BROWSER=webkit node test/flow.test.mjs  (requires web/build.mjs to have run)
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const engines = { webkit, chromium, firefox };
const engineName = (process.env.BROWSER || 'webkit').toLowerCase();
if (!engines[engineName]) { console.error(`Unknown BROWSER=${process.env.BROWSER}`); process.exit(2); }
console.log(`engine: ${engineName}`);
const launchOpts = process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] } : {};
const browser = await engines[engineName].launch(launchOpts);

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}
const errors = [];
let pages = 0;

async function newPage({ width = 900, height = 700 } = {}) {
  const page = await browser.newPage({ viewport: { width, height } });
  collectPageErrors(page, errors, `page ${++pages}: `);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  return page;
}

const patch = (version, ops, extra = {}) => ({ version, reset: false, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ...extra });
function doc(n, extra = {}, html = i => `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`) {
  const ops = [];
  for (let i = 1; i <= n; i++) ops.push({ op: 'insert', slot: i, after: i - 1, html: html(i), kind: 'paragraph' });
  return patch(1, ops, { reset: true, ...extra });
}
const key = (page, k, o = {}) => page.evaluate(([k, o]) => document.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true, ...o })), [k, o]);

// 1. Copy as Quote: the blocks a selection touches, whole; a selection that
//    ends at the start of the next block (a triple click) leaves it out; the
//    page says when there is a selection and when it went.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(6, {}, i => i === 4 ? '<hr>' : `<p>para ${i} text</p>`));
  const r = await page.evaluate(async () => {
    const tick = () => new Promise(r => setTimeout(r, 50));
    const text = s => document.querySelector(`.blk[data-slot="${s}"] p`).firstChild;
    const sel = getSelection();
    const range = document.createRange();
    // From inside block 2 to inside block 5, across the rule in block 4.
    range.setStart(text(2), 3);
    range.setEnd(text(5), 4);
    sel.removeAllRanges();
    sel.addRange(range);
    await tick();
    const across = window.readout.selectedSlots();
    // All of block 3's paragraph, ending at the very start of block 5 (as a triple click selects).
    const triple = document.createRange();
    triple.setStart(text(3), 0);
    triple.setEnd(text(5), 0);
    sel.removeAllRanges();
    sel.addRange(triple);
    await tick();
    const tripled = window.readout.selectedSlots();
    // Inside one block.
    const inside = document.createRange();
    inside.setStart(text(6), 1);
    inside.setEnd(text(6), 4);
    sel.removeAllRanges();
    sel.addRange(inside);
    await tick();
    const one = window.readout.selectedSlots();
    sel.removeAllRanges();
    await tick();
    return { across, tripled, one, none: window.readout.selectedSlots(), msgs: window.__msgs.filter(m => m.type === 'selection').map(m => m.has) };
  });
  check('Copy as Quote: a selection across blocks names each block it touches', JSON.stringify(r.across) === '[2,3,4,5]', JSON.stringify(r));
  check('Copy as Quote: a selection ending at the start of the next block leaves that block out', JSON.stringify(r.tripled) === '[3]', JSON.stringify(r));
  check('Copy as Quote: a selection inside a block names that block; none, nothing', JSON.stringify(r.one) === '[6]' && r.none.length === 0, JSON.stringify(r));
  check('Copy as Quote: the page says when there is a selection and when it went',
    r.msgs.length >= 2 && r.msgs[0] === true && r.msgs[r.msgs.length - 1] === false, JSON.stringify(r.msgs));
  await page.close();
}

// 1a. Copy as Quote's link definitions come from the page, as ⌘C's do
//     (3.9, B8: one implementation): those the selected blocks' sources use,
//     in the order of first use; not a footnote reference, not one a block holds.
{
  const page = await newPage();
  const srcs = ['[x][C] then [a]', 'no links', '[^a] and [b]\n\n[b]: https://b'];
  const ops = srcs.map((src, i) => ({ op: 'insert', slot: i + 1, after: i, html: `<p>block ${i + 1}</p>`, kind: 'paragraph', src }));
  const links = ['a', 'b', 'c'].map(l => ({ label: l, md: `[${l}]: https://${l}` }));
  await page.evaluate(p => window.readout.apply(p), patch(1, ops, { reset: true, links }));
  const r = await page.evaluate(async () => {
    const tick = () => new Promise(r => setTimeout(r, 50));
    const sel = getSelection();
    const out = [];
    for (const s of [1, 2, 3]) {
      const t = document.querySelector(`.blk[data-slot="${s}"] p`).firstChild;
      const range = document.createRange();
      range.setStart(t, 1);
      range.setEnd(t, 4);
      sel.removeAllRanges();
      sel.addRange(range);
      await tick();
      out.push(window.readout.quoteSelection());
    }
    sel.removeAllRanges();
    return out;
  });
  check('Copy as Quote: the definitions a block uses, in the order of first use',
    JSON.stringify(r[0]) === JSON.stringify({ slots: [1], links: ['[c]: https://c', '[a]: https://a'] }), JSON.stringify(r[0]));
  check('Copy as Quote: no definitions for a block without references', JSON.stringify(r[1]) === JSON.stringify({ slots: [2], links: [] }), JSON.stringify(r[1]));
  check('Copy as Quote: a footnote reference is no label; a definition the block holds is not added again',
    JSON.stringify(r[2]) === JSON.stringify({ slots: [3], links: [] }), JSON.stringify(r[2]));
  await page.close();
}

// 1b. U4 (3.8): N lands on a change with no text selected; Copy as Quote
//     quotes that block (the page says there is something to quote), so
//     "N, then ⇧⌘C" needs no mouse. A text selection still wins; focus
//     leaving the document leaves nothing to quote.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(30));
  await page.evaluate(p => window.readout.apply(p), patch(2, [], { marks: [{ slot: 12, kind: 'modified' }] }));
  await page.evaluate(() => { window.__msgs.length = 0; });
  await key(page, 'n');
  await page.waitForTimeout(400);
  const r = await page.evaluate(async () => {
    const tick = () => new Promise(r => setTimeout(r, 50));
    const landed = { active: document.activeElement?.dataset?.slot, selected: window.readout.selectedSlots(), text: getSelection().toString() };
    // A selection in another block wins over the focus.
    const t = document.querySelector('.blk[data-slot="20"] p').firstChild;
    const range = document.createRange();
    range.setStart(t, 1);
    range.setEnd(t, 5);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    await tick();
    const withText = window.readout.selectedSlots();
    getSelection().removeAllRanges();
    await tick();
    document.activeElement.blur();
    await tick();
    return { landed, withText, after: window.readout.selectedSlots(), msgs: window.__msgs.filter(m => m.type === 'selection').map(m => m.has || m.focused) };
  });
  check('Copy as Quote after N: the block N landed on, with no text selected',
    r.landed.active === '12' && r.landed.text === '' && JSON.stringify(r.landed.selected) === '[12]', JSON.stringify(r));
  check('Copy as Quote after N: a text selection still names its own blocks', JSON.stringify(r.withText) === '[20]', JSON.stringify(r));
  check('Copy as Quote after N: the page says there is something to quote, and when there no longer is',
    r.msgs[0] === true && r.msgs[r.msgs.length - 1] === false && JSON.stringify(r.after) === '[]', JSON.stringify(r));
  // A patch removes the focused block (an agent's edit, or a reset): nothing to quote is said at once.
  await page.evaluate(() => { const b = document.querySelector('.blk[data-slot="12"]'); b.setAttribute('tabindex', '-1'); b.focus(); });
  await page.waitForTimeout(100);
  const removed = await page.evaluate(async p => {
    const before = { active: document.activeElement?.dataset?.slot, last: (m => m && (m.has || m.focused))(window.__msgs.filter(m => m.type === 'selection').pop()) };
    window.__msgs.length = 0;
    window.readout.apply(p);
    await new Promise(r => setTimeout(r, 50));
    return { before, selected: window.readout.selectedSlots(), msgs: window.__msgs.filter(m => m.type === 'selection').map(m => m.has || m.focused) };
  }, patch(3, [{ op: 'remove', slot: 12 }]));
  check('Copy as Quote: a patch removing the focused block says there is nothing to quote',
    removed.before.active === '12' && removed.before.last === true && JSON.stringify(removed.msgs) === '[false]' && removed.selected.length === 0, JSON.stringify(removed));
  // After N, a right click on another block: focus stays on the block N went to, but
  // no text is selected, so the context menu (the app shows Copy as Quote for `has` only)
  // offers no quote of it; the Edit menu still quotes the focused block.
  await page.evaluate(() => { const b = document.querySelector('.blk[data-slot="5"]'); window.__msgs.length = 0; b.setAttribute('tabindex', '-1'); b.focus(); });
  await page.waitForTimeout(100);
  const ctx = await page.evaluate(async () => {
    const other = document.querySelector('.blk[data-slot="20"] p');
    const r = other.getBoundingClientRect();
    other.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2, clientX: r.left + 5, clientY: r.top + 5 }));
    await new Promise(r => setTimeout(r, 50));
    const last = window.__msgs.filter(m => m.type === 'selection').pop() || null;
    return { last, active: document.activeElement?.dataset?.slot, text: getSelection().toString() };
  });
  check('Copy as Quote: after N, a right click on another block offers no context-menu quote (no text selected)',
    ctx.last && ctx.last.has === false && ctx.last.focused === true && ctx.text === '', JSON.stringify(ctx));
  await page.close();
}

// 2. N with nothing unread says so as N (the app goes on to the next
//    document); the app's firstChange goes to the document's first change
//    from wherever the reader is, without "wrapped".
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(40));
  await key(page, 'n');
  const none = await page.evaluate(() => window.__msgs.filter(m => m.type === 'nothing'));
  check('N with nothing unread posts "nothing" as N\'s', none.length === 1 && none[0].jump === true, JSON.stringify(none));
  await page.evaluate(p => window.readout.apply(p), patch(2, [], { marks: [{ slot: 1, kind: 'inserted' }, { slot: 30, kind: 'modified' }] }));
  await page.evaluate(() => { document.querySelector('.blk[data-slot="35"]').scrollIntoView(); window.__msgs.length = 0; });
  await page.waitForTimeout(100);
  await page.evaluate(() => window.readout.firstChange());
  await page.waitForTimeout(700);
  const r = await page.evaluate(() => ({ focused: document.activeElement?.dataset?.slot, top: Math.round(document.querySelector('.blk[data-slot="1"]').getBoundingClientRect().top),
    wrapped: window.__msgs.filter(m => m.type === 'wrapped').length }));
  check('firstChange goes to the first unread change, without "wrapped"', r.focused === '1' && r.top >= -2 && r.top < 700 && r.wrapped === 0, JSON.stringify(r));
  await page.close();
}

// 3. The app's notice ("Marked against the last commit") shows above the document.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(3));
  await page.evaluate(() => window.readout.notice('Marked against the last commit'));
  const r = await page.evaluate(() => { const n = document.getElementById('ro-notice'); return { hidden: n.hidden, text: n.textContent }; });
  check('the app\'s notice shows above the document', !r.hidden && r.text === 'Marked against the last commit', JSON.stringify(r));
  // Compare with Last Commit undone (3.8): its notice goes at once; another notice stays.
  const h = await page.evaluate(() => {
    const n = document.getElementById('ro-notice');
    window.readout.hideNotice('Rewritten since the last commit');
    const other = n.hidden;
    window.readout.hideNotice('Marked against the last commit');
    return { other, hidden: n.hidden };
  });
  check('hideNotice hides the notice it names at once, and no other', h.other === false && h.hidden === true, JSON.stringify(h));
  await page.close();
}

// 4. S3: keyboard focus in the window's outline or find field takes it from
//    the page (document.hasFocus() is false), but the window is still key:
//    a change in view mid-document is read as in a focused window. Before
//    the app said so, it waited for the page to have the focus again.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(60));
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; window.dispatchEvent(new Event('blur')); });
  await page.evaluate(() => { document.querySelector('.blk[data-slot="20"]').scrollIntoView(); });
  await page.waitForTimeout(100);
  await page.evaluate(p => window.readout.apply(p), patch(2, [], { marks: [{ slot: 21, kind: 'inserted' }] }));
  await page.waitForTimeout(1300);
  const unfocused = await page.evaluate(() => window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots));
  check('a change in view mid-document waits while another window has the focus', !unfocused.includes(21), JSON.stringify(unfocused));
  await page.evaluate(() => window.readout.setWindowKey(true));
  await page.waitForTimeout(1300);
  const key = await page.evaluate(() => window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots));
  check('with the window key (focus in its outline or find field) it is read', key.includes(21), JSON.stringify(key));
  // The window no longer key: the next change waits again.
  await page.evaluate(() => window.readout.setWindowKey(false));
  await page.evaluate(p => window.readout.apply(p), patch(3, [], { marks: [{ slot: 22, kind: 'inserted' }] }));
  await page.waitForTimeout(1300);
  const after = await page.evaluate(() => window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots));
  check('once the window is no longer key, a change in view mid-document waits again', !after.includes(22), JSON.stringify(after));
  await page.close();
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
