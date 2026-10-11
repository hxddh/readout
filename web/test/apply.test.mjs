// JS unit tests for the reader patch engine (insert order, anchor stability,
// follow semantics). Runs in WebKit by default (the production engine) via
// Playwright; BROWSER selects the engine (webkit | chromium | firefox).
// Usage: BROWSER=webkit node test/apply.test.mjs  (requires web/build.mjs to have run)
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
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
page.on('pageerror', e => errors.push(String(e)));
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
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForTimeout(200);
await page.evaluate(() => window.readout.apply({
  version: 6, reset: false, rewrite: false,
  ops: [{ op: 'insert', slot: 202, after: 40, html: '<p>appended at end</p>', kind: 'paragraph' }],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const atBottom = await page.evaluate(() => {
  const se = document.scrollingElement;
  return se.scrollHeight - (se.scrollTop + window.innerHeight) < 48;
});
check('append at end follows', atBottom);

// 5. Fragment scroll.
await page.evaluate(() => window.scrollTo(0, 0));
await page.evaluate(p => window.readout.apply({
  version: 7, reset: true, rewrite: false,
  ops: [
    { op: 'insert', slot: 301, after: 0, html: '<h2 id="target-section">Target</h2>', kind: 'heading', anchor: 'target-section' },
    ...Array.from({ length: 30 }, (_, i) => ({ op: 'insert', slot: 302 + i, after: 301 + i, html: `<p>filler ${i}</p>`, kind: 'paragraph' })),
  ],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
await page.evaluate(() => window.readout.scrollToFragment({ fragment: 'target-section' }));
const fragTop = await page.evaluate(() => document.querySelector('.k-heading').getBoundingClientRect().top);
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
  ],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
});
const idCheck = await page.evaluate(() => {
  const ids = [...document.querySelectorAll('[id]')].map(e => e.id);
  const dupes = ids.filter((id, i) => ids.indexOf(id) !== i);
  const heads = [...document.querySelectorAll('.k-heading')];
  const para = document.querySelector('.blk[data-slot="506"]');
  const paraLeft = para ? para.getBoundingClientRect().left : -1;
  return {
    dupes,
    heads: heads.map(h => {
      const inner = h.querySelector('h1,h2,h3,h4,h5,h6') || h;
      const cs = getComputedStyle(inner);
      const r = inner.getBoundingClientRect();
      return { id: inner.id, position: cs.position, width: r.width, left: r.left };
    }),
    paraLeft,
  };
});
check('no duplicate ids with clashing headings', idCheck.dupes.length === 0, JSON.stringify(idCheck.dupes));
for (const h of idCheck.heads) {
  check(`heading ${h.id} is static-positioned`, h.position === 'static', `${h.id}: ${h.position}`);
  check(`heading ${h.id} keeps full width`, h.width > 100, `${h.id}: ${h.width}`);
  check(`heading ${h.id} aligns with body text`, Math.abs(h.left - idCheck.paraLeft) <= 2, `${h.id}: ${h.left} vs ${idCheck.paraLeft}`);
}
await page.evaluate(() => window.readout.scrollToFragment({ fragment: 'notice' }));
const noticeTop = await page.evaluate(() => {
  const h = [...document.querySelectorAll('.k-heading')].find(e => e.querySelector('h2')?.textContent === 'Notice');
  return h ? h.getBoundingClientRect().top : -999;
});
check('scrollToFragment lands on heading, not chrome', noticeTop >= 0 && noticeTop <= 40, `top=${noticeTop}`);

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
check('changes-only capture sees slot 65', captured && captured.slot === 65, JSON.stringify(captured));
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
await page.waitForTimeout(300);
const railLabels = await page.evaluate(() => [...document.querySelectorAll('#ro-rail button')].map(b => b.getAttribute('aria-label')));
check('rail labels use the localized template',
  JSON.stringify(railLabels) === JSON.stringify(['未读变更 1 / 2：新增', '未读变更 2 / 2：修改']), JSON.stringify(railLabels));

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
