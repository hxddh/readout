// Reader interaction tests: keys, jumps, the TOC, popups, read detection,
// Quick Look, heading links and tables. Each section opens its own page.
// Runs in WebKit by default (the production engine) via Playwright.
// Usage: BROWSER=webkit node test/interact.test.mjs  (requires web/build.mjs to have run)
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';

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
  page.on('pageerror', e => errors.push(`page ${n}: ${e}`));
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

// 1. A table that scrolled in a narrow window fits again once the window, the
//    column or the type size leaves it room.
{
  const page = await newPage({ width: 520, height: 800 });
  const long = 'A full sentence of reasoning about the option, as agents write in comparison tables. '.repeat(2);
  const html = `<div class="table-wrap"><table><thead><tr><th>Option name</th><th>Rationale</th><th>Monthly cost</th><th>Risk level</th><th>Owner team</th><th>Status</th></tr></thead><tbody>
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

  // The column and the type size (no window resize): a table of long words
  // that fits the wide column, or smaller type, but not the narrow column.
  const p2 = await newPage({ width: 1300, height: 800 });
  const words = ['Implementation', 'Responsibility', 'Configuration', 'Documentation', 'Compatibility', 'Infrastructure', 'Observability'];
  const row = words.map(w => `<td>${w}</td>`).join('');
  await p2.evaluate(p => window.readout.apply(p), patch(1, [{ op: 'insert', slot: 1, after: 0, kind: 'table',
    html: `<div class="table-wrap"><table><thead><tr>${words.map(w => `<th>${w}</th>`).join('')}</tr></thead><tbody><tr>${row}</tr></tbody></table></div>` }], { reset: true }));
  await p2.waitForTimeout(300);
  const state = async () => (await p2.evaluate(() => document.querySelector('.table-wrap').classList.contains('scrolls')));
  const steps = { narrow16: await state() };
  await p2.evaluate(() => window.readout.setAppearance({ fontSize: 12 }));
  steps.narrow12 = await state();
  await p2.evaluate(() => window.readout.setAppearance({ fontSize: 16 }));
  steps.narrow16again = await state();
  await p2.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  steps.wide16 = await state();
  check('a table that scrolled fits again when the column widens or the type gets smaller',
    steps.narrow16 && !steps.narrow12 && steps.narrow16again && !steps.wide16, JSON.stringify(steps));
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
{
  const page = await newPage();
  await page.evaluate(() => { window.__focused = false; document.hasFocus = () => window.__focused; });
  const r = doc(5, i => `<p>para ${i}</p>`);
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

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
