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

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
