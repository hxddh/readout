// Reader interaction tests: keys, jumps, the TOC, popups, read detection,
// Quick Look, heading links and tables. Each section opens its own page.
// Runs in WebKit by default (the production engine) via Playwright.
// Usage: BROWSER=webkit node test/interact.test.mjs  (requires web/build.mjs to have run)
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

async function newPage({ width = 900, height = 700, appearance = {} } = {}) {
  const page = await browser.newPage({ viewport: { width, height } });
  const n = ++pages;
  collectPageErrors(page, errors, `page ${n}: `);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(a => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, ...a }), appearance);
  return page;
}

const patch = (version, ops, extra = {}) => ({ version, reset: false, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ...extra });
function doc(n, html = i => `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`, kind = () => 'paragraph') {
  const ops = [];
  for (let i = 1; i <= n; i++) ops.push({ op: 'insert', slot: i, after: i - 1, html: html(i), kind: kind(i) });
  return patch(1, ops, { reset: true });
}
const corpus = name => JSON.parse(readFileSync(join('test/corpus/patches', name), 'utf8'));
const key = (page, k, o = {}) => page.evaluate(([k, o]) => document.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true, ...o })), [k, o]);
const scrollTop = page => page.evaluate(() => Math.round(document.scrollingElement.scrollTop));
const remaining = page => page.evaluate(() => { const s = document.scrollingElement; return Math.round(s.scrollHeight - s.scrollTop - innerHeight); });
// The top of `sel` once it is the same three frames running (at most 3 s).
async function settledTop(page, sel) {
  return page.evaluate(sel => new Promise(resolve => {
    const t0 = performance.now();
    let last = null, same = 0;
    const frame = () => {
      const top = Math.round(document.querySelector(sel).getBoundingClientRect().top);
      same = top === last ? same + 1 : 0;
      last = top;
      if (same >= 3 || performance.now() - t0 > 3000) resolve(top); else requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }), sel);
}

// Counts writes that set or clear content-visibility on the document's blocks,
// from watchCv until cvWrites.
const watchCv = page => page.evaluate(() => {
  window.__cv = 0;
  window.__cvObserver = new MutationObserver(ms => {
    for (const m of ms) if (/content-visibility/.test(m.oldValue || '') !== /content-visibility/.test(m.target.getAttribute('style') || '')) window.__cv++;
  });
  window.__cvObserver.observe(document.getElementById('ro-doc'), { subtree: true, attributes: true, attributeFilter: ['style'], attributeOldValue: true });
});
const cvWrites = page => page.evaluate(() => { window.__cvObserver.disconnect(); return window.__cv; });

// 1. A table that scrolled in a narrow window fits again once the window, the
//    column or the type size leaves it room.
{
  const page = await newPage({ width: 520, height: 800 });
  const long = 'A full sentence of reasoning about the option, as agents write in comparison tables. '.repeat(2);
  // Headers that cannot wrap (no-break spaces): short cells that can wrap do
  // so before a table scrolls (typography.test.mjs).
  const html = `<div class="table-wrap"><table><thead><tr><th>Option&nbsp;name</th><th>Rationale</th><th>Monthly&nbsp;cost</th><th>Risk&nbsp;level</th><th>Owner&nbsp;team</th><th>Status</th></tr></thead><tbody>
<tr><td>A</td><td>${long}</td><td>12</td><td>low</td><td>team-a</td><td>ok</td></tr><tr><td>B</td><td>${long}</td><td>40</td><td>high</td><td>team-b</td><td>ok</td></tr></tbody></table></div>`;
  await page.evaluate(p => window.readout.apply(p), patch(1, [{ op: 'insert', slot: 1, after: 0, html, kind: 'table' }], { reset: true }));
  await page.waitForTimeout(300);
  const scrolls = () => page.evaluate(() => document.querySelector('.table-wrap').classList.contains('scrolls'));
  const narrow = await scrolls();
  await page.setViewportSize({ width: 1000, height: 800 });
  await page.waitForTimeout(300);
  const wide = await scrolls();
  check('a table that scrolled fits again when the window widens', narrow && !wide, JSON.stringify({ narrow, wide }));
  await page.close();

  // The column (no window resize): a table of long words that fits the wide
  // column but not the narrow one.
  const p2 = await newPage({ width: 1300, height: 800 });
  const words = ['Implementation', 'Responsibility', 'Configuration', 'Documentation', 'Compatibility', 'Infrastructure', 'Observability'];
  const row = words.map(w => `<td>${w}</td>`).join('');
  await p2.evaluate(p => window.readout.apply(p), patch(1, [{ op: 'insert', slot: 1, after: 0, kind: 'table',
    html: `<div class="table-wrap"><table><thead><tr>${words.map(w => `<th>${w}</th>`).join('')}</tr></thead><tbody><tr>${row}</tr></tbody></table></div>` }], { reset: true }));
  await p2.waitForTimeout(300);
  const state = async () => (await p2.evaluate(() => document.querySelector('.table-wrap').classList.contains('scrolls')));
  // (The column is set in rem: a type size change scales it with the table.)
  const steps = { narrow: await state() };
  await p2.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  steps.wide = await state();
  await p2.evaluate(() => window.readout.setAppearance({ width: 'narrow' }));
  steps.narrowAgain = await state();
  await p2.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  steps.wideAgain = await state();
  check('a table that scrolled fits again when the column widens',
    steps.narrow && !steps.wide && steps.narrowAgain && !steps.wideAgain, JSON.stringify(steps));
  await p2.close();
}

// 2. A short page that grows above a reader at its top leaves them at the top
//    while the agent writes on (it used to carry them down once it scrolled).
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(3, i => `<p>para ${i}</p>`));
  await page.evaluate(p => window.readout.apply(p), patch(2, [{ op: 'insert', slot: 50, after: 0, html: '<h1 id="t">Title added on top</h1>', kind: 'heading', anchor: 't' }]));
  for (let v = 3; v < 30; v++) {
    await page.evaluate(v => window.readout.apply({ version: v, reset: false, rewrite: false, ops: [{ op: 'insert', slot: 100 + v, after: v === 3 ? 3 : 100 + v - 1, html: `<p style="min-height:60px">appended ${v}</p>`, kind: 'paragraph' }], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }), v);
  }
  await page.waitForTimeout(100);
  const r = await page.evaluate(() => ({ y: scrollY, h: document.scrollingElement.scrollHeight, title: Math.round(document.querySelector('.k-heading').getBoundingClientRect().top) }));
  check('a reader at the top of a short page stays there when it grows above and below', r.y === 0 && r.h > 1400, JSON.stringify(r));
  await page.close();
}

// 3. The section link sits beside the heading, which is named by its own
//    content as the browser computes it; headings balance their lines.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), patch(1, [
    { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'cost', html: '<h1 id="cost">Cost of <span class="math math-inline" data-tex="O(n^2)">O(n^2)</span> merges<sup class="fn-ref"><a href="#user-content-fn-1" id="user-content-fnref-1" data-footnote-ref>1</a></sup></h1>' },
    { op: 'insert', slot: 2, after: 1, kind: 'heading', anchor: 'long', html: '<h2 id="long">A heading long enough to wrap onto a second line in the column of the reader x</h2>' },
    { op: 'insert', slot: 3, after: 2, kind: 'paragraph', html: '<p>body</p>' },
    { op: 'insert', slot: 4, after: 3, kind: 'footnotes', html: '<section class="footnotes" data-footnotes><ol><li id="user-content-fn-1"><p>A note.</p></li></ol></section>' },
  ], { reset: true }));
  await page.waitForTimeout(500);
  const names = [];
  const walk = n => { if (/heading/i.test(n.role)) names.push(n.name); (n.children || []).forEach(walk); };
  walk(await page.accessibility.snapshot({ interestingOnly: false }));
  const place = await page.evaluate(() => [...document.querySelectorAll('.k-heading')].map(b => {
    const link = b.querySelector('.h-link');
    return { parent: link.parentElement === b, first: b.firstElementChild.localName, label: b.querySelector('h1, h2').getAttribute('aria-label') };
  }));
  const math = names.find(n => /^Cost of/.test(n)) || '';
  check('a heading with math is named by the browser from its content, the formula once, not by its link',
    /O\s*\(\s*n\s*2\s*\)/.test(math) && !/n\^2/.test(math) && !/Copy Link/.test(names.join('|')) && place.every(p => p.parent && /^h\d$/.test(p.first) && p.label === null),
    JSON.stringify({ names, place }));
  // The link stays on the heading's first line, in the gutter, and works from the keyboard.
  const align = await page.evaluate(() => [...document.querySelectorAll('.k-heading')].map(b => {
    const h = b.querySelector('h1, h2'), r = h.getBoundingClientRect(), l = b.querySelector('.h-link').getBoundingClientRect();
    return { mid: Math.round((l.top + l.bottom) / 2 - r.top), lh: Math.round(parseFloat(getComputedStyle(h).lineHeight)), left: Math.round(l.left - b.getBoundingClientRect().left), right: Math.round(r.left - l.right) };
  }));
  check('the section link sits on the heading\'s first line, in the gutter', align.every(a => a.mid > 0 && a.mid < a.lh && a.left >= 0 && a.right >= 0), JSON.stringify(align));
  await page.getByRole('button', { name: 'Copy Link to Section' }).nth(1).focus();
  await page.evaluate(() => { window.__msgs.length = 0; });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(250);
  const msg = await page.evaluate(() => ({ copy: window.__msgs.find(m => m.type === 'copyLink'), shown: getComputedStyle(document.activeElement).opacity }));
  check('the section link is reached and used from the keyboard, and shows while focused', msg.copy?.anchor === 'long' && msg.shown === '1', JSON.stringify(msg));
  // Balanced: the two lines of the long heading are about as long as each other.
  const lines = await page.evaluate(() => {
    const h = document.getElementById('long');
    const range = document.createRange();
    range.selectNodeContents(h);
    const rows = new Map();
    for (const r of range.getClientRects()) { const k = Math.round(r.top); rows.set(k, Math.max(rows.get(k) || 0, r.right)); }
    const left = h.getBoundingClientRect().left;
    return { wrap: getComputedStyle(h).textWrap || getComputedStyle(h).textWrapStyle, widths: [...rows.values()].map(r => Math.round(r - left)), column: Math.round(h.getBoundingClientRect().width) };
  });
  check('a heading that wraps balances its lines', lines.widths.length === 2 && Math.abs(lines.widths[0] - lines.widths[1]) < lines.column * 0.25, JSON.stringify(lines));
  await page.close();
}

// 4. A TOC jump shows the section clicked as the current one, even with the
//    next heading close under it, until the reader scrolls; in a large
//    document it lands where it aimed.
{
  const page = await newPage({ appearance: { topInset: 52 } });
  // Sections whose first subsection follows their heading closely.
  const review = corpus('08-clawd-tank-code-review.json');
  await page.evaluate(p => window.readout.apply(p), review);
  await page.waitForTimeout(300);
  const active = () => page.evaluate(() => window.__msgs.filter(m => m.type === 'activeHeading').pop()?.slot);
  const clicked = [];
  for (const slot of [7, 14, 33, 51]) {
    await page.evaluate(s => window.readout.scrollToSlot(s), slot);
    await page.waitForTimeout(300);
    clicked.push([slot, await active()]);
  }
  await page.evaluate(() => window.scrollBy(0, 400));
  await page.waitForTimeout(300);
  const scrolled = await active();
  check('a TOC jump reports the section clicked until the reader scrolls', clicked.every(([s, a]) => s === a) && scrolled !== 51, JSON.stringify({ clicked, scrolled }));
  // A patch that turns the section's heading into another kind of block ends the pin.
  await page.evaluate(() => window.readout.scrollToSlot(33));
  await page.waitForTimeout(200);
  await page.evaluate(() => window.readout.apply({ version: 99, reset: false, rewrite: false, ops: [{ op: 'replace', slot: 33, html: '<p>no longer a heading</p>', kind: 'paragraph', change: 'content' }], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }));
  await page.waitForTimeout(200);
  const replaced = await active();
  check('a TOC pin ends when its heading becomes another kind of block', replaced !== 33 && replaced != null, `active=${replaced}`);
  await page.close();

  // A large document (content-visibility): from the top to headings far down.
  const p2 = await newPage({ appearance: { topInset: 52 } });
  const big = corpus('17-dataagent-tdd-design.json');
  await p2.evaluate(p => window.readout.apply(p), big);
  await p2.waitForTimeout(400);
  const offs = [];
  for (const e of [...big.toc].reverse().filter((_, i) => i % 5 === 0).slice(0, 12)) {
    await p2.evaluate(() => window.scrollTo(0, 0));
    await p2.waitForTimeout(100);
    await p2.evaluate(s => window.readout.scrollToSlot(s), e.slot);
    await p2.waitForTimeout(400);
    offs.push(await p2.evaluate(s => {
      const se = document.scrollingElement;
      const top = Math.round(document.querySelector(`.blk[data-slot="${s}"]`).getBoundingClientRect().top);
      return { s, top, end: se.scrollTop >= se.scrollHeight - innerHeight - 1, active: window.__msgs.filter(m => m.type === 'activeHeading').pop()?.slot };
    }, e.slot));
  }
  // Aiming again never undoes the reader scrolling away right after the jump.
  const away = await p2.evaluate(async s => {
    window.scrollTo(0, 0);
    await new Promise(r => setTimeout(r, 100));
    window.readout.scrollToSlot(s);
    await new Promise(r => requestAnimationFrame(r));
    window.scrollTo(0, 0);
    await new Promise(r => setTimeout(r, 600));
    return Math.round(document.scrollingElement.scrollTop);
  }, big.toc.at(-1).slot);
  check('scrolling away right after a TOC jump stays where the reader went', away === 0, `scrollTop=${away}`);
  const cv = await p2.evaluate(() => document.getElementById('ro-doc').classList.contains('cv'));
  check('TOC jumps in a large document land the heading under the toolbar and report it', cv && offs.every(o => (o.end || Math.abs(o.top - 68) <= 2) && o.active === o.s), JSON.stringify(offs));
  await p2.close();
}

// 5. Keys: End / Command-Down and G reach the end of a large document,
//    Home / Command-Up the top; j and k step like the arrow keys; Caps Lock
//    does not turn n into N or g into G.
{
  const page = await newPage({ appearance: { topInset: 52 } });
  await page.evaluate(p => window.readout.apply(p), corpus('13-swagger-ui-claude-md.json'));
  await page.waitForTimeout(400);
  // End, Home and Command-arrows are pressed for real: WebKit scrolls by itself for them.
  const ends = {};
  for (const k of ['End', 'Meta+ArrowDown', 'Shift+G']) {
    await page.evaluate(() => window.scrollTo(0, 1));
    await page.waitForTimeout(100);
    await page.keyboard.press(k);
    await page.waitForTimeout(700);
    ends[k] = await remaining(page);
  }
  const tops = {};
  for (const k of ['Home', 'Meta+ArrowUp', 'g']) {
    await page.evaluate(() => window.scrollTo(0, 5000));
    await page.waitForTimeout(100);
    await page.keyboard.press(k);
    await page.waitForTimeout(700);
    tops[k] = await scrollTop(page);
  }
  check('End, Command-Down and G reach the end of a large document', Object.values(ends).every(r => r <= 1), JSON.stringify(ends));
  check('Home, Command-Up and g reach the top', Object.values(tops).every(y => y === 0), JSON.stringify(tops));
  // Caps Lock: the letters arrive upper case without Shift.
  await page.evaluate(() => window.scrollTo(0, 5000));
  await page.waitForTimeout(100);
  await key(page, 'G');
  await page.waitForTimeout(300);
  const capsG = await scrollTop(page);
  await page.evaluate(() => window.scrollTo(0, 3000));
  await page.waitForTimeout(150);
  const y0 = await scrollTop(page);
  await key(page, 'j');
  await page.waitForTimeout(500);
  const dj = (await scrollTop(page)) - y0;
  await key(page, 'K');
  await page.waitForTimeout(500);
  const dk = (await scrollTop(page)) - y0 - dj;
  check('Caps Lock G goes to the top; j and k (any case) step 40 px like the arrow keys', capsG === 0 && dj === 40 && dk === -40, JSON.stringify({ capsG, dj, dk }));
  await page.close();

  const p2 = await newPage();
  const r = doc(60, i => `<p style="min-height:120px">para ${i}</p>`);
  r.marks = [{ slot: 20, kind: 'inserted' }, { slot: 50, kind: 'inserted' }];
  await p2.evaluate(p => window.readout.apply(p), r);
  await p2.evaluate(() => window.scrollTo(0, 0));
  await p2.waitForTimeout(100);
  await key(p2, 'N');   // Caps Lock on, no Shift: forward
  await p2.waitForTimeout(600);
  const caps = await p2.evaluate(() => Math.round(document.querySelector('.blk[data-slot="20"]').getBoundingClientRect().top - innerHeight / 3));
  check('Caps Lock N jumps forward, as n does', Math.abs(caps) <= 2, `offset=${caps}`);
  await p2.close();
}

// 6. The removed-text popup stays open for a click inside it (to select and
//    copy); Escape closes popups and comparisons.
{
  const page = await newPage();
  const r = doc(10, i => `<p>para ${i}</p>`);
  r.ops[2].html = '<p>edited text</p>';
  r.marks = [{ slot: 3, kind: 'modified', diff: '<del>old</del><ins>edited</ins> text' }];
  r.deletions = [{ id: 7, after: 5, count: 1, preview: 'the removed paragraph' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.click('.del-mark[data-del="7"] button');
  const opened = await page.evaluate(() => !!document.querySelector('.del-pop'));
  await page.click('.del-pop');
  const afterInside = await page.evaluate(() => !!document.querySelector('.del-pop'));
  await page.evaluate(() => window.readout.toggleDiff(3));
  const diffOpen = await page.evaluate(() => !!document.querySelector('.wd-panel'));
  await page.keyboard.press('Escape');
  const afterEsc = await page.evaluate(() => ({ pop: !!document.querySelector('.del-pop'), diff: !!document.querySelector('.wd-panel') }));
  check('a click inside the removed-text popup keeps it open', opened && afterInside, JSON.stringify({ opened, afterInside }));
  check('Escape closes the removed-text popup and open comparisons', diffOpen && !afterEsc.pop && !afterEsc.diff, JSON.stringify({ diffOpen, afterEsc }));
  await page.click('.del-mark[data-del="7"] button');
  await page.click('.blk[data-slot="1"]');
  check('a click elsewhere still closes it', await page.evaluate(() => !document.querySelector('.del-pop')));
  await page.close();
}

// 7. A change in view while the window is in the background is read only
//    once it has been seen for the full 800 ms after the window comes back.
//    (The page is taller than the window and the reader at its top: a page
//    that fits the window is all on screen, and a reader watching it from
//    another window reads what changes in it, case 20. This case used five
//    short paragraphs, a page that fits, which 3.7 reads unfocused.)
{
  const page = await newPage();
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; });
  const r = doc(40, i => `<p style="min-height:60px">para ${i}</p>`);
  r.marks = [{ slot: 2, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  const read = () => page.evaluate(() => window.__msgs.some(m => m.type === 'read' && m.slots.includes(2)));
  await page.waitForTimeout(1750);
  const background = await read();
  await page.evaluate(() => { window.__focused = true; window.dispatchEvent(new Event('focus')); });
  await page.waitForTimeout(450);
  const soon = await read();
  await page.waitForTimeout(700);
  const later = await read();
  check('a change is read 800 ms after the window comes back, not at once', !background && !soon && later, JSON.stringify({ background, soon, later }));
  await page.close();
}

// 8. Quick Look: no Copy buttons, no section links, remote images as text.
{
  const page = await newPage({ appearance: { mode: 'quicklook' } });
  await page.evaluate(p => window.readout.apply(p), patch(1, [
    { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'ql', html: '<h2 id="ql">Quick Look</h2>' },
    { op: 'insert', slot: 2, after: 1, kind: 'code', html: '<div class="code-block" data-lang="js"><pre><code>let a = 1;</code></pre></div>' },
    { op: 'insert', slot: 3, after: 2, kind: 'paragraph', html: '<p><span class="remote-img" data-src="https://img.example/a.png" data-alt="A"></span></p>' },
  ], { reset: true }));
  const r = await page.evaluate(() => ({
    copy: getComputedStyle(document.querySelector('.cb-copy')).display,
    link: getComputedStyle(document.querySelector('.h-link')).display,
    remoteButtons: document.querySelectorAll('.remote-img button').length,
    remoteText: document.querySelector('.remote-img').textContent,
  }));
  check('Quick Look shows no Copy button, no section link, and remote images as text only',
    r.copy === 'none' && r.link === 'none' && r.remoteButtons === 0 && r.remoteText.includes('img.example'), JSON.stringify(r));
  await page.close();
}

// 9. n with nothing unread asks the app for a beep; n and a rail tick move
//    the keyboard focus to the change they go to.
{
  const page = await newPage();
  const r = doc(40, i => `<p style="min-height:120px">para ${i}</p>`);
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => { window.__msgs.length = 0; });
  await key(page, 'n');
  await key(page, 'n', { shiftKey: true });
  const nothing = await page.evaluate(() => window.__msgs.filter(m => m.type === 'nothing').length);
  check('n and Shift-N with nothing unread post "nothing"', nothing === 2, `count=${nothing}`);
  r.version = 2;
  r.marks = [{ slot: 15, kind: 'inserted' }, { slot: 30, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.scrollTo(0, 0));
  await key(page, 'n');
  const focusN = await page.evaluate(() => document.activeElement?.dataset?.slot);
  await page.waitForTimeout(500);
  const railFocus = await page.evaluate(() => {
    document.querySelectorAll('#ro-rail button')[1].click();
    return { slot: document.activeElement?.dataset?.slot, outline: getComputedStyle(document.activeElement).outlineStyle };
  });
  check('n and a rail tick move the keyboard focus to the change, without a focus ring', focusN === '15' && railFocus.slot === '30' && railFocus.outline === 'none', JSON.stringify({ focusN, railFocus }));
  await page.close();
}

// 10. A rail tick is clickable left of its 3 px mark.
{
  const page = await newPage();
  const r = doc(40, i => `<p style="min-height:120px">para ${i}</p>`);
  r.marks = [{ slot: 20, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.waitForTimeout(400);
  const hit = await page.evaluate(() => {
    const b = document.querySelector('#ro-rail button');
    const rect = b.getBoundingClientRect();
    const y = (rect.top + rect.bottom) / 2;
    const visual = rect.right - parseFloat(getComputedStyle(b).paddingLeft) - rect.left;
    const at = x => document.elementFromPoint(x, y) === b;
    return { visual: Math.round(rect.width - parseFloat(getComputedStyle(b).paddingLeft)), right: Math.round(innerWidth - rect.right), at4: at(rect.right - 1 - 4), at10: at(rect.right - 1 - 11), clip: getComputedStyle(b).backgroundClip, v: visual };
  });
  check('a rail tick is clickable 10 px left of its 3 px mark, the mark itself unchanged', hit.visual === 3 && hit.right === 2 && hit.at4 && hit.at10 && hit.clip === 'content-box', JSON.stringify(hit));
  await page.close();
}

// 11. A window on screen but not focused (Readout beside the terminal the
//     agent runs in): what arrives at the end the reader follows is read
//     after 1.5 s; elsewhere in the document, or in a hidden window, it waits.
{
  const page = await newPage();
  const tall = doc(40, i => `<p style="min-height:60px">para ${i}</p>`);
  await page.evaluate(p => window.readout.apply(p), tall);
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(100);
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; window.dispatchEvent(new Event('blur')); window.__msgs.length = 0; });
  const read = slot => page.evaluate(s => window.__msgs.some(m => m.type === 'read' && m.slots.includes(s)), slot);
  const append = (v, slot, after) => page.evaluate(p => window.readout.apply(p), patch(v, [{ op: 'insert', slot, after, kind: 'paragraph', html: `<p>the agent wrote ${slot}</p>` }],
    { marks: [{ slot, kind: 'inserted' }] }));
  await append(2, 41, 40);
  await page.waitForTimeout(1000);
  const early = await read(41);
  await page.waitForTimeout(900);
  const following = await read(41);
  const atEnd = await page.evaluate(() => { const s = document.scrollingElement; return s.scrollHeight - s.scrollTop - innerHeight < 48; });
  // Away from the end: it waits for the reader.
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(p => window.readout.apply(p), patch(3, [{ op: 'insert', slot: 42, after: 1, kind: 'paragraph', html: '<p>inserted near the top</p>' }],
    { marks: [{ slot: 41, kind: 'inserted' }, { slot: 42, kind: 'inserted' }] }));
  await page.waitForTimeout(2000);
  const away = await read(42);
  // Hidden (minimised, another space): it waits too, even at the end.
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); window.scrollTo(0, document.scrollingElement.scrollHeight); });
  await append(4, 43, 41);
  await page.waitForTimeout(2000);
  const hidden = await read(43);
  check('unfocused but on screen: a change at the end the reader follows is read after 1.5 s, not elsewhere or hidden',
    atEnd && !early && following && !away && !hidden, JSON.stringify({ atEnd, early, following, away, hidden }));
  await page.close();
}

// 12. A change N went to is read once it has been on screen for 300 ms, or
//     when N leaves it after 250 ms; going past the last one says so.
{
  const page = await newPage();
  const r = doc(60, i => `<p style="min-height:100px">para ${i}</p>`);
  // The first on screen already: its own 800 ms dwell starts with the patch.
  r.marks = [{ slot: 4, kind: 'inserted' }, { slot: 30, kind: 'modified' }, { slot: 50, kind: 'inserted' }];
  await page.evaluate(p => { window.scrollTo(0, 0); window.__msgs.length = 0; window.readout.apply(p); }, r);
  const readSlots = () => page.evaluate(() => window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots));
  await key(page, 'n');
  await page.waitForTimeout(600);
  const dwell = await readSlots();
  // Pressing on: each change left after 250 ms is read.
  await key(page, 'n');
  await page.waitForTimeout(260);
  await key(page, 'n');
  await page.waitForTimeout(200);
  const pressed = await readSlots();
  check('a change N went to is read after 300 ms on screen, or when N leaves it after 250 ms',
    dwell.includes(4) && !dwell.includes(30) && pressed.includes(30), JSON.stringify({ dwell, pressed }));
  // Past the last change: back to the first unread one, and the app hears of it.
  const r2 = doc(60, i => `<p style="min-height:100px">para ${i}</p>`);
  r2.version = 5;
  r2.marks = [{ slot: 10, kind: 'inserted' }, { slot: 20, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r2);
  await page.evaluate(() => { window.scrollTo(0, document.scrollingElement.scrollHeight); window.__msgs.length = 0; });
  await page.waitForTimeout(100);
  await key(page, 'n');
  const wrap = await page.evaluate(() => ({ wrapped: window.__msgs.filter(m => m.type === 'wrapped').length, nothing: window.__msgs.filter(m => m.type === 'nothing').length, at: document.activeElement?.dataset?.slot }));
  check('N past the last change wraps to the first and posts "wrapped"', wrap.wrapped === 1 && wrap.nothing === 0 && wrap.at === '10', JSON.stringify(wrap));
  await page.close();
}

// 13. The "Rewritten" notice counts down only while the window is focused
//     and visible: one that arrived in the background is still there.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(10));
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; window.dispatchEvent(new Event('blur')); });
  const rw = doc(10, i => `<p>rewritten ${i}</p>`);
  rw.version = 2; rw.rewrite = true;
  rw.ops.forEach(o => { o.slot += 100; o.after = o.after ? o.after + 100 : 0; });
  await page.evaluate(p => window.readout.apply(p), rw);
  const shown = () => page.evaluate(() => !document.getElementById('ro-notice').hidden);
  await page.waitForTimeout(6800);
  const background = await shown();
  await page.evaluate(() => { window.__focused = true; window.dispatchEvent(new Event('focus')); });
  await page.waitForTimeout(3000);
  const soon = await shown();
  await page.waitForTimeout(3800);
  const later = await shown();
  check('the Rewritten notice waits in the background and counts down once focused', background && soon && !later, JSON.stringify({ background, soon, later }));
  await page.close();
}

// 14. On a rewrite the reader goes to the section they were in, if it is
//     still there, else to the top (not where the old offset lands).
{
  const page = await newPage({ appearance: { topInset: 52 } });
  const sections = (base, names) => {
    const ops = [];
    let slot = base;
    for (const name of names) {
      ops.push({ op: 'insert', slot: ++slot, after: slot - 1 === base ? 0 : slot - 1, kind: 'heading', anchor: name, html: `<h2 id="${name}">${name}</h2>` });
      for (let i = 0; i < 12; i++) ops.push({ op: 'insert', slot: ++slot, after: slot - 1, kind: 'paragraph', html: `<p>${name} ${i} ${'lorem ipsum dolor sit amet '.repeat(5)}</p>` });
    }
    return ops;
  };
  await page.evaluate(p => window.readout.apply(p), patch(1, sections(0, ['alpha', 'beta', 'gamma']), { reset: true }));
  const intoBeta = () => page.evaluate(() => { const h = document.querySelector('[data-anchor="beta"]'); window.scrollBy(0, h.getBoundingClientRect().top + 300); });
  await intoBeta();
  await page.waitForTimeout(100);
  await page.evaluate(p => window.readout.apply(p), patch(2, sections(1000, ['intro', 'beta', 'delta']), { reset: true, rewrite: true }));
  const kept = await page.evaluate(() => Math.round(document.querySelector('[data-anchor="beta"]').getBoundingClientRect().top));
  await intoBeta();
  await page.waitForTimeout(100);
  await page.evaluate(p => window.readout.apply(p), patch(3, sections(2000, ['one', 'two', 'three', 'four']), { reset: true, rewrite: true }));
  const top = await scrollTop(page);
  check('a rewrite keeps the reader in their section if it is still there, else goes to the top', kept === 52 + 16 && top === 0, JSON.stringify({ kept, top }));
  await page.close();
}

// 15. Copying: the panels open in the document stay out, math copies as its
//     TeX, task boxes as [ ] / [x], footnote references as [^n] without the
//     ↩ links back. A selection inside a panel copies as it is.
{
  const page = await newPage();
  const r = patch(1, [
    { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'plan', html: '<h2 id="plan">Plan</h2>' },
    { op: 'insert', slot: 2, after: 1, kind: 'paragraph', html: '<p>The cache uses Postgres.<sup class="fn-ref"><a href="#user-content-fn-1" id="user-content-fnref-1" data-footnote-ref>1</a></sup> Energy is <span class="math math-inline" data-tex="E=mc^2">E=mc^2</span> here.</p>' },
    { op: 'insert', slot: 3, after: 2, kind: 'math', html: '<div class="math-block" data-tex="\\int_0^1 x\\,dx">\\int_0^1 x\\,dx</div>' },
    { op: 'insert', slot: 4, after: 3, kind: 'listItem', html: '<ul class="li-block"><li class="task"><span class="task-box" aria-hidden="true"></span>Step one</li><li class="task"><span class="task-box checked" aria-hidden="true"></span>Step two</li></ul>' },
    { op: 'insert', slot: 5, after: 4, kind: 'paragraph', html: '<p>Last words.</p>' },
    { op: 'insert', slot: 6, after: 5, kind: 'footnotes', html: '<section class="footnotes" data-footnotes><ol><li id="user-content-fn-1"><p>The note. <a href="#user-content-fnref-1" class="fn-back" data-footnote-backref aria-label="Back">↩</a></p></li></ol></section>' },
  ], { reset: true, marks: [{ slot: 2, kind: 'modified', diff: 'The cache uses <del>Redis</del><ins>Postgres</ins>.' }],
       deletions: [{ id: 1, after: 4, count: 1, preview: 'A removed paragraph.' }] });
  await page.evaluate(p => window.readout.apply(p), r);
  for (let i = 0; i < 100 && !(await page.evaluate(() => document.querySelectorAll('.katex').length === 2)); i++) await page.waitForTimeout(50);
  await page.evaluate(() => { window.readout.toggleDiff(2); document.querySelector('.del-mark > button').click(); });
  const copy = sel => page.evaluate(sel => {
    const out = {};
    const grab = e => { out.text = e.clipboardData.getData('text/plain'); out.html = e.clipboardData.getData('text/html'); out.handled = e.defaultPrevented; };
    window.addEventListener('copy', grab);
    const range = document.createRange();
    range.selectNodeContents(document.querySelector(sel));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    out.native = getSelection().toString();
    document.execCommand('copy');
    window.removeEventListener('copy', grab);
    return out;
  }, sel);
  const all = await copy('#ro-doc');
  const t = all.text || '';
  const want = ['Plan', 'The cache uses Postgres.[^1] Energy is $E=mc^2$ here.', '$$\\int_0^1 x\\,dx$$', '[ ] Step one', '[x] Step two', 'Last words.', '[^1]: The note.'];
  const unwanted = ['Changes since', 'Redis', 'A removed paragraph', '↩', 'mc2'];
  check('copy writes math as TeX, tasks as [ ]/[x], footnotes as [^n], without the open panels',
    all.handled && want.every(w => t.includes(w)) && !unwanted.some(u => t.includes(u)),
    JSON.stringify({ missing: want.filter(w => !t.includes(w)), present: unwanted.filter(u => t.includes(u)), t }));
  check('the copied rich text carries the same cleaned-up content',
    !/wd-panel|del-pop|katex|<button|data-slot/.test(all.html || '') && (all.html || '').includes('$E=mc^2$'), (all.html || '').slice(0, 400));
  const inPop = await copy('.del-pop');
  check('a selection inside the removed-text popup copies as it is', !inPop.handled && inPop.native === 'A removed paragraph.', JSON.stringify(inPop));
  await page.close();
}

// 16. A link's tooltip says where it goes: the address, the path as written,
//     the section; an author's title stays, footnote links get none.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), patch(1, [
    { op: 'insert', slot: 1, after: 0, kind: 'paragraph', html: '<p><a href="https://example.com/a%20b">web</a> <a href="docs/setup%20guide.md#L42">file</a> <a href="#install">section</a> <a href="https://x.dev" title="Author title">titled</a> <a href="readout://file/Users/me/notes.md">own</a><sup class="fn-ref"><a href="#user-content-fn-1" data-footnote-ref>1</a></sup></p>' },
  ], { reset: true }));
  const titles = await page.evaluate(() => [...document.querySelectorAll('#ro-doc a')].map(a => a.title));
  check('link tooltips show the destination, never readout: internals',
    JSON.stringify(titles) === JSON.stringify(['https://example.com/a b', 'docs/setup guide.md#L42', '#install', 'Author title', '/Users/me/notes.md', '']), JSON.stringify(titles));
  await page.close();
}

// 17. The first open of a large document reads no layout before its first
//     frame, and a patch to it forces none of the layouts it used to
//     (offsetParent for every block, a reflow to restart the flash, the
//     trace's scroll height); heights still come in, from the resize observer.
{
  const page = await newPage();
  await page.evaluate(() => {
    const counts = window.__layoutReads = {};
    window.__counting = false;
    const count = name => { if (window.__counting) counts[name] = (counts[name] || 0) + 1; };
    const wrapGetter = (proto, name) => {
      const d = Object.getOwnPropertyDescriptor(proto, name);
      Object.defineProperty(proto, name, { ...d, get() { count(name); return d.get.call(this); } });
    };
    for (const n of ['offsetParent', 'offsetWidth', 'offsetHeight', 'offsetTop']) wrapGetter(HTMLElement.prototype, n);
    for (const n of ['scrollTop', 'scrollHeight', 'clientHeight', 'clientWidth']) wrapGetter(Element.prototype, n);
    const gbcr = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function () { count('getBoundingClientRect'); return gbcr.call(this); };
    const gcs = window.getComputedStyle;
    window.getComputedStyle = function (...a) { count('getComputedStyle'); return gcs.apply(this, a); };
  });
  const big = doc(600, i => i % 50 === 1 ? `<h2 id="s${i}">Section ${i}</h2>` : i % 7 === 0
    ? '<div class="code-block" data-lang="js"><pre><code>const answer = 42;</code></pre></div>'
    : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`, i => i % 50 === 1 ? 'heading' : i % 7 === 0 ? 'code' : 'paragraph');
  big.ops.forEach(o => { if (o.kind === 'heading') o.anchor = `s${o.slot}`; });
  const first = await page.evaluate(p => {
    window.__counting = true;
    window.readout.apply(p);
    window.__counting = false;
    const reads = { ...window.__layoutReads };
    const code7 = document.querySelector('.blk[data-slot="7"] .code-block').dataset.hl;
    return new Promise(r => requestAnimationFrame(() => setTimeout(() => setTimeout(() => r({ reads, code7,
      active: window.__msgs.filter(m => m.type === 'activeHeading').length }), 50), 0)));
  }, big);
  check('the first open of a large document reads no layout before its first frame',
    Object.keys(first.reads).length === 0 && first.code7 !== 'pending' && first.active >= 1, JSON.stringify(first));
  // Heights from the resize observer: a block above the reader that grows does not push them down.
  await page.evaluate(() => window.scrollBy(0, document.querySelector('.blk[data-slot="300"]').getBoundingClientRect().top));
  // Measured once the page has settled (the blocks the scroll brought on
  // screen laid out, their compensation made), not after a fixed time a
  // loaded machine can overrun (it measured -38 then, once in four runs).
  const top300 = () => settledTop(page, '.blk[data-slot="300"]');
  const before = await top300();
  await page.evaluate(() => { document.querySelector('.blk[data-slot="250"] p').style.paddingTop = '200px'; });
  await page.waitForTimeout(100);
  const after = await top300();
  check('heights taken from the resize observer still keep the place', Math.abs(after - before) <= 1, JSON.stringify({ before, after }));
  // A patch in the middle of reading.
  const edit = (v, text) => patch(v, [301, 302, 450].map(slot => ({ op: 'replace', slot, kind: 'paragraph', change: 'content', html: `<p>${text} ${slot}</p>` })),
    { marks: [301, 302, 450].map(slot => ({ slot, kind: 'modified' })) });
  const reads = await page.evaluate(p => {
    for (const k of Object.keys(window.__layoutReads)) delete window.__layoutReads[k];
    window.__counting = true;
    window.readout.apply(p);
    window.__counting = false;
    return { ...window.__layoutReads };
  }, edit(2, 'edited'));
  const flash1 = await page.evaluate(() => document.querySelector('.blk[data-slot="301"]').className);
  await page.evaluate(p => window.readout.apply(p), edit(3, 'edited again'));
  const flash2 = await page.evaluate(() => document.querySelector('.blk[data-slot="301"]').className);
  // (The anchor block's own offsetParent, and the scroll height that tells
  // whether the reader follows the end, read before the patch changes anything.)
  check('a patch reads no offsetParent per block, forces no reflow for the flash, and no scroll height after it',
    (reads.offsetParent || 0) <= 4 && !reads.offsetWidth && (reads.scrollHeight || 0) <= 1, JSON.stringify(reads));
  check('a flash running restarts under the other name', /\bflash\b/.test(flash1) && !/flash-alt/.test(flash1) && /flash-alt/.test(flash2), JSON.stringify({ flash1, flash2 }));
  await page.close();
}

// 18. A wide table far down a large document scrolls from the first open
//     (its block is skipped by the first frame, which lays out the screen
//     only): measured once it comes on screen, its block laid out then (3.8:
//     not at once, every such block laid out for the moment, which cost ~1 s
//     at 1 MB), and no block's content-visibility is set for it.
{
  const page = await newPage({ width: 600, height: 700 });
  const words = ['Implementation', 'Responsibility', 'Configuration', 'Documentation', 'Compatibility', 'Infrastructure', 'Observability'];
  const table = `<div class="table-wrap"><table><thead><tr>${words.map(w => `<th>${w}</th>`).join('')}</tr></thead><tbody><tr>${words.map(w => `<td>${w}</td>`).join('')}</tr></tbody></table></div>`;
  const big = doc(400, i => i === 350 || i === 3 ? table : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`, i => i === 350 || i === 3 ? 'table' : 'paragraph');
  await watchCv(page);
  await page.evaluate(p => window.readout.apply(p), big);
  await page.waitForTimeout(500);
  const near = await page.evaluate(() => document.querySelector('.blk[data-slot="3"] .table-wrap').classList.contains('scrolls'));
  await page.evaluate(() => window.scrollBy(0, document.querySelector('.blk[data-slot="350"]').getBoundingClientRect().top - 100));
  await settledTop(page, '.blk[data-slot="350"]');
  const far = await page.evaluate(() => document.querySelector('.blk[data-slot="350"] .table-wrap').classList.contains('scrolls'));
  const r = { near, far, writes: await cvWrites(page) };
  check('a wide table scrolls from the first open, on screen or far below, with no block forced', r.near && r.far && r.writes === 0, JSON.stringify(r));
  await page.close();
}

// 19. Reopening a large document at a saved place (the app's resume calls
//     scrollToAnchor right after the first apply): blocks above the place
//     that the first frame lays out at another height than their estimate
//     do not move it (3.6 first open kept no height baseline: 536 px off).
{
  const page = await newPage({ width: 1000, height: 800 });
  const img = '<p class="img-only"><img width="600" height="400" alt="diagram" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></p>';
  const big = doc(600, i => i === 398 || i === 399 ? img : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(1 + (i % 9))}</p>`, () => 'paragraph');
  await page.evaluate(p => { window.readout.apply(p); window.readout.scrollToAnchor({ slot: 400, offset: 0, ratio: 0 }); }, big);
  await page.waitForTimeout(1000);
  const top = await page.evaluate(() => Math.round(document.querySelector('.blk[data-slot="400"]').getBoundingClientRect().top));
  check('a large document reopened at a saved place stays there', Math.abs(top) <= 2, `top=${top}`);
  await page.close();
}

// 20. A page that fits the window, watched from the terminal beside it (on
//     screen, unfocused): what the agent changes in it is read after 1.5 s,
//     as at the end of a longer page (it never was: the page had no end to
//     be at, scrolled to nowhere). Grown past the window, it follows.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(4, i => `<p>para ${i}</p>`));
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; window.dispatchEvent(new Event('blur')); window.__msgs.length = 0; });
  await page.evaluate(p => window.readout.apply(p), patch(2, [
    { op: 'replace', slot: 2, kind: 'paragraph', change: 'content', html: '<p>para 2, edited by the agent</p>' },
    { op: 'insert', slot: 5, after: 4, kind: 'paragraph', html: '<p>Next: run the full suite.</p>' }],
    { marks: [{ slot: 2, kind: 'modified' }, { slot: 5, kind: 'inserted' }] }));
  const read = s => page.evaluate(s => window.__msgs.some(m => m.type === 'read' && m.slots.includes(s)), s);
  await page.waitForTimeout(1100);
  const early = (await read(2)) || (await read(5));
  await page.waitForTimeout(1000);
  const both = (await read(2)) && (await read(5));
  const ops = [];
  for (let i = 6; i < 40; i++) ops.push({ op: 'insert', slot: i, after: i - 1, kind: 'paragraph', html: `<p style="min-height:60px">step ${i}</p>` });
  await page.evaluate(p => window.readout.apply(p), patch(3, ops));
  await page.waitForTimeout(100);
  const grown = { y: await scrollTop(page), left: await remaining(page) };
  check('a page that fits the window, watched unfocused: its changes are read after 1.5 s, and it follows once it grows',
    !early && both && grown.y > 0 && grown.left < 48, JSON.stringify({ early, both, grown }));
  await page.close();
}

// 21. A rewrite while the reader is at the end (following the old text)
//     takes them to their section, or the top, with the notice in view: not
//     to the end of a document they have not read.
{
  const page = await newPage();
  const sections = (base, names) => {
    const ops = [];
    let slot = base;
    for (const name of names) {
      ops.push({ op: 'insert', slot: ++slot, after: slot - 1 === base ? 0 : slot - 1, kind: 'heading', anchor: name, html: `<h2 id="${name}">${name}</h2>` });
      for (let i = 0; i < 12; i++) ops.push({ op: 'insert', slot: ++slot, after: slot - 1, kind: 'paragraph', html: `<p>${name} ${i} ${'lorem ipsum dolor sit amet '.repeat(5)}</p>` });
    }
    return ops;
  };
  await page.evaluate(p => window.readout.apply(p), patch(1, sections(0, ['alpha', 'beta']), { reset: true }));
  const toEnd = async () => { await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight)); await page.waitForTimeout(100); };
  await toEnd();
  await page.evaluate(p => window.readout.apply(p), patch(2, sections(1000, ['one', 'two', 'three']), { reset: true, rewrite: true }));
  const top = { y: await scrollTop(page), notice: await page.evaluate(() => { const n = document.getElementById('ro-notice'); const r = n.getBoundingClientRect(); return !n.hidden && r.bottom > 0 && r.top < innerHeight; }) };
  await toEnd();
  await page.evaluate(p => window.readout.apply(p), patch(3, sections(2000, ['intro', 'three', 'four', 'five']), { reset: true, rewrite: true }));
  const section = { three: await page.evaluate(() => Math.round(document.querySelector('[data-anchor="three"]').getBoundingClientRect().top)), left: await remaining(page) };
  check('a rewrite at the end goes to the reader\'s section or the top, the notice in view, not to the new end',
    top.y === 0 && top.notice && section.three === 16 && section.left > 300, JSON.stringify({ top, section }));
  await page.close();
}

// 22. N after an outline click, Home or a #section: the change right under
//     where the page landed is the next one (N looks a third down the
//     screen, which skipped it), until the reader scrolls.
{
  const page = await newPage();
  const big = doc(80, i => i % 20 === 1 ? `<h2 id="s${i}">Section ${i}</h2>` : `<p style="min-height:60px">para ${i}</p>`, i => i % 20 === 1 ? 'heading' : 'paragraph');
  big.ops.forEach(o => { if (o.kind === 'heading') o.anchor = `s${o.slot}`; });
  big.marks = [2, 22, 30, 42, 46].map(slot => ({ slot, kind: 'modified' }));
  let version = 1;
  // The marks again, unread (each step reads what it went to).
  const fresh = () => page.evaluate(p => window.readout.apply(p), { ...big, version: version++ });
  await fresh();
  const at = () => page.evaluate(() => document.activeElement?.dataset?.slot);
  const wrapped = () => page.evaluate(() => window.__msgs.filter(m => m.type === 'wrapped').length);
  await page.evaluate(() => { window.__msgs.length = 0; window.readout.scrollToSlot(41); });
  const under = await page.evaluate(() => Math.round(document.querySelector('.blk[data-slot="42"]').getBoundingClientRect().top));
  await key(page, 'n');
  const outline = await at();
  await key(page, 'n');
  const next = await at();
  // Scrolled since: from a third down the screen again.
  await fresh();
  await page.evaluate(() => { window.readout.scrollToSlot(41); window.scrollBy(0, 5); });
  await page.waitForTimeout(50);
  await key(page, 'n');
  const scrolled = await at();
  await fresh();
  await page.evaluate(() => window.scrollTo(0, 1500));
  await page.waitForTimeout(50);
  await key(page, 'Home');
  await page.waitForTimeout(50);
  await key(page, 'n');
  const home = await at();
  await fresh();
  await page.evaluate(() => window.scrollTo(0, 3000));
  await page.waitForTimeout(50);
  await page.evaluate(() => window.readout.scrollToFragment({ fragment: '#s21' }));
  await key(page, 'n');
  const fragment = await at();
  const r = { under, outline, next, scrolled, home, fragment, wrapped: await wrapped() };
  check('N goes to the change right under where an outline click, Home or a #section landed',
    under < 700 / 3 && outline === '42' && next === '46' && scrolled === '46' && home === '2' && fragment === '22' && r.wrapped === 0, JSON.stringify(r));
  await page.close();
}

// 23. Where N and a rail tick went shows (the .landed pulse), also when the
//     page could not scroll there.
{
  const page = await newPage();
  const short = doc(4, i => `<p>para ${i}</p>`);
  short.marks = [{ slot: 3, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), short);
  await key(page, 'n');
  const n = await page.evaluate(() => ({ landed: document.querySelector('.blk[data-slot="3"]').classList.contains('landed'), y: scrollY,
    animation: getComputedStyle(document.querySelector('.blk[data-slot="3"]')).animationName }));
  await page.close();
  const p2 = await newPage();
  const tall = doc(40, i => `<p style="min-height:120px">para ${i}</p>`);
  tall.marks = [{ slot: 25, kind: 'inserted' }];
  await p2.evaluate(p => window.readout.apply(p), tall);
  await p2.waitForTimeout(400);
  const tick = await p2.evaluate(() => { document.querySelector('#ro-rail button').click(); return document.querySelector('.blk[data-slot="25"]').classList.contains('landed'); });
  check('N and a rail tick show where they went, on a page that cannot scroll too', n.landed && n.y === 0 && n.animation === 'landed' && tick, JSON.stringify({ n, tick }));
  await p2.close();
}

// 24. N takes a run of unread blocks (a section the agent wrote, boxes it
//     ticked) as one change: what of it is on screen is read, the next N
//     goes to the first block of it still off screen, then to the next run.
{
  const page = await newPage();
  const r = doc(120, i => `<p>line ${i}, a short paragraph</p>`);
  const run = (a, b) => Array.from({ length: b - a + 1 }, (_, k) => ({ slot: a + k, kind: 'inserted' }));
  r.marks = [...run(30, 48), ...run(90, 94)];
  await page.evaluate(p => { window.scrollTo(0, 0); window.readout.apply(p); }, r);
  await page.evaluate(() => { window.__msgs.length = 0; });
  const unread = () => page.evaluate(() => document.querySelectorAll('.blk.m-inserted:not(.m-read)').length);
  // Pressed every 450 ms, faster than the 800 ms dwell reads what is on
  // screen: the stops are N's own. A press after the last run may find its
  // blocks read by then ("nothing"): not a stop.
  const steps = [];
  for (let i = 0; i < 12 && (await unread()) > 0; i++) {
    const before = await scrollTop(page);
    await page.evaluate(() => { window.__msgs.length = 0; });
    await key(page, 'n');
    if (await page.evaluate(() => window.__msgs.some(m => m.type === 'nothing'))) break;
    await page.waitForTimeout(450);
    steps.push({ at: await page.evaluate(() => document.activeElement?.dataset?.slot), moved: (await scrollTop(page)) - before,
      wrapped: await page.evaluate(() => window.__msgs.some(m => m.type === 'wrapped')) });
  }
  await page.waitForTimeout(600);
  const left = await unread();
  const second = +steps[1]?.at;
  check('N stops once per run of unread blocks, then at what of the run is still off screen',
    left === 0 && steps.length === 3 && steps[0].at === '30' && second > 36 && second <= 48 && steps[2].at === '90'
    && steps.every(s => s.moved > 150 && !s.wrapped), JSON.stringify({ steps, left }));
  await page.close();
}

// 25. D with nothing in view to compare asks the app for a beep (as the menu
//     item, enabled whenever a document is open, does); it still opens an
//     edit's comparison after the edit was read.
{
  const page = await newPage();
  const r = doc(40, i => `<p style="min-height:60px">para ${i}</p>`);
  r.marks = [{ slot: 2, kind: 'modified', diff: 'para <del>two</del><ins>2</ins>' }];
  await page.evaluate(p => window.readout.apply(p), r);
  const readIt = await page.evaluate(() => new Promise(res => { const t0 = Date.now(); const poll = () => window.__msgs.some(m => m.type === 'read' && m.slots.includes(2)) ? res(true) : Date.now() - t0 > 3000 ? res(false) : setTimeout(poll, 50); poll(); }));
  // The app drops the read mark: the next patch carries none.
  await page.evaluate(p => window.readout.apply(p), patch(2, [{ op: 'insert', slot: 41, after: 40, kind: 'paragraph', html: '<p>added</p>' }], { marks: [{ slot: 41, kind: 'inserted' }] }));
  await page.evaluate(() => { window.scrollTo(0, 0); window.__msgs.length = 0; });
  await page.waitForTimeout(50);
  await key(page, 'd');
  const opened = await page.evaluate(() => !!document.querySelector('.blk[data-slot="2"] > .wd-panel'));
  await key(page, 'Escape');
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(50);
  await key(page, 'd');
  await page.evaluate(() => window.readout.toggleDiffInView());
  const nothing = await page.evaluate(() => window.__msgs.filter(m => m.type === 'nothing').length);
  check('D and Show What Changed with nothing in view to compare post "nothing"; D works after the edit was read',
    readIt && opened && nothing === 2, JSON.stringify({ readIt, opened, nothing }));
  await page.close();
}

// 26. A path in a code span is a link for the keyboard and VoiceOver, its
//     tooltip the file and line.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), patch(1, [{ op: 'insert', slot: 1, after: 0, kind: 'paragraph',
    html: '<p>See <code class="path-link" data-path="/repo/src/cache.ts" data-line="42">src/cache.ts:42</code> and <code class="path-link" data-path="/repo/Makefile">Makefile</code>.</p>' }], { reset: true }));
  const attrs = await page.evaluate(() => [...document.querySelectorAll('code.path-link')].map(c => ({ role: c.getAttribute('role'), tab: c.tabIndex, title: c.title })));
  await page.focus('code.path-link');
  await page.evaluate(() => { window.__msgs.length = 0; });
  await page.keyboard.press('Enter');
  await page.keyboard.press('Tab');
  await page.keyboard.press(' ');
  const opened = await page.evaluate(() => window.__msgs.filter(m => m.type === 'openPath').map(m => `${m.path}:${m.line}`));
  const links = [];
  const walk = n => { if (n.role === 'link') links.push(n.name); (n.children || []).forEach(walk); };
  walk(await page.accessibility.snapshot());
  const scrolled = await scrollTop(page);
  check('a path in a code span is a link: role, Tab, Return and Space, its file and line as the tooltip',
    JSON.stringify(attrs) === JSON.stringify([{ role: 'link', tab: 0, title: '/repo/src/cache.ts:42' }, { role: 'link', tab: 0, title: '/repo/Makefile' }])
    && JSON.stringify(opened) === JSON.stringify(['/repo/src/cache.ts:42', '/repo/Makefile:0']) && links.includes('src/cache.ts:42') && links.includes('Makefile') && scrolled === 0,
    JSON.stringify({ attrs, opened, links, scrolled }));
  await page.close();
}

// 27. Reopened mid-way in a large document (the app's resume calls
//     scrollToAnchor right after the first apply), the code on screen is
//     highlighted in the first frame that shows it, not a frame later.
{
  const page = await newPage();
  await page.evaluate(() => window.readout.warm());
  await page.waitForTimeout(1500);   // grammars preloaded, as in a warmed app window
  const ops = Array.from({ length: 600 }, (_, k) => k % 5 === 0
    ? { op: 'insert', slot: k + 1, after: k, kind: 'code', html: `<div class="code-block" data-lang="js"><pre><code>const a${k} = ${k};\nfunction f${k}() { return a${k} * 2; }</code></pre></div>` }
    : { op: 'insert', slot: k + 1, after: k, kind: 'paragraph', html: `<p>Para ${k} ${'lorem ipsum '.repeat(10)}</p>` });
  const r = await page.evaluate(ops => new Promise(res => {
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], ops });
    window.readout.scrollToAnchor({ slot: 301, offset: 0, ratio: 0 });
    requestAnimationFrame(() => {
      const vis = [...document.querySelectorAll('.code-block')].filter(c => { const b = c.getBoundingClientRect(); return b.bottom > 0 && b.top < innerHeight; });
      res({ onScreen: vis.length, states: vis.map(c => c.dataset.hl) });
    });
  }), ops);
  check('code on screen at a resumed place is highlighted in its first frame', r.onScreen > 0 && r.states.every(s => s === 'done'), JSON.stringify(r));
  await page.close();
}

// 28. The app's unread badge and dots are told of a change (showUnread)
//     only once it is not being read at once: one arriving at the end the
//     reader follows is read first (its read posted before), one off
//     screen is told at once.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(40, i => `<p style="min-height:60px">para ${i}</p>`));
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(100);
  await page.evaluate(() => { window.__msgs.length = 0; window.__t0 = performance.now(); window.__at = {}; const push = window.__msgs.push.bind(window.__msgs); window.__msgs.push = m => { window.__at[m.type] ??= performance.now() - window.__t0; return push(m); }; });
  await page.evaluate(p => window.readout.apply(p), patch(2, [{ op: 'insert', slot: 41, after: 40, kind: 'paragraph', html: '<p>the agent wrote this</p>' }], { marks: [{ slot: 41, kind: 'inserted' }] }));
  await page.waitForTimeout(1600);
  const followed = await page.evaluate(() => ({ order: window.__msgs.map(m => m.type).filter(t => t === 'read' || t === 'showUnread'), at: window.__at }));
  await page.evaluate(() => { window.scrollTo(0, 0); window.__msgs.length = 0; window.__t0 = performance.now(); window.__at = {}; });
  await page.waitForTimeout(100);
  await page.evaluate(p => window.readout.apply(p), patch(3, [{ op: 'insert', slot: 42, after: 41, kind: 'paragraph', html: '<p>more, off screen</p>' }], { marks: [{ slot: 42, kind: 'inserted' }] }));
  await page.waitForTimeout(500);
  const away = await page.evaluate(() => ({ order: window.__msgs.map(m => m.type).filter(t => t === 'read' || t === 'showUnread'), at: window.__at }));
  check('the app is told to show a change once it is not read at once; one read at the end it follows is read first',
    JSON.stringify(followed.order) === '["read","showUnread"]' && followed.at.showUnread > 700
    && JSON.stringify(away.order) === '["showUnread"]' && away.at.showUnread < 400, JSON.stringify({ followed, away }));
  await page.close();
}

// 29. A patch touches the marks of only the blocks whose mark changed (it
//     used to take every mark off and put it back, restyling them all), and
//     keeps the removal markers it had (and what was read of them).
{
  const page = await newPage();
  const r = doc(300, i => `<p>para ${i}</p>`);
  const kept = Array.from({ length: 50 }, (_, k) => ({ slot: 200 + k, kind: 'inserted' }));
  r.marks = kept;
  r.deletions = [{ id: 7, after: 250, count: 2, preview: 'gone' }];
  await page.evaluate(p => { window.scrollTo(0, 0); window.readout.apply(p); }, r);
  await page.waitForTimeout(100);
  const touched = await page.evaluate(p => new Promise(res => {
    const seen = new Set();
    const mo = new MutationObserver(ms => { for (const m of ms) if (m.target.classList?.contains('blk')) seen.add(m.target.dataset.slot); });
    mo.observe(document.getElementById('ro-doc'), { subtree: true, attributes: true, attributeFilter: ['class'] });
    const del = document.querySelector('.del-mark');
    window.readout.apply(p);
    setTimeout(() => { mo.disconnect(); res({ slots: [...seen], sameMarker: document.querySelector('.del-mark') === del }); }, 0);
  }), patch(2, [{ op: 'insert', slot: 301, after: 300, kind: 'paragraph', html: '<p>new</p>' }],
    { marks: [...kept, { slot: 301, kind: 'inserted' }], deletions: [{ id: 7, after: 250, count: 2 }] }));
  check('a patch changes the classes of only the blocks whose mark changed, and keeps its removal markers',
    JSON.stringify(touched.slots) === '["301"]' && touched.sameMarker, JSON.stringify(touched));
  await page.close();
}

// ---------------------------------------------------------------- 3.8 web performance
// In a large document (content-visibility) a style change on a block that has
// been laid out (contain-intrinsic-size, content-visibility), and offsetParent
// read after any change, make WebKit lay out every skipped block again: 1-4 s
// per patch or jump at 5 MB.

// 30. P1: an edit above the reader leaves a block that has been laid out its
//     contain-intrinsic-size (content-visibility keeps its last size), and
//     reads no offsetParent while the changes-only filter is off.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(600));
  // Block 300 on screen (laid out), then the reader 30 blocks further on.
  for (const s of [300, 330]) {
    await page.evaluate(s => window.scrollBy(0, document.querySelector(`.blk[data-slot="${s}"]`).getBoundingClientRect().top), s);
    await settledTop(page, `.blk[data-slot="${s}"]`);
  }
  const r = await page.evaluate(p => {
    const el = document.querySelector('.blk[data-slot="300"]');
    const before = el.style.containIntrinsicSize;
    const reader = document.querySelector('.blk[data-slot="330"]').getBoundingClientRect().top;
    let reads = 0;
    const d = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetParent');
    Object.defineProperty(HTMLElement.prototype, 'offsetParent', { ...d, get() { reads++; return d.get.call(this); } });
    try { window.readout.apply(p); } finally { Object.defineProperty(HTMLElement.prototype, 'offsetParent', d); }
    return { before, after: el.style.containIntrinsicSize, reads, edited: el.textContent.startsWith('edited'),
      moved: Math.round(document.querySelector('.blk[data-slot="330"]').getBoundingClientRect().top - reader) };
  }, patch(2, [{ op: 'replace', slot: 300, kind: 'paragraph', change: 'content', html: `<p>edited ${'and much longer now '.repeat(40)}</p>` }],
    { marks: [{ slot: 300, kind: 'modified' }] }));
  check('an edit above the reader keeps a laid-out block\'s intrinsic size, reads no offsetParent, keeps the place',
    r.before && r.before === r.after && r.reads === 0 && r.edited && Math.abs(r.moved) <= 1, JSON.stringify(r));
  // With the changes-only filter on, hidden blocks are still told apart.
  await page.evaluate(() => window.readout.setChangesOnly(true));
  const shown = await page.evaluate(() => [...document.querySelectorAll('#ro-doc > .blk')].filter(e => !e.hidden).map(e => +e.dataset.slot));
  await page.evaluate(() => window.readout.setChangesOnly(false));
  check('the changes-only filter still shows only the change', JSON.stringify(shown) === '[300]', JSON.stringify(shown));
  await page.close();
}

// 31. P2: an outline jump and N in a large document set content-visibility
//     on no block (an outline jump forced 40 blocks laid out, and back a frame
//     later), and still land where they aim.
{
  const page = await newPage({ appearance: { topInset: 52 } });
  const big = doc(600, i => i % 50 === 1 ? `<h2 id="s${i}">Section ${i}</h2>` : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(1 + (i * 7) % 11)}</p>`,
    i => i % 50 === 1 ? 'heading' : 'paragraph');
  big.ops.forEach(o => { if (o.kind === 'heading') o.anchor = `s${o.slot}`; });
  big.marks = [{ slot: 560, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), big);
  await page.waitForTimeout(300);
  await watchCv(page);
  await page.evaluate(() => window.readout.scrollToSlot(451));
  await page.waitForTimeout(1200);
  const toc = { writes: await cvWrites(page), top: await page.evaluate(() => Math.round(document.querySelector('.blk[data-slot="451"]').getBoundingClientRect().top)) };
  await watchCv(page);
  await key(page, 'n');
  await page.waitForTimeout(1200);
  const n = { writes: await cvWrites(page), ...await page.evaluate(() => ({ top: Math.round(document.querySelector('.blk[data-slot="560"]').getBoundingClientRect().top), want: Math.round(innerHeight / 3) })) };
  check('an outline jump and N in a large document force no block\'s layout and land where they aim',
    toc.writes === 0 && Math.abs(toc.top - 68) <= 2 && n.writes === 0 && Math.abs(n.top - n.want) <= 30, JSON.stringify({ toc, n }));
  await page.close();
}

// 32. P3: following the end is sticky. The page moving under the reader (a
//     block near the end laid out taller) leaves them short of the end: the
//     next patch takes them there again. The reader scrolling (the wheel, the
//     scrollbar: a scroll the page did not make) stops it.
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(60));
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(300);
  let slot = 60;
  const append = () => page.evaluate(s => window.readout.apply({ version: s, reset: false, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
    ops: [{ op: 'insert', slot: s, after: s - 1, kind: 'paragraph', html: `<p>streamed ${s}</p>` }] }), ++slot);
  const grow = () => page.evaluate(s => { const d = document.createElement('div'); d.style.height = '300px'; document.querySelector(`.blk[data-slot="${s}"]`).appendChild(d); }, slot - 1);
  const r = {};
  await append();
  r.following = await remaining(page);
  await grow();
  await page.waitForTimeout(300);   // settled: the reader is short of the end
  r.slipped = await remaining(page);
  await append();
  r.caught = await remaining(page);
  // The wheel.
  await page.mouse.move(450, 350);
  await page.mouse.wheel(0, -600);
  await page.waitForTimeout(400);
  let y = await scrollTop(page);
  await append();
  r.wheelStays = (await scrollTop(page)) - y;
  // Back at the end it follows again, through a slip again.
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(300);
  await grow();
  await page.waitForTimeout(300);
  await append();
  r.again = await remaining(page);
  // The scrollbar.
  await page.evaluate(() => window.scrollBy(0, -500));
  await page.waitForTimeout(400);
  y = await scrollTop(page);
  await append();
  r.barStays = (await scrollTop(page)) - y;
  check('following the end survives the page moving under the reader, and stops when they scroll',
    r.following <= 1 && r.slipped >= 250 && r.caught <= 1 && r.wheelStays === 0 && r.again <= 1 && r.barStays === 0, JSON.stringify(r));
  await page.close();
}

// 33. P6: scrolling up through a large document's unseen blocks (shown at
//     their estimated height until WebKit lays them out, a frame after they
//     came into view): the text on screen stays where the scroll put it once
//     they are laid out (the block kept in place is the first on screen that
//     was laid out before; those before it grow upward).
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(600, i => `<p style="min-height: ${60 + (i * 37) % 240}px">para ${i}</p>`));
  for (let k = 0; k < 2; k++) {
    await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
    await page.waitForTimeout(400);
  }
  const moved = await page.evaluate(() => new Promise(resolve => {
    const out = [];
    let el = null, top = 0;
    const after = () => {
      if (el) out.push(Math.round(el.getBoundingClientRect().top - top - 400));
      if (out.length >= 12) return resolve(out);
      el = document.elementFromPoint(450, 350).closest('.blk');
      top = el.getBoundingClientRect().top;
      // Measured once the blocks the step brought on screen are laid out and their change made up for.
      const settled = n => (n ? requestAnimationFrame(() => settled(n - 1)) : setTimeout(after, 0));
      requestAnimationFrame(() => { window.scrollBy(0, -400); settled(4); });
    };
    after();
  }));
  const sum = moved.reduce((a, b) => a + Math.abs(b), 0);
  check('scrolling up through unseen blocks of a large document keeps the text in place', sum <= 60, JSON.stringify({ sum, moved }));
  await page.close();
}

// 34. P10: blocks a following reader's patches lay out at once at the end
//     go back to content-visibility many at a time, not each in a frame of
//     its own two frames later (each such frame laid out the whole document
//     again: 5 MB, ~0.1 s per append).
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(400));
  for (let k = 0; k < 2; k++) {
    await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
    await page.waitForTimeout(300);
  }
  const r = await page.evaluate(() => new Promise(resolve => {
    // Which frames hand blocks back: a counter the frames advance.
    let frame = 0;
    const tick = () => { frame++; requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    const clears = new Set();
    let sets = 0;
    const mo = new MutationObserver(ms => {
      for (const m of ms) {
        const was = /content-visibility/.test(m.oldValue || ''), is = /content-visibility/.test(m.target.getAttribute('style') || '');
        if (was && !is) clears.add(frame); else if (!was && is) sets++;
      }
    });
    mo.observe(document.getElementById('ro-doc'), { subtree: true, attributes: true, attributeFilter: ['style'], attributeOldValue: true });
    let s = 400, left = [];
    const add = () => {
      s++;
      window.readout.apply({ version: s, reset: false, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
        ops: [{ op: 'insert', slot: s, after: s - 1, kind: 'paragraph', html: `<p>streamed ${s} ${'more agent output '.repeat(20)}</p>` }] });
      const se = document.scrollingElement;
      left.push(Math.round(se.scrollHeight - se.scrollTop - innerHeight));
      if (s < 440) requestAnimationFrame(() => requestAnimationFrame(add));
      else setTimeout(() => { mo.disconnect(); resolve({ sets, clearFrames: clears.size, maxLeft: Math.max(...left) }); }, 300);
    };
    add();
  }));
  check('a following reader\'s forced blocks go back many at a time, not one frame each',
    r.sets === 40 && r.clearFrames >= 1 && r.clearFrames <= 2 && r.maxLeft <= 1, JSON.stringify(r));
  await page.close();
}

// 35. A block at the top of the window that changes size later (a <details>
//     the reader opens, an image loading) grows down from where it is, in a
//     small document and in a large one: only blocks laid out for the first
//     time (at their estimate until then) grow upward (33).
for (const n of [60, 400]) {
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(n, i => i === 30
    ? `<details><summary>More</summary>${'<p>folded text that the reader opens to read. '.repeat(1) + 'x</p>'.repeat(1)}${'<p>folded line</p>'.repeat(60)}</details>`
    : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`));
  const tops = [];
  for (const at of [2, 200]) {
    await page.evaluate(at => { window.scrollBy(0, document.querySelector('.blk[data-slot="30"]').getBoundingClientRect().top - at); }, at);
    await settledTop(page, '.blk[data-slot="30"] summary');
    const before = await page.evaluate(() => Math.round(document.querySelector('.blk[data-slot="30"] summary').getBoundingClientRect().top));
    await page.evaluate(() => { document.querySelector('.blk[data-slot="30"] details').open = true; });
    const after = await settledTop(page, '.blk[data-slot="30"] summary');
    await page.evaluate(() => { document.querySelector('.blk[data-slot="30"] details').open = false; });
    await settledTop(page, '.blk[data-slot="30"] summary');
    tops.push({ at, before, after });
  }
  check(`a <details> opened at the top of the window stays where it is (${n} blocks)`, tops.every(t => Math.abs(t.after - t.before) <= 1), JSON.stringify(tops));
  await page.close();
}

// 36. P1: a block never laid out (far below, skipped) that an edit makes far
//     larger (a paragraph become a 2,000-line code block) gets the new
//     content's estimate, so the page's height follows it; one laid out keeps
//     its intrinsic size (30), and small edits keep theirs (perf.test).
{
  const page = await newPage();
  await page.evaluate(p => window.readout.apply(p), doc(600, i => `<p>para ${i}</p>`));
  await page.waitForTimeout(300);
  const big = `<div class="code-block" data-lang="text"><pre><code>${Array.from({ length: 2000 }, (_, i) => `line ${i}`).join('\n')}</code></pre></div>`;
  const r = await page.evaluate(p => {
    const el = document.querySelector('.blk[data-slot="500"]');
    const h0 = document.scrollingElement.scrollHeight, before = el.style.containIntrinsicSize;
    window.readout.apply(p);
    return { before, after: el.style.containIntrinsicSize, grew: document.scrollingElement.scrollHeight - h0 };
  }, patch(2, [{ op: 'replace', slot: 500, kind: 'code', change: 'content', html: big }]));
  check('an edit to a block never laid out gives it the new estimate', r.before !== r.after && r.grew > 30000, JSON.stringify(r));
  await page.close();
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
