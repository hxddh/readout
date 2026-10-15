// JS unit tests for the reader patch engine (insert order, anchor stability,
// follow semantics). Runs in WebKit by default (the production engine) via
// Playwright; BROWSER selects the engine (webkit | chromium | firefox).
// Usage: BROWSER=webkit node test/apply.test.mjs  (requires web/build.mjs to have run)
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors, benign } from './pageerrors.mjs';

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
if (!engines[engineName]) {
  console.error(`Unknown BROWSER=${process.env.BROWSER}; want webkit | chromium | firefox`);
  process.exit(2);
}
console.log(`engine: ${engineName}`);
// CHROME_PATH overrides the browser binary (local dev only; CI uses stock Playwright browsers).
const launchOpts = process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] } : {};
const browser = await engines[engineName].launch(launchOpts);
const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
const errors = [];
collectPageErrors(page, errors);
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}

// Waits until the page has stopped moving: the reading position is the same
// two frames running (resize compensations, lazy work and the observers'
// notifications have run), instead of a fixed time a loaded machine overruns.
async function settled() {
  await until(() => new Promise(resolve => {
    const at = () => JSON.stringify([document.scrollingElement.scrollTop, document.scrollingElement.scrollHeight]);
    const a = at();
    requestAnimationFrame(() => requestAnimationFrame(() => resolve(at() === a)));
  }));
}

// Polls `fn` in the page (with `arg`) until it returns true, or `ms` pass.
// (page.waitForFunction evaluates a string, which the page's CSP refuses.)
async function until(fn, arg, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await page.evaluate(fn, arg)) return true;
    await page.waitForTimeout(25);
  }
  return false;
}

// Build a reset patch with N paragraph blocks.
function resetPatch(n, prefix = 'para') {
  const ops = [];
  let prev = 0;
  for (let i = 1; i <= n; i++) {
    ops.push({ op: 'insert', slot: i, after: prev, html: `<p>${prefix} ${i}</p>`, kind: 'paragraph', cjk: false });
    prev = i;
  }
  return { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
}

// 1. Insert order: three blocks prepended at the top must keep document order.
await page.evaluate(p => window.readout.apply(p), resetPatch(5));
await page.evaluate(() => window.scrollTo(0, 0));
await page.evaluate(p => window.readout.apply({
  version: 2, reset: false, rewrite: false,
  ops: [
    { op: 'insert', slot: 101, after: 0, html: '<p>new A</p>', kind: 'paragraph' },
    { op: 'insert', slot: 102, after: 101, html: '<p>new B</p>', kind: 'paragraph' },
    { op: 'insert', slot: 103, after: 102, html: '<p>new C</p>', kind: 'paragraph' },
  ],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const order = await page.evaluate(() => [...document.querySelectorAll('.blk')].map(e => e.textContent.trim()));
check('prepend keeps order', JSON.stringify(order.slice(0, 3)) === JSON.stringify(['new A', 'new B', 'new C']), JSON.stringify(order.slice(0, 5)));

// 2. Anchor stability: editing a block above the viewport must not move the top block.
await page.evaluate(p => window.readout.apply(p), resetPatch(40, 'stable'));
const before = await page.evaluate(() => {
  const blocks = [...document.querySelectorAll('.blk')];
  const target = blocks[20];
  window.scrollBy(0, target.getBoundingClientRect().top - 30);
  return { slot: +target.dataset.slot, top: target.getBoundingClientRect().top };
});
await page.evaluate(() => window.readout.apply({
  version: 4, reset: false, rewrite: false,
  ops: [{ op: 'replace', slot: 2, html: '<p>edited far above with much longer content that changes height a lot. '.repeat(5) + '</p>', kind: 'paragraph', change: 'content' }],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const shift = await page.evaluate(slot => document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().top, before.slot);
check('anchor stable after edit above', Math.abs(shift - before.top) < 2, `shift=${shift - before.top}`);

// 3. Follow semantics: a top insertion must NOT yank a bottom-dwelling reader.
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForTimeout(200);
const bottomBefore = await page.evaluate(() => document.scrollingElement.scrollTop);
await page.evaluate(() => window.readout.apply({
  version: 5, reset: false, rewrite: false,
  ops: [{ op: 'insert', slot: 201, after: 0, html: '<p>inserted at top</p>', kind: 'paragraph' }],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const bottomAfter = await page.evaluate(() => document.scrollingElement.scrollTop);
check('top insert does not yank bottom reader', Math.abs(bottomAfter - bottomBefore) < 120, `delta=${bottomAfter - bottomBefore}`);

// 4. Follow still works: an append at the end follows the bottom reader.
// The appended block is tall (taller than the page's bottom padding), so the
// reader only stays at the end if the page follows; and following goes on.
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForTimeout(200);
const follows = [];
for (const [slot, after] of [[202, 40], [203, 202]]) {
  await page.evaluate(([slot, after]) => window.readout.apply({
    version: 6, reset: false, rewrite: false,
    ops: [{ op: 'insert', slot, after, html: `<p>${'appended at the end of the document '.repeat(60)}</p>`, kind: 'paragraph' }],
    marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
  }), [slot, after]);
  follows.push(await page.evaluate(slot => {
    const se = document.scrollingElement;
    return { gap: Math.round(se.scrollHeight - (se.scrollTop + window.innerHeight)),
      height: Math.round(document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().height) };
  }, slot));
}
check('append at end follows (tall block, twice)', follows.every(f => f.gap < 48 && f.height >= 600 && f.height <= 900), JSON.stringify(follows));

// 5. Fragment scroll. (The heading is not the first block: at the top of the
// page the first block rests 12 px under the toolbar, above the 16 px gap;
// the heading text, not its block's top margin, lands 16 px down.)
await page.evaluate(() => window.scrollTo(0, 0));
await page.evaluate(p => window.readout.apply({
  version: 7, reset: true, rewrite: false,
  ops: [
    { op: 'insert', slot: 300, after: 0, html: '<p>before the target</p>', kind: 'paragraph' },
    { op: 'insert', slot: 301, after: 300, html: '<h2 id="target-section">Target</h2>', kind: 'heading', anchor: 'target-section' },
    ...Array.from({ length: 30 }, (_, i) => ({ op: 'insert', slot: 302 + i, after: 301 + i, html: `<p>filler ${i}</p>`, kind: 'paragraph' })),
  ],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
await page.evaluate(() => window.readout.scrollToFragment({ fragment: 'target-section' }));
const fragTop = await page.evaluate(() => document.getElementById('target-section').getBoundingClientRect().top);
check('fragment scroll lands on heading', Math.abs(fragTop - 16) < 4, `top=${fragTop}`);

// 6. Changes-only filter: read blocks hide, headings stay, marks still navigate.
await page.evaluate(p => window.readout.apply({
  version: 8, reset: true, rewrite: false,
  ops: [
    { op: 'insert', slot: 401, after: 0, html: '<h2 id="s-a">Section A</h2>', kind: 'heading', anchor: 's-a' },
    { op: 'insert', slot: 402, after: 401, html: '<p>read body</p>', kind: 'paragraph' },
    { op: 'insert', slot: 403, after: 402, html: '<p>new body</p>', kind: 'paragraph' },
  ],
  marks: [{ slot: 403, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const linkBtn = await page.evaluate(() => !!document.querySelector('.k-heading .h-link'));
check('heading has section link button', linkBtn);
await page.evaluate(() => window.readout.setChangesOnly(true));
const filtered = await page.evaluate(() => ({
  readHidden: document.querySelector('.blk[data-slot="402"]').hidden,
  headVisible: !document.querySelector('.blk[data-slot="401"]').hidden,
  newVisible: !document.querySelector('.blk[data-slot="403"]').hidden,
}));
check('changes-only hides read blocks, keeps heading + new', filtered.readHidden && filtered.headVisible && filtered.newVisible, JSON.stringify(filtered));
// Clicking the heading link posts a copyLink message with the anchor.
await page.evaluate(() => { window.__msgs.length = 0; });
await page.evaluate(() => document.querySelector('.k-heading .h-link').click());
const copyMsg = await page.evaluate(() => window.__msgs.find(m => m.type === 'copyLink'));
check('heading link posts copyLink', copyMsg && copyMsg.anchor === 's-a', JSON.stringify(copyMsg));
// Silent re-render must not drop the unread mark or the filter.
await page.evaluate(() => window.readout.apply({
  version: 9, reset: false, rewrite: false,
  ops: [{ op: 'replace', slot: 403, html: '<p>new body</p>', kind: 'paragraph', change: 'silent' }],
  marks: [{ slot: 403, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const afterSilent = await page.evaluate(() => ({
  marked: document.querySelector('.blk[data-slot="403"]').classList.contains('m-inserted'),
  readHidden: document.querySelector('.blk[data-slot="402"]').hidden,
}));
check('silent re-render keeps mark + filter', afterSilent.marked && afterSilent.readHidden, JSON.stringify(afterSilent));
await page.evaluate(() => window.readout.setChangesOnly(false));
const restored = await page.evaluate(() => !document.querySelector('.blk[data-slot="402"]').hidden);
check('leaving changes-only restores blocks', restored);

// 7. Heading ids never collide with reader chrome ids.
await page.evaluate(() => window.scrollTo(0, 0));
await page.evaluate(p => window.readout.apply(p), {
  version: 10, reset: true, rewrite: false,
  ops: [
    { op: 'insert', slot: 501, after: 0, html: '<h2 id="notice">Notice</h2>', kind: 'heading', anchor: 'notice' },
    { op: 'insert', slot: 502, after: 501, html: '<h2 id="doc">Doc</h2>', kind: 'heading', anchor: 'doc' },
    { op: 'insert', slot: 503, after: 502, html: '<h2 id="rail">Rail</h2>', kind: 'heading', anchor: 'rail' },
    { op: 'insert', slot: 504, after: 503, html: '<h2 id="empty">Empty</h2>', kind: 'heading', anchor: 'empty' },
    { op: 'insert', slot: 505, after: 504, html: '<h2 id="caughtup">Caughtup</h2>', kind: 'heading', anchor: 'caughtup' },
    { op: 'insert', slot: 506, after: 505, html: '<p>body paragraph for alignment reference</p>', kind: 'paragraph' },
    // Filler so the page scrolls: the fragment test starts at the bottom and
    // only a real navigation brings the target back to the top (Codex P3).
    ...Array.from({ length: 30 }, (_, i) => ({
      op: 'insert', slot: 510 + i, after: 509 + i,
      html: `<p style="min-height:170px">filler ${i} to make the page scrollable</p>`, kind: 'paragraph',
    })),
  ],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
});
const idCheck = await page.evaluate(() => {
  const ids = [...document.querySelectorAll('[id]')].map(e => e.id);
  const dupes = ids.filter((id, i) => ids.indexOf(id) !== i);
  const heads = [...document.querySelectorAll('.k-heading')];
  const para = document.querySelector('.blk[data-slot="506"]');
  // The text, not the block: a block extends over the side gutters.
  const paraText = para ? (para.querySelector('p') || para.firstElementChild) : null;
  const paraLeft = paraText ? paraText.getBoundingClientRect().left : -1;
  return {
    dupes,
    heads: heads.map(h => {
      const inner = h.querySelector('h1,h2,h3,h4,h5,h6') || h;
      const cs = getComputedStyle(inner);
      const r = inner.getBoundingClientRect();
      // textAlign/paddingTop: the old #empty rule changed these without
      // touching position/width/left, so assert them explicitly (Codex P2).
      return { id: inner.id, position: cs.position, width: r.width, left: r.left,
               align: cs.textAlign, padTop: cs.paddingTop };
    }),
    paraLeft,
  };
});
check('no duplicate ids with clashing headings', idCheck.dupes.length === 0, JSON.stringify(idCheck.dupes));
// Large documents use content-visibility, whose containment clips each block:
// what sits in the gutter (change marks, heading links) must be inside it,
// and the layout must not change with the mode.
const contained = await page.evaluate(() => {
  const doc = document.getElementById('ro-doc');
  const b = document.querySelector('.blk[data-slot="506"]');
  const h = document.querySelector('.k-heading');
  const before = parseFloat(getComputedStyle(b, '::before').left);
  const link = h.querySelector('.h-link');
  const linkLeft = link ? link.getBoundingClientRect().left - h.getBoundingClientRect().left : 0;
  const heights = () => [...doc.querySelectorAll('.blk')].slice(0, 40).map(e => Math.round(e.getBoundingClientRect().height));
  const withCV = heights();
  doc.classList.remove('cv');
  const without = heights();
  doc.classList.add('cv');
  return { cv: doc.classList.contains('cv'), before, linkLeft, same: JSON.stringify(withCV) === JSON.stringify(without) };
});
check('large document uses content-visibility', contained.cv);
check('change mark sits inside its block', contained.before >= 0, `left=${contained.before}`);
check('heading link sits inside its block', contained.linkLeft >= 0, `left=${contained.linkLeft}`);
check('blocks lay out the same with and without content-visibility', contained.same);
for (const h of idCheck.heads) {
  check(`heading ${h.id} is static-positioned`, h.position === 'static', `${h.id}: ${h.position}`);
  check(`heading ${h.id} keeps full width`, h.width > 100, `${h.id}: ${h.width}`);
  check(`heading ${h.id} aligns with body text`, Math.abs(h.left - idCheck.paraLeft) <= 2, `${h.id}: ${h.left} vs ${idCheck.paraLeft}`);
  check(`heading ${h.id} is not center-aligned`, h.align !== 'center', `${h.id}: text-align=${h.align}`);
  check(`heading ${h.id} has no empty-state padding`, parseFloat(h.padTop) < 20, `${h.id}: padding-top=${h.padTop}`);
}
// Start scrolled to the bottom: with the page at scroll 0 the target already
// sits near the top, so even a broken lookup that scrolls nowhere would pass
// (Codex P3). From the bottom, only a real navigation lands it at the top.
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForTimeout(200);
await page.evaluate(() => window.readout.scrollToFragment({ fragment: 'notice' }));
const noticeTop = await page.evaluate(() => {
  const h = [...document.querySelectorAll('.k-heading')].find(e => e.querySelector('h2')?.textContent === 'Notice');
  return h ? h.getBoundingClientRect().top : -999;
});
check('scrollToFragment lands on heading, not chrome', noticeTop >= 0 && noticeTop <= 40, `top=${noticeTop}`);
// In-document links go through the same fragment resolver: same target, and a
// malformed escape is ignored instead of throwing.
await page.evaluate(() => {
  const host = document.querySelector('#ro-doc .blk');
  for (const href of ['#Notice', '#%E0%A4%A']) {
    const a = document.createElement('a');
    a.href = href;
    a.textContent = href;
    a.className = 'frag-test';
    host.appendChild(a);
  }
});
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForTimeout(200);
await page.evaluate(() => document.querySelector('a.frag-test[href="#Notice"]').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })));
const linkTop = await page.evaluate(() => {
  const h = [...document.querySelectorAll('.k-heading')].find(e => e.querySelector('h2')?.textContent === 'Notice');
  return h ? h.getBoundingClientRect().top : -999;
});
check('in-document #link lands on the same heading', linkTop >= -2 && linkTop <= 40, `top=${linkTop}`);
// Clicked in the same frame as a scroll: in a large document the target's block
// is still skipped by content-visibility, where WebKit's scrollIntoView scrolled
// nowhere (about one click in five). Every click must land.
{
  const missed = [];
  for (let i = 0; i < 12; i++) {
    await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
    const top = await page.evaluate(() => {
      document.querySelector('a.frag-test[href="#Notice"]').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      const h = [...document.querySelectorAll('.k-heading')].find(e => e.querySelector('h2')?.textContent === 'Notice');
      return h.getBoundingClientRect().top;
    });
    if (!(top >= -2 && top <= 40)) missed.push(top);
    await page.waitForTimeout(i % 3 * 40);
  }
  check('in-document #link lands even right after a scroll', missed.length === 0, JSON.stringify(missed));
}
const beforeBad = await page.evaluate(() => document.scrollingElement.scrollTop);
await page.evaluate(() => document.querySelector('a.frag-test[href="#%E0%A4%A"]').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })));
const afterBad = await page.evaluate(() => document.scrollingElement.scrollTop);
check('malformed #link is ignored without moving', afterBad === beforeBad, `${beforeBad} -> ${afterBad}`);
await page.evaluate(() => document.querySelectorAll('a.frag-test').forEach(a => a.remove()));

// 8. Changes-only anchor stability: hidden blocks must not break capture/restore.
await page.evaluate(() => window.scrollTo(0, 0));
{
  const ops = [];
  // Tall blocks: with the filter hiding 9 of 10 blocks, the survivors must
  // still fill more than a viewport so a middle block can reach the top.
  for (let i = 1; i <= 120; i++) ops.push({ op: 'insert', slot: i, after: i - 1, html: `<p style="min-height:170px">body ${i} with enough text to take vertical space in the viewport</p>`, kind: 'paragraph' });
  const marks = [];
  for (let s = 5; s <= 120; s += 10) marks.push({ slot: s, kind: 'inserted' });
  await page.evaluate(p => window.readout.apply(p), { version: 20, reset: true, rewrite: false, ops, marks, deletions: [], toc: [], tasks: { done: 0, total: 0 } });
}
await page.evaluate(() => window.readout.setChangesOnly(true));
// Put slot 65 at the top of the viewport; hidden blocks above must not confuse capture.
await page.evaluate(() => {
  const el = document.querySelector('.blk[data-slot="65"]');
  window.scrollBy(0, el.getBoundingClientRect().top);
});
const captured = await page.evaluate(() => window.readout.captureAnchor());
// Failed once in 58 CI runs (null), never locally: say where the page was if it happens again.
const captureState = await page.evaluate(() => ({ scrollY, scrollHeight: document.scrollingElement.scrollHeight,
  cv: document.getElementById('ro-doc').classList.contains('cv'),
  shown: [...document.querySelectorAll('#ro-doc > .blk')].filter(e => !e.hidden && e.offsetParent).length,
  top65: document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top }));
check('changes-only capture sees slot 65', captured && captured.slot === 65, JSON.stringify({ captured, ...captureState }));
// Insert a long unread paragraph after slot 20: slot 65 must not move.
// Marks are a full snapshot (DocumentSession.payload sends currentMarks), so
// the patch keeps every existing mark alongside the new one — a patch that
// dropped them would hide 65 itself and the assertion would prove nothing.
const top65Before = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
await page.evaluate((extra) => window.readout.apply({
  version: 21, reset: false, rewrite: false,
  ops: [{ op: 'insert', slot: 1001, after: 20, html: `<p>${'inserted long paragraph. '.repeat(30)}</p>`, kind: 'paragraph' }],
  marks: [...extra, { slot: 1001, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}), Array.from({ length: 12 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' })));
const top65After = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
check('slot 65 does not jump after patch above', Math.abs(top65After - top65Before) < 2, `shift=${top65After - top65Before}`);

// 9. Anchor block hidden by the filter: restore falls back to the nearest
// visible block. Slot 65 sits at the viewport top; a patch that drops its
// mark hides it, so restore must land on 55 (nearest visible before it).
// The patch keeps every other mark (full-snapshot semantics): only 65's mark
// is dropped, so 55 stays visible and the fallback has a real target.
await page.evaluate(() => window.readout.setChangesOnly(false));
await page.evaluate(() => {
  const el = document.querySelector('.blk[data-slot="65"]');
  window.scrollBy(0, el.getBoundingClientRect().top);
});
await page.evaluate(() => window.readout.setChangesOnly(true));
await page.evaluate((extra) => window.readout.apply({
  version: 22, reset: false, rewrite: false, ops: [],
  marks: [...extra, { slot: 1001, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}), Array.from({ length: 12 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' })).filter(m => m.slot !== 65));
const fallback = await page.evaluate(() => ({
  top55: document.querySelector('.blk[data-slot="55"]').getBoundingClientRect().top,
  hidden65: document.querySelector('.blk[data-slot="65"]').hidden,
}));
// Restore must land on 55 (nearest visible before the hidden anchor 65);
// captureAnchor itself still reports the first block below the viewport top.
check('hidden anchor falls back to previous visible block',
  fallback.hidden65 && Math.abs(fallback.top55) < 2, JSON.stringify(fallback));

// 10. Toggling the filter itself keeps position (the anchor block keeps its
// mark, so it stays visible under the filter; hiding it is section 9's case).
// Restore the full mark set: with only two visible blocks left, the document
// is shorter than the viewport and no scroll position can survive a toggle.
await page.evaluate(() => window.readout.setChangesOnly(false));
await page.evaluate((extra) => window.readout.apply({
  version: 23, reset: false, rewrite: false, ops: [],
  marks: [...extra, { slot: 1001, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}), Array.from({ length: 12 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' })));
await page.evaluate(() => {
  const el = document.querySelector('.blk[data-slot="65"]');
  window.scrollBy(0, el.getBoundingClientRect().top);
});
const vis65Before = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
await page.evaluate(() => window.readout.setChangesOnly(true));
await page.evaluate(() => window.readout.setChangesOnly(false));
const vis65After = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
check('filter toggle preserves position', Math.abs(vis65After - vis65Before) < 2, `shift=${vis65After - vis65Before}`);

// 11. Read blocks vanish only on the next patch (or re-toggle), never mid-read.
// Give slot 41 an unread mark under the filter: it must stay visible across
// a patch that keeps its mark, and hide once a patch drops the mark.
await page.evaluate(() => window.readout.setChangesOnly(false));
await page.evaluate(() => window.readout.apply({
  version: 24, reset: false, rewrite: false, ops: [],
  marks: [{ slot: 41, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
await page.evaluate(() => window.readout.setChangesOnly(true));
const keptVisible = await page.evaluate(() => {
  window.readout.apply({ version: 25, reset: false, rewrite: false, ops: [], marks: [{ slot: 41, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  return !document.querySelector('.blk[data-slot="41"]').hidden;
});
check('marked block survives a patch that keeps its mark', keptVisible);
const hiddenNext = await page.evaluate(() => {
  window.readout.apply({ version: 26, reset: false, rewrite: false, ops: [], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  return document.querySelector('.blk[data-slot="41"]').hidden;
});
check('block hides once a later patch drops its mark', hiddenNext);

// 12. Rail tick aria-labels come from the localized strings template.
// Tall blocks so the rail renders (it hides on short documents); the
// changes-only filter must be off, or the document is too short to scroll.
await page.evaluate(() => window.readout.setChangesOnly(false));
await page.evaluate(p => window.readout.apply(p), {
  version: 30, reset: true, rewrite: false,
  ops: Array.from({ length: 30 }, (_, i) => ({
    op: 'insert', slot: 2000 + i, after: i === 0 ? 0 : 2000 + i - 1,
    html: `<p style="min-height:170px">rail label probe ${i} with enough text to fill vertical space</p>`, kind: 'paragraph',
  })),
  marks: [{ slot: 2000, kind: 'inserted' }, { slot: 2005, kind: 'modified' }],
  deletions: [], toc: [], tasks: { done: 0, total: 0 },
});
await page.evaluate(() => window.readout.setAppearance({ strings: {
  railChange: '未读变更 %d / %d：%@', railAdded: '新增', railEdited: '修改', railRemoved: '删除',
} }));
// The rail redraws at most every 250 ms, then in a frame: wait for the
// labels rather than a fixed time a loaded machine can overrun.
const wantLabels = ['未读变更 1 / 2：新增', '未读变更 2 / 2：修改'];
await until(w => JSON.stringify([...document.querySelectorAll('#ro-rail button')].map(b => b.getAttribute('aria-label'))) === JSON.stringify(w), wantLabels);
const railLabels = await page.evaluate(() => [...document.querySelectorAll('#ro-rail button')].map(b => b.getAttribute('aria-label')));
check('rail labels use the localized template',
  JSON.stringify(railLabels) === JSON.stringify(wantLabels), JSON.stringify(railLabels));

// The first highlight with a grammar pays for compiling its patterns, and
// Shiki's 500 ms per-line guard may cut it short. If that cold highlight was
// slow it is redone once; highlights with a warm grammar never are.
{
  const r = await page.evaluate(async () => {
    // Every performance.now() reading jumps 300 ms: every highlight looks slow.
    const real = performance.now.bind(performance);
    let skew = 0;
    performance.now = () => (skew += 300) + real();
    const pres = new Map();
    const watch = slot => {
      const cb = document.querySelector(`.blk[data-slot="${slot}"] .code-block`);
      pres.set(slot, 0);
      new MutationObserver(m => pres.set(slot, pres.get(slot) + m.filter(x => [...x.addedNodes].some(n => n.tagName === 'PRE')).length))
        .observe(cb, { childList: true });
      return cb;
    };
    const block = (slot, after) => ({ op: 'insert', slot, after, kind: 'code',
      html: '<div class="code-block" data-lang="ruby"><pre><code># note\nx = 1</code></pre></div>' });
    // Ruby is not preloaded, so this block is the grammar's first, cold, highlight.
    window.readout.apply({ version: 90, reset: true, rewrite: false, ops: [block(901, 0)], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
    const cold = watch(901);
    const states = [];
    for (let i = 0; i < 200 && cold.dataset.hl !== 'done'; i++) { states.push(cold.dataset.hl); await new Promise(r => setTimeout(r, 25)); }
    // A second Ruby block: the grammar is warm now.
    window.readout.apply({ version: 91, reset: false, rewrite: false, ops: [block(902, 901)], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
    const warm = watch(902);
    const warmFirst = warm.dataset.hl;
    await new Promise(r => setTimeout(r, 300));
    performance.now = real;
    return { sawRecheck: states.includes('recheck'), coldFinal: cold.dataset.hl, coldPres: pres.get(901),
      warmFirst, warmFinal: warm.dataset.hl, warmPres: pres.get(902),
      colored: !!cold.querySelector('pre.shiki span[style]') && !!warm.querySelector('pre.shiki span[style]') };
  });
  check('slow cold-grammar highlight is redone once and settles', r.sawRecheck && r.coldFinal === 'done' && r.coldPres === 2 && r.colored, JSON.stringify(r));
  check('slow warm-grammar highlight is not redone', r.warmFirst === 'done' && r.warmFinal === 'done' && r.warmPres === 0 && r.colored, JSON.stringify(r));
}
// Footnotes: a reference lands on its note mid-screen and marks where; the
// back link returns to the reference.
{
  const ops = [];
  for (let i = 1; i <= 40; i++) ops.push({ op: 'insert', slot: 1000 + i, after: i === 1 ? 0 : 999 + i, kind: 'paragraph', html: `<p>filler ${i}</p>` });
  ops.splice(1, 0, { op: 'insert', slot: 1100, after: 1001, kind: 'paragraph',
    html: '<p>Claim<sup class="fn-ref"><a href="#user-content-fn-1" id="user-content-fnref-1" data-footnote-ref>1</a></sup>.</p>' });
  ops[2].after = 1100;
  ops.push({ op: 'insert', slot: 1200, after: 1040, kind: 'footnotes',
    html: '<section class="footnotes" data-footnotes><ol><li id="user-content-fn-1"><p>Source. <a href="#user-content-fnref-1" class="fn-back" data-footnote-backref>↩</a></p></li></ol></section>' });
  await page.evaluate(p => window.readout.apply(p), { version: 95, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await page.evaluate(() => window.scrollTo(0, 0));
  const r = await page.evaluate(async () => {
    document.querySelector('[data-footnote-ref]').click();
    await new Promise(r => setTimeout(r, 50));
    const note = document.getElementById('user-content-fn-1');
    const nr = note.getBoundingClientRect();
    const landed = note.classList.contains('landed');
    note.querySelector('.fn-back').click();
    await new Promise(r => setTimeout(r, 50));
    const ref = document.getElementById('user-content-fnref-1').getBoundingClientRect();
    return { noteMid: nr.top + nr.height / 2, h: innerHeight, landed, refVisible: ref.top >= 0 && ref.bottom <= innerHeight };
  });
  check('footnote reference lands on its note mid-screen and marks it', Math.abs(r.noteMid - r.h / 2) < r.h * 0.2 && r.landed, JSON.stringify(r));
  check('footnote back link returns to the reference', r.refVisible, JSON.stringify(r));
}

// Code wrap: toggling from a code block posts the choice and keeps the reading position.
{
  const ops = [];
  for (let i = 1; i <= 30; i++) ops.push({ op: 'insert', slot: 1300 + i, after: i === 1 ? 0 : 1299 + i, kind: 'code',
    html: `<div class="code-block" data-lang="text"><pre><code>${'long line '.repeat(40)} ${i}</code></pre></div>` });
  await page.evaluate(p => window.readout.apply(p), { version: 96, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  const r = await page.evaluate(async () => {
    const target = document.querySelector('.blk[data-slot="1320"]');
    window.scrollBy(0, target.getBoundingClientRect().top);
    const before = target.getBoundingClientRect().top;
    window.__msgs.length = 0;
    target.querySelector('.cb-wrap').click();
    const after = target.getBoundingClientRect().top;
    const wrapped = getComputedStyle(target.querySelector('pre')).whiteSpace;
    const msg = window.__msgs.find(m => m.type === 'setCodeWrap');
    window.readout.setAppearance({ codeWrap: false });
    return { shift: after - before, wrapped, msg, unwrapped: getComputedStyle(target.querySelector('pre')).whiteSpace };
  });
  check('code wrap toggle wraps, posts the choice and keeps position', r.wrapped === 'pre-wrap' && r.msg && r.msg.on === true && Math.abs(r.shift) <= 2, JSON.stringify(r));
  check('code wrap set from the app turns it off again', r.unwrapped === 'pre', JSON.stringify(r));
}

// Tables: a table that stops fitting when the window narrows starts scrolling.
{
  const cells = Array.from({ length: 4 }, (_, i) => `<td>column ${i} value</td>`).join('');
  await page.evaluate(p => window.readout.apply(p), { version: 97, reset: true, rewrite: false,
    ops: [{ op: 'insert', slot: 1401, after: 0, kind: 'table', html: `<div class="table-wrap"><table><thead><tr>${cells.replace(/td/g, 'th')}</tr></thead><tbody><tr>${cells}</tr></tbody></table></div>` }],
    marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await page.waitForTimeout(100);
  const wide = await page.evaluate(() => document.querySelector('.table-wrap').classList.contains('scrolls'));
  await page.setViewportSize({ width: 420, height: 700 });
  await page.waitForTimeout(200);
  const narrow = await page.evaluate(() => ({ scrolls: document.querySelector('.table-wrap').classList.contains('scrolls'),
    pageScroll: document.scrollingElement.scrollWidth > innerWidth + 1 }));
  await page.setViewportSize({ width: 900, height: 700 });
  check('table starts scrolling when the window narrows', !wide && narrow.scrolls && !narrow.pageScroll, JSON.stringify({ wide, narrow }));
}
// What changed: the edit mark of a modified block opens a word-level comparison
// under it, without moving the reader; it stays open when the block is read
// and a later patch arrives; an unknown earlier text says so.
{
  const ops = Array.from({ length: 40 }, (_, i) => ({ op: 'insert', slot: 1501 + i, after: i ? 1500 + i : 0, kind: 'paragraph', html: `<p>Paragraph ${i} with enough words to fill a line of the column.</p>` }));
  await page.evaluate(p => window.readout.apply(p), { version: 98, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await page.evaluate(p => window.readout.apply(p), { version: 99, reset: false, rewrite: false,
    ops: [{ op: 'replace', slot: 1521, kind: 'paragraph', change: 'content', html: '<p>Paragraph 20 now uses Postgres.</p>' },
          { op: 'replace', slot: 1525, kind: 'paragraph', change: 'content', html: '<p>Paragraph 24 changed.</p>' }],
    marks: [{ slot: 1521, kind: 'modified', diff: 'Paragraph 20 now uses <del>Redis &lt;b&gt;</del><ins>Postgres</ins>.' },
            { slot: 1525, kind: 'modified', diff: '' }],
    deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  const r = await page.evaluate(async () => {
    const el = document.querySelector('.blk[data-slot="1521"]');
    window.scrollTo(0, el.offsetTop - 300);
    await new Promise(r => requestAnimationFrame(r));
    // The block at the top of the view: what the reader is looking at.
    const ref = [...document.querySelectorAll('#ro-doc > .blk')].find(b => b.getBoundingClientRect().top >= 0);
    const top0 = ref.getBoundingClientRect().top;
    const textLeft = el.firstElementChild.getBoundingClientRect().left;
    const y = el.getBoundingClientRect().top + 8;
    // A click on the text itself does nothing; one in the gutter opens it.
    el.firstElementChild.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: textLeft + 20, clientY: y }));
    const afterTextClick = !!el.querySelector('.wd-panel');
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: textLeft - 20, clientY: y }));
    const panel = el.querySelector('.wd-panel');
    const opened = { del: panel?.querySelector('del')?.textContent, ins: panel?.querySelector('ins')?.textContent,
      escaped: !panel?.querySelector('b'), shift: ref.getBoundingClientRect().top - top0 };
    // Another patch (the block was read meanwhile: no mark) keeps it open.
    window.readout.apply({ version: 100, reset: false, rewrite: false, ops: [{ op: 'replace', slot: 1540, kind: 'paragraph', change: 'content', html: '<p>Last one edited.</p>' }],
      marks: [{ slot: 1540, kind: 'modified', diff: '<del>a</del><ins>b</ins>' }], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
    const keptOpen = !!el.querySelector('.wd-panel ins');
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: textLeft - 20, clientY: y }));
    const closed = !el.querySelector('.wd-panel');
    const closeShift = ref.getBoundingClientRect().top - top0;
    const unknown = window.readout.toggleDiff(1525) && document.querySelector('.blk[data-slot="1525"] .wd-body.wd-none')?.textContent;
    window.readout.toggleDiff(1525);
    // Read (the mark is gone) and the gutter still opens it; so does D.
    el.classList.remove('m-modified', 'm-read');
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: textLeft - 20, clientY: y }));
    const afterRead = !!el.querySelector('.wd-panel');
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: textLeft - 20, clientY: y }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', bubbles: true }));
    const byKey = !!document.querySelector('.wd-panel');
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', bubbles: true }));
    return { afterTextClick, opened, keptOpen, closed, closeShift, unknown, afterRead, byKey, refSlot: ref.dataset.slot };
  });
  check('text click does not open the comparison', r.afterTextClick === false, JSON.stringify(r));
  check('edit mark opens the comparison', r.opened.del === 'Redis <b>' && r.opened.ins === 'Postgres' && r.opened.escaped, JSON.stringify(r.opened));
  check('opening the comparison keeps the position', Math.abs(r.opened.shift) < 2, JSON.stringify(r.opened));
  check('the comparison stays open across a patch', r.keptOpen, JSON.stringify(r));
  check('closing the comparison keeps the position', r.closed && Math.abs(r.closeShift) < 2, JSON.stringify(r));
  check('an unknown earlier text says so', typeof r.unknown === 'string' && r.unknown.length > 10, JSON.stringify(r));
  check('the comparison opens after the block was read', r.afterRead, JSON.stringify(r));
  check('D opens the comparison of an edited block in view', r.byKey, JSON.stringify(r));
}
// Code inside a closed <details> is highlighted when it is opened.
{
  await page.evaluate(p => window.readout.apply(p), { version: 120, reset: true, rewrite: false,
    ops: [{ op: 'insert', slot: 1601, after: 0, kind: 'html', html: '<details><summary>More</summary><div class="code-block" data-lang="js"><pre><code>const answer = 42;</code></pre></div></details>' }],
    marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await settled();   // the observers have seen the closed block
  const before = await page.evaluate(() => document.querySelector('.blk[data-slot="1601"] .code-block').dataset.hl);
  await page.evaluate(() => { document.querySelector('.blk[data-slot="1601"] details').open = true; });
  let after = '';
  for (let i = 0; i < 60 && after !== 'done'; i++) {
    await page.waitForTimeout(50);
    after = await page.evaluate(() => document.querySelector('.blk[data-slot="1601"] .code-block').dataset.hl);
  }
  check('code in a closed <details> is highlighted when opened', after === 'done', JSON.stringify({ before, after }));
}
// Comparisons and removed texts arrive once; later patches leave them out.
{
  const base = { rewrite: false, toc: [], tasks: { done: 0, total: 0 } };
  await page.evaluate(p => window.readout.apply(p), { ...base, version: 130, reset: true,
    ops: [{ op: 'insert', slot: 1701, after: 0, kind: 'paragraph', html: '<p>The plan uses Postgres.</p>' },
          { op: 'insert', slot: 1702, after: 1701, kind: 'paragraph', html: '<p>End.</p>' }],
    marks: [{ slot: 1701, kind: 'modified', diff: 'The plan uses <del>Redis</del><ins>Postgres</ins>.' }],
    deletions: [{ id: 91, after: 1701, count: 1, preview: 'Removed words.' }] });
  await page.evaluate(p => window.readout.apply(p), { ...base, version: 131, reset: false,
    ops: [{ op: 'replace', slot: 1702, change: 'content', kind: 'paragraph', html: '<p>End, changed.</p>' }],
    marks: [{ slot: 1701, kind: 'modified' }, { slot: 1702, kind: 'modified', diff: '<del>End</del><ins>End, changed</ins>.' }],
    deletions: [{ id: 91, after: 1701, count: 1 }] });
  const r = await page.evaluate(() => {
    const has = document.querySelector('.blk[data-slot="1701"]').classList.contains('wd-has');
    document.querySelector('.del-mark[data-del="91"] button').click();
    const text = document.querySelector('.del-mark[data-del="91"] .del-pop')?.textContent;
    document.body.click();
    return { has, text };
  });
  check('a comparison sent earlier stays available', r.has, JSON.stringify(r));
  check('a removed text sent earlier still opens', r.text === 'Removed words.', JSON.stringify(r));
}
// D walks down the screen: the topmost closed comparison in view first, then
// the next; once all in view are open, it closes them.
{
  const base = { rewrite: false, toc: [], tasks: { done: 0, total: 0 }, deletions: [] };
  await page.evaluate(p => window.readout.apply(p), { ...base, version: 140, reset: true,
    ops: [{ op: 'insert', slot: 1801, after: 0, kind: 'paragraph', html: '<p>First edited.</p>' },
          { op: 'insert', slot: 1802, after: 1801, kind: 'paragraph', html: '<p>Second edited.</p>' }],
    marks: [{ slot: 1801, kind: 'modified', diff: '<ins>First</ins> edited.' },
            { slot: 1802, kind: 'modified', diff: '<ins>Second</ins> edited.' }] });
  await page.evaluate(() => window.scrollTo(0, 0));
  const press = () => page.evaluate(() => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', bubbles: true }));
    return [1801, 1802].filter(s => document.querySelector(`.blk[data-slot="${s}"] > .wd-panel`));
  });
  const steps = [await press(), await press(), await press()];
  check('D opens the top comparison, then the next, then closes both',
    JSON.stringify(steps) === JSON.stringify([[1801], [1801, 1802], []]), JSON.stringify(steps));
}
// A tall comparison that pushes the next edited block off screen does not
// stop D from reaching it: the press after still opens that block.
{
  const base = { rewrite: false, toc: [], tasks: { done: 0, total: 0 }, deletions: [] };
  const long = 'changed words here '.repeat(1500);
  await page.evaluate(p => window.readout.apply(p), { ...base, version: 150, reset: true,
    ops: [{ op: 'insert', slot: 1901, after: 0, kind: 'paragraph', html: '<p>First edited.</p>' },
          { op: 'insert', slot: 1902, after: 1901, kind: 'paragraph', html: '<p>Second edited.</p>' }],
    marks: [{ slot: 1901, kind: 'modified', diff: `<del>${long}</del><ins>First</ins> edited.` },
            { slot: 1902, kind: 'modified', diff: '<ins>Second</ins> edited.' }] });
  await page.evaluate(() => window.scrollTo(0, 0));
  const press = () => page.evaluate(() => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', bubbles: true }));
    const second = document.querySelector('.blk[data-slot="1902"]').getBoundingClientRect().top;
    return { open: [1901, 1902].filter(s => document.querySelector(`.blk[data-slot="${s}"] > .wd-panel`)),
             pushed: second > innerHeight };
  });
  const steps = [await press(), await press(), await press()];
  check('D reaches a comparison the one above pushed off screen',
    steps[0].pushed && JSON.stringify(steps.map(s => s.open)) === JSON.stringify([[1901], [1901, 1902], []]),
    JSON.stringify(steps));
}
// ---------------------------------------------------------------- 3.3 reader fixes
const fixBase = { rewrite: false, toc: [], tasks: { done: 0, total: 0 }, marks: [], deletions: [] };
let fixVersion = 200;
function fixReset(n, html = i => `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`, kind = () => 'paragraph', first = 1) {
  const ops = [];
  for (let i = 0; i < n; i++) ops.push({ op: 'insert', slot: first + i, after: i ? first + i - 1 : 0, html: html(first + i), kind: kind(first + i) });
  return { ...fixBase, version: ++fixVersion, reset: true, ops };
}
const fixPatch = o => ({ ...fixBase, version: ++fixVersion, reset: false, ops: [], ...o });
const topOf = slot => page.evaluate(slot => Math.round(document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().top), slot);
const toTop = (slot, at = 0) => page.evaluate(([slot, at]) => {
  window.scrollBy(0, document.querySelector(`.blk[data-slot="${slot}"]`).getBoundingClientRect().top - at);
}, [slot, at]);

// "This file is empty." goes once content arrives in a patch that is not a reset.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(0));
  const shown = await page.evaluate(() => !!document.getElementById('ro-empty'));
  await page.evaluate(p => window.readout.apply(p), fixPatch({
    ops: [{ op: 'insert', slot: 1, after: 0, html: '<p>hello</p>', kind: 'paragraph' }], marks: [{ slot: 1, kind: 'inserted' }] }));
  const after = await page.evaluate(() => !!document.getElementById('ro-empty'));
  check('empty-file notice goes when content arrives', shown && !after, JSON.stringify({ shown, after }));
}

// The block at the top of the viewport is removed: the block after it takes
// its place, not the section heading far above.
{
  const r = fixReset(60, i => i === 1 ? '<h2>Section</h2>' : `<p>para ${i} ${'lorem ipsum '.repeat(10)}</p>`, i => i === 1 ? 'heading' : 'paragraph');
  r.ops[0].anchor = 'section';
  await page.evaluate(p => window.readout.apply(p), r);
  await toTop(40, 5);
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 40 }], deletions: [{ id: 1, after: 39, count: 1, preview: 'x' }] }));
  const a = await page.evaluate(() => window.readout.captureAnchor());
  check('removing the top block keeps the reader at the next one', a.slot === 41 && Math.abs(a.offset) <= 2, JSON.stringify(a));
}

// Font size, column width and window size reflow every block: the reader keeps their place.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(100));
  await toTop(80);
  await settled();
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 20 }));
  const sync = await page.evaluate(() => window.readout.captureAnchor());
  await page.waitForTimeout(500);
  const font = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  await page.waitForTimeout(500);
  const wide = await page.evaluate(() => window.readout.captureAnchor());
  await page.setViewportSize({ width: 560, height: 700 });
  await page.waitForTimeout(600);
  const narrow = await page.evaluate(() => window.readout.captureAnchor());
  await page.setViewportSize({ width: 900, height: 700 });
  await page.waitForTimeout(600);
  const back = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 16, width: 'narrow' }));
  const restored = await page.evaluate(() => window.readout.captureAnchor());
  const steps = [sync, font, wide, narrow, back, restored].map(a => a.slot);
  check('font size, width and window resize keep the reading position',
    a0.slot === 80 && steps.every(s => s === 80) && Math.abs(restored.offset) <= 3, JSON.stringify({ steps, offset: restored.offset }));
}

// Jump targets aim below the window toolbar the page scrolls under.
{
  const r = fixReset(60, i => i === 30 ? '<h2 id="inset-target">Target</h2>' : `<p>para ${i}</p>`, i => i === 30 ? 'heading' : 'paragraph');
  r.ops[29].anchor = 'inset-target';
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(() => window.readout.scrollToSlot(40));
  const slotTop = await topOf(40);
  await page.evaluate(() => window.readout.scrollToFragment({ fragment: 'inset-target' }));
  const fragTop = await page.evaluate(() => Math.round(document.getElementById('inset-target').getBoundingClientRect().top));
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('TOC and fragment jumps land below the toolbar inset', Math.abs(slotTop - 68) <= 2 && Math.abs(fragTop - 68) <= 2, JSON.stringify({ slotTop, fragTop }));
}

// Find in page: a large document lays out all of its blocks while finding.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i === 200 ? '<p>needle zebracorn here</p>' : `<p>para ${i} short</p>`));
  await toTop(100);
  await page.waitForTimeout(300);
  const before = await topOf(100);
  await page.evaluate(() => window.readout.findMode(true));
  const r = await page.evaluate(() => ({ cv: document.getElementById('ro-doc').classList.contains('cv'), top: Math.round(document.querySelector('.blk[data-slot="100"]').getBoundingClientRect().top) }));
  const found = await page.evaluate(() => {
    getSelection().removeAllRanges();
    const f = window.find('zebracorn');
    const s = getSelection();
    return { f, slot: s.rangeCount ? s.getRangeAt(0).startContainer.parentElement.closest('.blk')?.dataset.slot : null };
  });
  await page.evaluate(() => window.readout.findMode(false));
  const cvAfter = await page.evaluate(() => document.getElementById('ro-doc').classList.contains('cv'));
  check('find mode lays out a large document and keeps the place', !r.cv && Math.abs(r.top - before) <= 2 && cvAfter, JSON.stringify({ before, r, cvAfter }));
  check('find in page reaches block 200 of 400 in find mode', found.f && found.slot === '200', JSON.stringify(found));
}

// n in a large document lands on the change (no smooth scroll fighting the compensator).
{
  const r = fixReset(400, i => `<p>para ${i} short</p>`);
  r.marks = [{ slot: 380, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
  await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'n', bubbles: true })));
  await page.waitForTimeout(1500);
  const r2 = await page.evaluate(() => ({ top: Math.round(document.querySelector('.blk[data-slot="380"]').getBoundingClientRect().top), want: Math.round(innerHeight / 3) }));
  check('n in a large document lands on the change', Math.abs(r2.top - r2.want) <= 30, JSON.stringify(r2));
}

// A change taller than two screens is marked read once half a screen of it has been seen.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(10));
  await page.evaluate(p => window.readout.apply(p), fixPatch({
    ops: [{ op: 'insert', slot: 11, after: 5, html: `<p>${'a very long inserted paragraph '.repeat(400)}</p>`, kind: 'paragraph' }],
    marks: [{ slot: 11, kind: 'inserted' }] }));
  await page.evaluate(() => { window.__msgs.length = 0; });
  await toTop(11, -100);
  await page.waitForTimeout(1300);
  const r = await page.evaluate(() => ({ h: Math.round(document.querySelector('.blk[data-slot="11"]').getBoundingClientRect().height),
    read: window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots) }));
  check('a block taller than two screens is marked read', r.h > 2 * 700 && r.read.includes(11), JSON.stringify(r));
}

// Read detection while unfocused: a retry that gives up (block out of view)
// lets the next intersection start a new timer.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(40));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(() => { document.hasFocus = () => false; window.__msgs.length = 0; });
  await page.evaluate(p => window.readout.apply(p), fixPatch({
    ops: [{ op: 'replace', slot: 3, html: `<p>${'edited text in a taller block '.repeat(20)}</p>`, kind: 'paragraph', change: 'content' }],
    marks: [{ slot: 3, kind: 'modified', diff: '' }] }));
  await page.waitForTimeout(900);      // the 800 ms timer ran unfocused: a retry is due in 1 s
  // Out of view for the retry, without the intersection observer seeing it.
  await page.evaluate(() => {
    const el = document.querySelector('.blk[data-slot="3"]');
    el.getBoundingClientRect = () => ({ top: 5000, bottom: 5100, left: 0, right: 100, height: 100, width: 100, x: 0, y: 5000 });
  });
  await page.waitForTimeout(1200);
  await page.evaluate(() => { delete document.querySelector('.blk[data-slot="3"]').getBoundingClientRect; delete document.hasFocus; });
  // Partly scrolled off: an intersection change with more than half still visible.
  await page.evaluate(() => { const el = document.querySelector('.blk[data-slot="3"]'); const r = el.getBoundingClientRect(); window.scrollBy(0, r.top + r.height * 0.3); });
  await page.waitForTimeout(1300);
  const read = await page.evaluate(() => window.__msgs.filter(m => m.type === 'read').flatMap(m => m.slots));
  check('read detection restarts after an unfocused retry gave up', read.includes(3), JSON.stringify(read));
}

// The rewrite notice hiding does not move the text.
{
  const rw = fixReset(60, i => `<p>rewritten ${i}</p>`, () => 'paragraph', 1000);
  rw.rewrite = true;
  await page.evaluate(p => window.readout.apply(p), rw);
  await toTop(1030);
  await page.waitForTimeout(200);
  const t0 = await topOf(1030);
  await page.waitForTimeout(6300);
  const t1 = await topOf(1030);
  const hidden = await page.evaluate(() => document.getElementById('ro-notice').hidden);
  check('rewrite notice hides without moving the text', hidden && Math.abs(t1 - t0) <= 1, JSON.stringify({ t0, t1, hidden }));
}

// An open removed-text popup survives an unrelated patch.
{
  await page.evaluate(p => window.readout.apply(p), fixPatch({
    ops: [{ op: 'replace', slot: 1031, html: '<p>edited</p>', kind: 'paragraph', change: 'content' }],
    marks: [{ slot: 1031, kind: 'modified', diff: '' }], deletions: [{ id: 7, after: 1030, count: 1, preview: 'removed text' }] }));
  await page.evaluate(() => document.querySelector('.del-mark > button').click());
  const before = await page.evaluate(() => document.querySelector('.del-pop')?.textContent);
  await page.evaluate(p => window.readout.apply(p), fixPatch({
    ops: [{ op: 'insert', slot: 2000, after: 1059, html: '<p>agent appended</p>', kind: 'paragraph' }],
    marks: [{ slot: 1031, kind: 'modified' }, { slot: 2000, kind: 'inserted' }], deletions: [{ id: 7, after: 1030, count: 1 }] }));
  const after = await page.evaluate(() => document.querySelector('.del-pop')?.textContent);
  check('removed-text popup stays open across an unrelated patch', before === 'removed text' && after === 'removed text', JSON.stringify({ before, after }));
}

// Printing: the changes-only filter is lifted (and comes back afterwards),
// and preparePrint draws diagrams and highlights code far from the viewport.
{
  const mm = '<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Print] --> B[Me]</pre></div>';
  const code = '<div class="code-block" data-lang="js"><pre><code>const far = 1;</code></pre></div>';
  const r = fixReset(300, i => i === 280 ? mm : i === 290 ? code : `<p>para ${i}</p>`, i => i === 280 ? 'mermaid' : i === 290 ? 'code' : 'paragraph');
  r.marks = [{ slot: 50, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.readout.setChangesOnly(true));
  await page.evaluate(() => window.scrollTo(0, 0));
  const hiddenOnScreen = await page.evaluate(() => document.querySelector('.blk[data-slot="20"]').hidden);
  await page.evaluate(() => window.dispatchEvent(new Event('beforeprint')));
  const hiddenPrinting = await page.evaluate(() => document.querySelector('.blk[data-slot="20"]').hidden);
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  const hiddenAfter = await page.evaluate(() => document.querySelector('.blk[data-slot="20"]').hidden);
  await page.evaluate(() => window.readout.setChangesOnly(false));
  check('printing lifts the changes-only filter, then restores it', hiddenOnScreen && !hiddenPrinting && hiddenAfter, JSON.stringify({ hiddenOnScreen, hiddenPrinting, hiddenAfter }));
  await page.evaluate(() => window.scrollTo(0, 0));
  const prepared = await page.evaluate(async () => {
    await window.readout.preparePrint();
    return { diagram: document.querySelector('.blk[data-slot="280"] .mermaid-block').classList.contains('done'),
      code: document.querySelector('.blk[data-slot="290"] .code-block').dataset.hl };
  });
  // The app prints right after preparePrint: finish the print cycle.
  await page.evaluate(() => { window.dispatchEvent(new Event('beforeprint')); window.dispatchEvent(new Event('afterprint')); });
  check('preparePrint draws far diagrams and highlights far code', prepared.diagram && prepared.code === 'done', JSON.stringify(prepared));
}

// Diagrams: identical diagrams get SVG ids of their own; switching the theme
// redraws them in place, keeping the reader where they were.
{
  const mm = i => `<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Start] --> B[Middle ${i % 2}]\n  B --> C[End]</pre></div>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(40, i => i % 5 === 0 ? mm(i) : `<p>para ${i} ${'lorem ipsum '.repeat(8)}</p>`, i => i % 5 === 0 ? 'mermaid' : 'paragraph'));
  // Scroll through so each diagram is drawn as it comes near.
  await page.evaluate(() => window.scrollTo(0, 0));
  for (let k = 0; k < 60 && await page.evaluate(() => document.querySelectorAll('.mermaid-block.done').length) < 8; k++) {
    await page.evaluate(() => window.scrollBy(0, 400));
    await page.waitForTimeout(150);
  }
  const ids = await page.evaluate(() => [...document.querySelectorAll('#ro-doc [id]')].map(e => e.id));
  check('identical diagrams have unique SVG ids', ids.length > 8 && new Set(ids).size === ids.length,
    `${ids.length} ids, ${new Set(ids).size} unique`);
  await toTop(27);
  await page.waitForTimeout(300);
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ dark: true }));
  const svgsSync = await page.evaluate(() => document.querySelectorAll('.mermaid-svg').length);
  await page.waitForTimeout(1500);
  const a1 = await page.evaluate(() => window.readout.captureAnchor());
  const restyled = await page.evaluate(() => [...document.querySelectorAll('.mermaid-block')].filter(b => b.getBoundingClientRect().bottom > -innerHeight && b.getBoundingClientRect().top < 2 * innerHeight).every(b => !b.dataset.stale && b.classList.contains('done')));
  await page.evaluate(() => window.readout.setAppearance({ dark: false }));
  await page.waitForTimeout(800);
  check('theme switch keeps diagrams and the reading position', svgsSync === 8 && a1.slot === a0.slot && Math.abs(a1.offset - a0.offset) <= 2 && restyled,
    JSON.stringify({ svgsSync, a0, a1, restyled }));
}
// A theme change while a diagram is being drawn in the old theme: the
// diagram ends up drawn in the new one.
{
  await page.evaluate(() => window.readout.setAppearance({ dark: false }));
  const src = 'graph TD\n  A[Theme race] --> B[Drawn mid switch]\n  B --> C[Done]';
  const r = await page.evaluate(async p => {
    window.readout.apply(p);
    const b = document.querySelector('.blk[data-slot="1"] .mermaid-block');
    for (let i = 0; i < 2000 && !b.classList.contains('busy'); i++) await new Promise(r => setTimeout(r, 1));
    const busy = b.classList.contains('busy');
    window.readout.setAppearance({ dark: true });
    for (let i = 0; i < 300 && !(b.classList.contains('done') && !b.classList.contains('busy')); i++) await new Promise(r => setTimeout(r, 20));
    const svg = b.querySelector('.mermaid-svg')?.innerHTML.toLowerCase() || '';
    return { busy, done: b.classList.contains('done'), dark: svg.includes('#2a2a2c'), light: svg.includes('#f5f5f7') };
  }, { ...fixBase, version: ++fixVersion, reset: true,
    ops: [{ op: 'insert', slot: 1, after: 0, kind: 'mermaid', html: `<div class="mermaid-block"><pre class="mermaid-src">${src}</pre></div>` }] });
  await page.evaluate(() => window.readout.setAppearance({ dark: false }));
  check('a diagram drawn during a theme switch ends up in the new theme', r.busy && r.done && r.dark && !r.light, JSON.stringify(r));
}
// A second copy of a cached diagram gets ids of its own, but its text stays
// the text written, even when a label looks like an id.
{
  const draw = async (p, n) => page.evaluate(async ([p, n]) => {
    window.readout.apply(p);
    for (let i = 0; i < 400 && document.querySelectorAll('.mermaid-block.done').length < n; i++) await new Promise(r => setTimeout(r, 20));
  }, [p, n]);
  const block = src => `<div class="mermaid-block"><pre class="mermaid-src">${src}</pre></div>`;
  await draw({ ...fixBase, version: ++fixVersion, reset: true,
    ops: [{ op: 'insert', slot: 1, after: 0, kind: 'mermaid', html: block('graph TD\n  P[Probe] --> Q[Id]') }] }, 1);
  // The next diagram drawn takes the id after the probe's.
  const next = await page.evaluate(() => `mmd-${+document.querySelector('.mermaid-svg svg').id.slice(4) + 1}`);
  const src = `graph TD\n  A["${next}"] --> B[Copy]`;
  await draw({ ...fixBase, version: ++fixVersion, reset: true,
    ops: [{ op: 'insert', slot: 1, after: 0, kind: 'mermaid', html: block(src) },
          { op: 'insert', slot: 2, after: 1, kind: 'mermaid', html: block(src) }] }, 2);
  const r = await page.evaluate(label => {
    const svgs = [...document.querySelectorAll('.mermaid-svg svg')];
    const ids = [...document.querySelectorAll('#ro-doc [id]')].map(e => e.id);
    // Every url(#…) and href="#…" points at an element of the same drawing.
    const refsOk = svgs.every(svg => [...svg.querySelectorAll('*')].every(el => [...el.attributes].every(a => {
      const m = a.value.match(/url\(['"]?#([^'")]+)/) || (/href$/.test(a.name) && a.value.match(/^#(.+)/));
      return !m || !!svg.querySelector(`[id="${CSS.escape(m[1])}"]`);
    })));
    const styled = svgs.every(svg => svg.querySelector('style')?.textContent.includes(`#${svg.id}`));
    return { svgIds: svgs.map(s => s.id), labels: svgs.map(s => s.textContent.includes(label)), unique: new Set(ids).size === ids.length, refsOk, styled };
  }, next);
  check('a cached diagram copy keeps label text that looks like an id', r.svgIds.length === 2 && r.svgIds[0] !== r.svgIds[1]
    && r.labels.every(Boolean) && r.unique && r.refsOk && r.styled, JSON.stringify(r));
}

// Printing opens a folded <details> above the viewport: closing it after
// printing leaves the reader where they were.
{
  const fold = `<details><summary>Folded</summary>${'<p>folded paragraph with some words in it</p>'.repeat(40)}</details>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(60, i => i === 5 ? fold : `<p>para ${i} ${'lorem ipsum '.repeat(8)}</p>`));
  await toTop(40);
  await page.waitForTimeout(300);
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.dispatchEvent(new Event('beforeprint')));
  await page.waitForTimeout(300);
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  await page.waitForTimeout(300);
  const a1 = await page.evaluate(() => window.readout.captureAnchor());
  check('printing with a folded section above keeps the place', a1.slot === a0.slot && Math.abs(a1.offset - a0.offset) <= 2, JSON.stringify({ a0, a1 }));
}
// The TOC follows a jump under a tall toolbar (toolbar and tab bar): the
// heading it lands on is the active one.
{
  const r = fixReset(80, i => i % 20 === 1 ? `<h2>Sec ${i}</h2>` : `<p>para ${i} ${'lorem ipsum '.repeat(10)}</p>`, i => i % 20 === 1 ? 'heading' : 'paragraph');
  r.ops.forEach(o => { if (o.kind === 'heading') o.anchor = `sec-${o.slot}`; });
  await page.evaluate(p => window.readout.apply(p), r);
  const active = [];
  for (const inset of [52, 66, 80]) {
    await page.evaluate(i => window.readout.setAppearance({ topInset: i }), inset);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(150);
    await page.evaluate(() => window.readout.scrollToSlot(41));
    await page.waitForTimeout(300);
    active.push(await page.evaluate(() => window.__msgs.filter(m => m.type === 'activeHeading').at(-1)?.slot));
  }
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('TOC highlights the heading a jump lands on under a tall toolbar', active.every(s => s === 41), JSON.stringify(active));
}

// Printing from dark mode: diagrams are drawn light for paper, then dark
// again afterwards, and the reader stays where they were.
{
  const mm = '<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Paper] --> B[Light]</pre></div>';
  await page.evaluate(() => window.readout.setAppearance({ dark: true }));
  await page.evaluate(p => window.readout.apply(p), fixReset(60, i => i === 3 ? mm : `<p>para ${i} ${'lorem ipsum '.repeat(8)}</p>`, i => i === 3 ? 'mermaid' : 'paragraph'));
  const fills = () => page.evaluate(async () => {
    const b = document.querySelector('.blk[data-slot="3"] .mermaid-block');
    for (let i = 0; i < 300 && !(b.classList.contains('done') && !b.dataset.stale && !b.classList.contains('busy')); i++) await new Promise(r => setTimeout(r, 20));
    const svg = b.querySelector('.mermaid-svg')?.innerHTML.toLowerCase() || '';
    return svg.includes('#2a2a2c') ? 'dark' : svg.includes('#f5f5f7') ? 'light' : 'none';
  });
  await page.evaluate(() => window.scrollTo(0, 0));
  const onScreen = await fills();
  await toTop(40);
  await page.waitForTimeout(300);
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.preparePrint());
  await page.evaluate(() => window.dispatchEvent(new Event('beforeprint')));
  const printed = await fills();
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  await page.waitForTimeout(300);
  const a1 = await page.evaluate(() => window.readout.captureAnchor());
  // Off-screen diagrams are drawn back in the page's theme as they come near.
  await page.evaluate(() => window.scrollTo(0, 0));
  const after = await fills();
  const theme = await page.evaluate(() => document.documentElement.dataset.theme);
  await page.evaluate(() => window.readout.setAppearance({ dark: false }));
  check('printing from dark mode draws diagrams light, then dark again, keeping the place',
    onScreen === 'dark' && printed === 'light' && after === 'dark' && theme === 'dark' && a1.slot === a0.slot && Math.abs(a1.offset - a0.offset) <= 2,
    JSON.stringify({ onScreen, printed, after, theme, a0: [a0.slot, a0.offset], a1: [a1.slot, a1.offset] }));
}
// ---------------------------------------------------------------- 3.4 reader fixes
const gapToEnd = () => page.evaluate(() => { const se = document.scrollingElement; return Math.round(se.scrollHeight - (se.scrollTop + innerHeight)); });
const toEnd = () => page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));

// The agent writes on into the last block (a replace of the last slot, not an
// insert after it): a reader following the end stays at the end.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(30));
  let text = 'streamed line one.';
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot: 31, after: 30, html: `<p>${text}</p>`, kind: 'paragraph' }] }));
  await toEnd();
  await page.waitForTimeout(300);
  const gaps = [];
  for (let k = 0; k < 6; k++) {
    text += ' ' + 'another streamed sentence appended to the same paragraph. '.repeat(6);
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 31, html: `<p>${text}</p>`, kind: 'paragraph', change: 'content' }] }));
    await page.waitForTimeout(50);
    gaps.push(await gapToEnd());
  }
  // A code block the agent streams into, the same.
  const code = n => `<div class="code-block" data-lang="text"><pre><code>${Array.from({ length: n }, (_, i) => `line ${i}`).join('\n')}</code></pre></div>`;
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot: 32, after: 31, html: code(3), kind: 'code' }] }));
  await toEnd();
  await page.waitForTimeout(200);
  for (let k = 1; k <= 4; k++) {
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 32, html: code(3 + k * 15), kind: 'code', change: 'content' }] }));
    await page.waitForTimeout(50);
    gaps.push(await gapToEnd());
  }
  check('writing on into the last block keeps a following reader at the end', gaps.every(g => g <= 1), JSON.stringify(gaps));
}

// Font size, column width, find mode and window size reflow the page: a
// reader following the end stays at the end, and goes on following.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(40));
  await toEnd();
  await page.waitForTimeout(300);
  const gaps = {};
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 19 }));
  await page.waitForTimeout(300);
  gaps.font = await gapToEnd();
  await page.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  await page.waitForTimeout(300);
  gaps.width = await gapToEnd();
  await page.setViewportSize({ width: 640, height: 700 });
  await page.waitForTimeout(600);
  gaps.resize = await gapToEnd();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot: 41, after: 40, html: `<p>${'appended live tail text '.repeat(40)}</p>`, kind: 'paragraph' }] }));
  gaps.append = await gapToEnd();
  await page.setViewportSize({ width: 900, height: 700 });
  await page.waitForTimeout(600);
  gaps.back = await gapToEnd();
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 16, width: 'narrow' }));
  await page.waitForTimeout(300);
  gaps.restored = await gapToEnd();
  check('font size, width and window resize keep a following reader at the end',
    Object.values(gaps).every(g => g <= 1), JSON.stringify(gaps));
}

// Under the window toolbar: the block at the top is the first one below it,
// and when that block is removed the next one takes its place below the toolbar.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  // A block hidden under the toolbar is removed: the text below it stays put.
  await toTop(30, 30);   // block 29 ends under the toolbar, block 30 shows below it
  await page.waitForTimeout(300);
  const under = await page.evaluate(() => {
    const b = [...document.querySelectorAll('#ro-doc > .blk')].find(e => e.getBoundingClientRect().bottom > 8);
    return { slot: +b.dataset.slot, bottom: Math.round(b.getBoundingClientRect().bottom) };
  });
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: under.slot }], deletions: [{ id: 1, after: under.slot - 1, count: 1, preview: 'x' }] }));
  const kept = await topOf(30);
  // The block at the toolbar's edge goes, with the one under the toolbar above
  // it: the next block takes its place below the toolbar, not under it.
  await toTop(40, 52);
  await page.waitForTimeout(300);
  const a = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 39 }, { op: 'remove', slot: 40 }], deletions: [{ id: 2, after: 38, count: 2, preview: 'x' }] }));
  const nextTop = await topOf(41);
  // A block straddling the toolbar's edge grows: the share of it above the
  // edge stays the same, so the line being read stays at the edge.
  await toTop(20, 12);
  await page.waitForTimeout(300);
  const grow = await page.evaluate(() => {
    const r = document.querySelector('.blk[data-slot="20"]').getBoundingClientRect();
    return { slot: window.readout.captureAnchor().slot, above: (52 - r.top) / r.height };
  });
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 20, html: `<p>para 20 ${'lorem ipsum dolor sit amet '.repeat(18)}</p>`, kind: 'paragraph', change: 'content' }] }));
  grow.after = await page.evaluate(() => {
    const r = document.querySelector('.blk[data-slot="20"]').getBoundingClientRect();
    return { above: (52 - r.top) / r.height, h: r.height };
  });
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('a block at the toolbar edge keeps its share above the edge when it grows',
    grow.slot === 20 && Math.abs(grow.after.above * grow.after.h - grow.above * grow.after.h) <= 2, JSON.stringify(grow));
  // A block under the toolbar grows later (an image, a diagram): the text below it stays put.
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  await toTop(10, 30);
  await page.waitForTimeout(300);
  await page.evaluate(() => { const d = document.createElement('div'); d.id = 'grown'; d.style.height = '100px'; document.querySelector('.blk[data-slot="9"]').appendChild(d); });
  await page.waitForTimeout(300);
  const grown = await topOf(10);
  await page.evaluate(() => document.getElementById('grown').remove());
  await page.waitForTimeout(300);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('a block growing under the toolbar leaves the text below it in place', Math.abs(grown - 30) <= 2, `top=${grown}`);
  check('removing a block under the toolbar leaves the text below it in place', under.slot === 29 && under.bottom <= 52 && Math.abs(kept - 30) <= 2, JSON.stringify({ under, kept }));
  check('the reading position is taken below the toolbar and kept there', a.slot === 40 && Math.abs(nextTop - 52) <= 2, JSON.stringify({ slot: a.slot, nextTop }));
}

// A file emptied and written again (an agent truncating it first) brings the
// reader back where they were, or to the end when they were following it.
{
  const emptyAll = () => fixPatch({ ops: Array.from({ length: 60 }, (_, i) => ({ op: 'remove', slot: i + 1 })), deletions: [{ id: 7, after: 0, count: 60, preview: 'x' }] });
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await toTop(30);
  await page.waitForTimeout(300);
  const before = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(p => window.readout.apply(p), emptyAll());
  await page.waitForTimeout(200);
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  const after = await page.evaluate(() => window.readout.captureAnchor());
  await toEnd();
  await page.waitForTimeout(300);
  await page.evaluate(p => window.readout.apply(p), emptyAll());
  await page.waitForTimeout(200);
  await page.evaluate(p => window.readout.apply(p), fixReset(61));
  const gap = await gapToEnd();
  check('an emptied file written again keeps the reading position', before.slot === 30 && after?.slot === 30 && Math.abs(after.offset - before.offset) <= 2 && gap <= 1,
    JSON.stringify({ before: [before.slot, before.offset], after: after && [after.slot, after.offset], gap }));

  // Written again in parts: the first part does not reach the reader's block.
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await toTop(30);
  await page.waitForTimeout(300);
  const before2 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(p => window.readout.apply(p), emptyAll());
  await page.evaluate(p => window.readout.apply(p), fixReset(20));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: fixReset(40, undefined, undefined, 21).ops.map((o, i) => ({ ...o, after: 20 + i })) }));
  const after2 = await page.evaluate(() => window.readout.captureAnchor());
  // Following, and the first part fits in the window: following goes on.
  await toEnd();
  await page.waitForTimeout(300);
  await page.evaluate(p => window.readout.apply(p), emptyAll());
  await page.evaluate(p => window.readout.apply(p), fixReset(2));
  const tail = [];
  for (const slot of [3, 4, 5]) {
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot, after: slot - 1, html: `<p>${'appended live tail text '.repeat(60)}</p>`, kind: 'paragraph' }] }));
    tail.push(await gapToEnd());
  }
  check('an emptied file written again in parts keeps the reading position, or the end',
    after2?.slot === 30 && Math.abs(after2.offset - before2.offset) <= 2 && tail.every(g => g <= 1),
    JSON.stringify({ before: [before2.slot, before2.offset], after: after2 && [after2.slot, after2.offset], tail }));
}

// Headings are named by their text, not by the link button inside them; the
// button stays a named, focusable button.
{
  const r = fixReset(5, i => i === 1 ? '<h2>Overview of <code>the plan</code></h2>'
    : i === 2 ? '<h2>Status <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="Passing"></h2>'
    : i === 3 ? '<h2>Build <span class="remote-img" data-src="https://badge.example/b.svg" data-alt="Green"></span><span hidden> secret</span></h2>' : `<p>para ${i}</p>`, i => i <= 3 ? 'heading' : 'paragraph');
  r.ops[0].anchor = 'overview';
  r.ops[1].anchor = 'status';
  r.ops[2].anchor = 'build';
  await page.evaluate(p => window.readout.apply(p), r);
  const named = await page.getByRole('heading', { name: 'Overview of the plan', exact: true }).count()
    + await page.getByRole('heading', { name: 'Status Passing', exact: true }).count()
    // Until it is loaded a remote image is a button, and the heading shows its label.
    + await page.getByRole('heading', { name: 'Build Load image from badge.example', exact: true }).count();
  const button = page.getByRole('button', { name: 'Copy Link to Section', exact: true }).first();
  await button.focus();
  const focused = await page.evaluate(() => document.activeElement?.classList.contains('h-link'));
  await page.evaluate(() => { window.__msgs.length = 0; });
  await page.keyboard.press('Enter');
  const msg = await page.evaluate(() => window.__msgs.find(m => m.type === 'copyLink'));
  await page.evaluate(() => {
    document.querySelector('.remote-img[data-src="https://badge.example/b.svg"]').dataset.remoteId = 'rb';
    window.readout.remoteReady({ id: 'rb', url: 'data:image/gif;base64,R0lGODlhAQABAAAAACw=' });
  });
  const loaded = await page.getByRole('heading', { name: 'Build Green', exact: true }).count();
  check('a heading is named by its content alone, its link button stays reachable', named === 3 && loaded === 1 && focused && msg?.anchor === 'overview',
    JSON.stringify({ named, loaded, focused, msg }));
}

// An update measures the blocks it changed once, after changing them all: one
// layout, not one per op.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(120));
  await toTop(60);
  await page.waitForTimeout(300);
  const ops = Array.from({ length: 20 }, (_, i) => ({ op: 'replace', slot: 3 + i * 6, html: `<p>edited ${i} ${'lorem ipsum '.repeat(8)}</p>`, kind: 'paragraph', change: 'content' }));
  ops.push(...Array.from({ length: 5 }, (_, i) => ({ op: 'insert', slot: 500 + i, after: 50 + i * 10, html: `<p>inserted ${i}</p>`, kind: 'paragraph' })));
  const layouts = await page.evaluate(p => {
    // Counts measurements that follow a DOM change: each forces a layout.
    let dirty = false, layouts = 0;
    const html = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
    const rect = Element.prototype.getBoundingClientRect;
    Object.defineProperty(Element.prototype, 'innerHTML', { configurable: true, get() { return html.get.call(this); }, set(v) { dirty = true; html.set.call(this, v); } });
    Element.prototype.getBoundingClientRect = function () { if (dirty) { layouts++; dirty = false; } return rect.call(this); };
    try { window.readout.apply(p); } finally {
      Object.defineProperty(Element.prototype, 'innerHTML', html);
      Element.prototype.getBoundingClientRect = rect;
    }
    return layouts;
  }, fixPatch({ ops, marks: ops.map(o => ({ slot: o.slot, kind: o.op === 'insert' ? 'inserted' : 'modified' })) }));
  check('a 25-op update lays out the page once while applying', layouts <= 2, `layouts=${layouts}`);
}

// While the reader scrolls through a large document, blocks resize as they
// are laid out: the rail is redrawn a few times a second, not every frame,
// and its last state is drawn.
{
  const r = fixReset(400, i => `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(1 + (i * 7) % 13)}</p>`);
  r.marks = Array.from({ length: 40 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' }));
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(400);
  const r2 = await page.evaluate(() => new Promise(resolve => {
    const rail = document.getElementById('ro-rail');
    let rebuilds = 0, resizes = 0;
    const mo = new MutationObserver(recs => { for (const rec of recs) if (rec.removedNodes.length) rebuilds++; });
    mo.observe(rail, { childList: true });
    const ro = new ResizeObserver(() => { resizes++; });
    for (const b of document.querySelectorAll('#ro-doc > .blk')) ro.observe(b);
    const start = performance.now();
    const step = () => {
      window.scrollBy(0, 120);
      if (performance.now() - start < 1500) requestAnimationFrame(step);
      else setTimeout(() => { mo.disconnect(); ro.disconnect(); resolve({ rebuilds, resizes, ticks: rail.children.length }); }, 500);
    };
    requestAnimationFrame(step);
  }));
  const unread = await page.evaluate(() => document.querySelectorAll('#ro-doc > .blk.m-inserted:not(.m-read)').length);
  // 1.5 s of scrolling plus the half second after: at most one redraw per 250 ms.
  check('the rail is redrawn at most every 250 ms while blocks resize', r2.resizes > 20 && r2.rebuilds <= 9 && r2.ticks === unread,
    JSON.stringify({ ...r2, unread }));
}

// Rail ticks: placed below the window toolbar, at least 6 px tall, titled
// with their label; a checkbox change is an edit, not an addition.
{
  const r = fixReset(30, i => i === 2 ? '<ul><li><input type="checkbox" checked disabled> task</li></ul>' : `<p style="min-height:170px">rail probe ${i}</p>`, i => i === 2 ? 'listItem' : 'paragraph');
  r.marks = [{ slot: 1, kind: 'inserted' }, { slot: 2, kind: 'state' }];
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52, strings: { railChange: 'Unread change %d of %d: %@', railAdded: 'added', railEdited: 'edited', railRemoved: 'removed' } }));
  await page.evaluate(p => window.readout.apply(p), r);
  await page.waitForTimeout(400);
  const ticks = () => page.evaluate(() => [...document.querySelectorAll('#ro-rail button')].map(b => {
    const rect = b.getBoundingClientRect();
    // The mark's own width: the button reaches further left, transparent.
    return { top: Math.round(rect.top), h: Math.round(rect.height), w: Math.round(rect.width - parseFloat(getComputedStyle(b).paddingLeft)), label: b.getAttribute('aria-label'), title: b.title };
  }));
  const before = await ticks();
  await page.evaluate(() => window.readout.setAppearance({ strings: { railTask: 'task' } }));
  await page.waitForTimeout(400);
  const after = await ticks();
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('rail ticks sit below the toolbar, 6 px tall at least, titled with their label',
    before.length === 2 && before.every(t => t.top >= 52 && t.h >= 6 && t.w === 3 && t.title === t.label), JSON.stringify(before));
  check('a task change is labelled as one (or as an edit), not as an addition',
    before[1]?.label === 'Unread change 2 of 2: edited' && after[1]?.label === 'Unread change 2 of 2: task', JSON.stringify({ before, after }));
}

// The rewrite notice sits below the window toolbar, and fades before it goes.
{
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  const rw = fixReset(60, i => `<p>rewritten ${i}</p>`, () => 'paragraph', 3000);
  rw.rewrite = true;
  const r = await page.evaluate(async p => {
    const wait = ms => new Promise(r => setTimeout(r, ms));
    const notice = document.getElementById('ro-notice');
    window.readout.apply(p);
    window.scrollBy(0, document.querySelector('.blk[data-slot="3030"]').getBoundingClientRect().top);
    await wait(300);
    const top = Math.round(notice.getBoundingClientRect().top);
    const t0 = Math.round(document.querySelector('.blk[data-slot="3030"]').getBoundingClientRect().top);
    await wait(6000 - 300 + 150);
    const fading = { hidden: notice.hidden, opacity: +getComputedStyle(notice).opacity };
    await wait(600);
    const t1 = Math.round(document.querySelector('.blk[data-slot="3030"]').getBoundingClientRect().top);
    return { top, fading, hidden: notice.hidden, t0, t1 };
  }, rw);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('the rewrite notice sits below the toolbar', r.top >= 52 + 8, JSON.stringify(r));
  check('the rewrite notice fades out, then goes without moving the text',
    !r.fading.hidden && r.fading.opacity < 1 && r.hidden && Math.abs(r.t1 - r.t0) <= 1, JSON.stringify(r));
}

// The rail's own label comes from the app's strings.
{
  const before = await page.evaluate(() => document.getElementById('ro-rail').getAttribute('aria-label'));
  await page.evaluate(() => window.readout.setAppearance({ strings: { railLabel: '未读变更' } }));
  await page.waitForTimeout(400);
  const after = await page.evaluate(() => document.getElementById('ro-rail').getAttribute('aria-label'));
  await page.evaluate(() => window.readout.setAppearance({ strings: { railLabel: 'Unread changes' } }));
  check('the rail is labelled with the localized string', before === 'Unread changes' && after === '未读变更', JSON.stringify({ before, after }));
}

// No data-theme from the app (reader.html sets none): diagrams follow the
// system's appearance, print light, and the attribute is left absent.
{
  const sys = await browser.newPage({ viewport: { width: 900, height: 700 }, colorScheme: 'dark' });
  collectPageErrors(sys, errors);
  await sys.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await sys.goto(`${base}/reader.html`);
  await sys.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  const mm = '<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[System] --> B[Theme]</pre></div>';
  const ops = Array.from({ length: 3 }, (_, i) => ({ op: 'insert', slot: i + 1, after: i, kind: i === 0 ? 'mermaid' : 'paragraph', html: i === 0 ? mm : `<p>para ${i}</p>` }));
  await sys.evaluate(p => window.readout.apply(p), { ...fixBase, version: 1, reset: true, ops });
  const fills = () => sys.evaluate(async () => {
    const b = document.querySelector('.mermaid-block');
    for (let i = 0; i < 400 && !(b.classList.contains('done') && !b.dataset.stale && !b.classList.contains('busy')); i++) await new Promise(r => setTimeout(r, 20));
    const svg = b.querySelector('.mermaid-svg')?.innerHTML.toLowerCase() || '';
    return { theme: svg.includes('#2a2a2c') ? 'dark' : svg.includes('#f5f5f7') ? 'light' : 'none',
      attr: document.documentElement.getAttribute('data-theme') };
  });
  const shown = await fills();
  await sys.evaluate(() => window.readout.preparePrint());
  await sys.evaluate(() => window.dispatchEvent(new Event('beforeprint')));
  const printed = await fills();
  await sys.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  const back = await fills();
  await sys.close();
  check('with no data-theme, diagrams follow the system, print light, and leave the attribute absent',
    shown.theme === 'dark' && printed.theme === 'light' && back.theme === 'dark' && [shown, printed, back].every(s => s.attr === null),
    JSON.stringify({ shown, printed, back }));
}

// An empty page is never following. A file opened empty in a short window,
// whose empty page sits scrolled to its own bottom: the content that arrives
// shows from the top, not from its end.
{
  const short = await browser.newPage({ viewport: { width: 900, height: 160 } });
  collectPageErrors(short, errors);
  await short.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await short.goto(`${base}/reader.html`);
  await short.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await short.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16, topInset: 80 }));
  await short.evaluate(p => window.readout.apply(p), { ...fixBase, version: 1, reset: true, ops: [] });
  const emptyTop = await short.evaluate(() => { window.scrollTo(0, 10000); return document.scrollingElement.scrollTop; });
  await short.waitForTimeout(200);
  await short.evaluate(p => window.readout.apply(p), { ...fixBase, version: 2, reset: false, ops: fixReset(60).ops, marks: [] });
  const first = await short.evaluate(() => Math.round(document.querySelector('.blk[data-slot="1"]').getBoundingClientRect().top));
  await short.close();
  check('content arriving in an empty page shows from the top, not from its end', emptyTop > 0 && first >= 0 && first < 160, JSON.stringify({ emptyTop, first }));
}

// A file emptied and written again: scrolling the empty page in between
// does not lose the place.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await toTop(30);
  await page.waitForTimeout(300);
  const before = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 60 }, (_, i) => ({ op: 'remove', slot: i + 1 })), deletions: [{ id: 9, after: 0, count: 60, preview: 'x' }] }));
  await page.evaluate(() => { window.scrollTo(0, 10000); window.scrollTo(0, 0); });
  await page.waitForTimeout(600);
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  const after = await page.evaluate(() => window.readout.captureAnchor());
  check('scrolling the emptied page does not lose the reading position', after?.slot === 30 && Math.abs(after.offset - before.offset) <= 2,
    JSON.stringify({ before: [before.slot, before.offset], after: after && [after.slot, after.offset] }));
}

// The toolbar inset changes (a tab bar appears): a reader inside the document
// keeps their place; at the top, the document moves down from under the toolbar.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await toTop(40, 100);
  await page.waitForTimeout(300);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  const inside = await topOf(40);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  const back = await topOf(40);
  await page.evaluate(() => window.scrollTo(0, 0));
  const top0 = await topOf(1);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  const top52 = await topOf(1);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('a toolbar inset change keeps a reader in the document in place, and moves the top down',
    Math.abs(inside - 100) <= 2 && Math.abs(back - 100) <= 2 && top52 - top0 === 52, JSON.stringify({ inside, back, top0, top52 }));
}

// A read that catches the file half written cuts the document short below
// the reader: the page cannot scroll to their place and sits at its end.
// That is not following: when the rest arrives the reader is put back, not
// sent to the new end. Directly, and after the file was emptied first.
{
  const shifts = [];
  for (const emptied of [false, true]) {
    await page.evaluate(p => window.readout.apply(p), fixReset(60));
    await toTop(30, 40);
    await page.waitForTimeout(300);
    const t0 = await topOf(30);
    if (emptied) {
      await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 60 }, (_, i) => ({ op: 'remove', slot: i + 1 })), deletions: [{ id: 11, after: 0, count: 60, preview: 'x' }] }));
      await page.evaluate(p => window.readout.apply(p), fixReset(31));
    } else {
      await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 29 }, (_, i) => ({ op: 'remove', slot: 32 + i })) }));
    }
    const cut = await topOf(30);
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: fixReset(29, undefined, undefined, 32).ops.map((o, i) => ({ ...o, after: 31 + i })) }));
    shifts.push({ emptied, cut: cut - t0, shift: (await topOf(30)) - t0 });
  }
  check('a document cut short below the reader, then completed, puts the reader back', shifts.every(s => s.cut > 0 && Math.abs(s.shift) <= 1), JSON.stringify(shifts));
}

// The window resizes in the frame of a scroll made just before it (the app
// showing a window, a script scrolling): resize events run before scroll
// events, so the place settled before that scroll is stale. The resize keeps
// the place the scroll went to. (The smoke refill check failed this way:
// a resize hold put the reader back where they had been seconds earlier.)
{
  await page.evaluate(p => window.readout.apply(p), fixReset(60));
  await toTop(10);
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    window.scrollBy(0, document.querySelector('.blk[data-slot="40"]').getBoundingClientRect().top - 40);
    window.dispatchEvent(new Event('resize'));
  });
  await page.waitForTimeout(500);
  const top40 = await topOf(40);
  check('a resize right after a scroll keeps the place the scroll went to', Math.abs(top40 - 40) <= 2, `top=${top40}`);
}

// Emptied, then refilled in part without the reader's block: the held place
// survives a block above rendering taller (a diagram or formula; the page
// compensates for it, which is not the reader moving), and the completed
// document puts the reader back instead of following it to its end.
{
  // The reader's section heading (block 20) arrives in the first part: the page waits there.
  const doc = n => {
    const r = fixReset(n, i => i === 20 ? '<h2>Section</h2>' : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(6)}</p>`, i => i === 20 ? 'heading' : 'paragraph');
    r.ops[19].anchor = 'section';
    return r;
  };
  await page.evaluate(p => window.readout.apply(p), doc(60));
  await toTop(30, 40);
  await page.waitForTimeout(300);
  const t0 = await topOf(30);
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 60 }, (_, i) => ({ op: 'remove', slot: i + 1 })), deletions: [{ id: 12, after: 0, count: 60, preview: 'x' }] }));
  await page.evaluate(p => window.readout.apply(p), doc(25));
  const y0 = await page.evaluate(() => scrollY);
  await page.evaluate(() => { const d = document.createElement('div'); d.style.height = '300px'; document.querySelector('.blk[data-slot="3"]').appendChild(d); });
  await page.waitForTimeout(300);
  const compensated = (await page.evaluate(() => scrollY)) - y0;
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: doc(60).ops.slice(25) }));
  const shift = (await topOf(30)) - t0;
  check('a held place survives the page compensating for a block above, then puts the reader back', compensated >= 290 && Math.abs(shift) <= 1, JSON.stringify({ compensated, shift }));
}

// Every suite shares the one filter: WebKit's ResizeObserver loop notice is
// not a page error (it decided whether a run failed by how frames fell).
check('a ResizeObserver loop notice is not a page error, anything else is',
  benign('ResizeObserver loop completed with undelivered notifications.') && !benign('TypeError: undefined is not an object'));
check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
