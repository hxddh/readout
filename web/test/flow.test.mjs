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
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
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
