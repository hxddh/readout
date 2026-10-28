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
  const p = join(process.env.READOUT_WEB_BUILD || 'build/Web', decodeURIComponent(req.url.split('?')[0]));
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
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));

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
// The first setAppearance and first apply are timed for the smoke test (report only).
const firstTimings = await page.evaluate(() => JSON.stringify(window.readout.firstTimings()));
check('first setAppearance and first apply timed', ['setAppearance', 'blocks', 'layout'].every(k => Number.isFinite(JSON.parse(firstTimings)[k])), firstTimings);
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
    ops: [{ op: 'insert', slot, after, html: `<p>${'appended at the end of the document '.repeat(52)}</p>`, kind: 'paragraph' }],
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

// 6. Section link from the heading's context menu; a silent re-render keeps the unread mark.
await page.evaluate(p => window.readout.apply({
  version: 8, reset: true, rewrite: false,
  ops: [
    { op: 'insert', slot: 401, after: 0, html: '<h2 id="s-a">Section A</h2>', kind: 'heading', anchor: 's-a' },
    { op: 'insert', slot: 402, after: 401, html: '<p>read body</p>', kind: 'paragraph' },
    { op: 'insert', slot: 403, after: 402, html: '<p>new body</p>', kind: 'paragraph' },
  ],
  marks: [{ slot: 403, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
// 3.9 E9: no hover § in the gutter (it drew over the heading's change
// bar); a context menu tells the app which heading it opens on, for its
// Copy Link to Section, and that it is on none elsewhere.
await page.evaluate(() => { window.__msgs.length = 0; });
const ctx = await page.evaluate(() => {
  const menu = el => { el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true })); return window.__msgs.filter(m => m.type === 'contextHeading').pop(); };
  return { button: !!document.querySelector('.h-link, .k-heading button'), heading: menu(document.getElementById('s-a')),
    body: menu(document.querySelector('.blk[data-slot="402"] p')) };
});
check('a heading\'s context menu reports its anchor, a paragraph\'s none; no hover link button',
  !ctx.button && ctx.heading?.anchor === 's-a' && ctx.body?.anchor === '', JSON.stringify(ctx));
// Silent re-render must not drop the unread mark.
await page.evaluate(() => window.readout.apply({
  version: 9, reset: false, rewrite: false,
  ops: [{ op: 'replace', slot: 403, html: '<p>new body</p>', kind: 'paragraph', change: 'silent' }],
  marks: [{ slot: 403, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}));
const afterSilent = await page.evaluate(() => ({
  marked: document.querySelector('.blk[data-slot="403"]').classList.contains('m-inserted'),
}));
check('silent re-render keeps mark', afterSilent.marked, JSON.stringify(afterSilent));
// S1: Show Only Changes is gone: no filter call, no "All caught up" state.
const noFilter = await page.evaluate(() => ({ api: typeof window.readout.setChangesOnly, caught: !!document.getElementById('ro-caughtup') }));
check('no changes-only filter left in the page', noFilter.api === 'undefined' && !noFilter.caught, JSON.stringify(noFilter));

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
// what sits in the gutter (change marks) must be inside it,
// and the layout must not change with the mode.
const contained = await page.evaluate(() => {
  const doc = document.getElementById('ro-doc');
  const b = document.querySelector('.blk[data-slot="506"]');
  const before = parseFloat(getComputedStyle(b, '::before').left);
  const heights = () => [...doc.querySelectorAll('.blk')].slice(0, 40).map(e => Math.round(e.getBoundingClientRect().height));
  const withCV = heights();
  doc.classList.remove('cv');
  const without = heights();
  doc.classList.add('cv');
  return { cv: doc.classList.contains('cv'), before, same: JSON.stringify(withCV) === JSON.stringify(without) };
});
check('large document uses content-visibility', contained.cv);
check('change mark sits inside its block', contained.before >= 0, `left=${contained.before}`);
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

// 8. Anchor stability: a patch above the block at the top does not move it.
await page.evaluate(() => window.scrollTo(0, 0));
{
  const ops = [];
  for (let i = 1; i <= 120; i++) ops.push({ op: 'insert', slot: i, after: i - 1, html: `<p style="min-height:170px">body ${i} with enough text to take vertical space in the viewport</p>`, kind: 'paragraph' });
  const marks = [];
  for (let s = 5; s <= 120; s += 10) marks.push({ slot: s, kind: 'inserted' });
  await page.evaluate(p => window.readout.apply(p), { version: 20, reset: true, rewrite: false, ops, marks, deletions: [], toc: [], tasks: { done: 0, total: 0 } });
}
// Put slot 65 at the top of the viewport.
await page.evaluate(() => {
  const el = document.querySelector('.blk[data-slot="65"]');
  window.scrollBy(0, el.getBoundingClientRect().top);
});
const captured = await page.evaluate(() => window.readout.captureAnchor());
// Failed once in 58 CI runs (null), never locally: say where the page was if it happens again.
const captureState = await page.evaluate(() => ({ scrollY, scrollHeight: document.scrollingElement.scrollHeight,
  cv: document.getElementById('ro-doc').classList.contains('cv'),
  shown: [...document.querySelectorAll('#ro-doc > .chunk > .blk')].filter(e => !e.hidden && e.offsetParent).length,
  top65: document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top }));
check('capture sees slot 65', captured && captured.slot === 65, JSON.stringify({ captured, ...captureState }));
// Insert a long unread paragraph after slot 20: slot 65 must not move.
const top65Before = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
await page.evaluate((extra) => window.readout.apply({
  version: 21, reset: false, rewrite: false,
  ops: [{ op: 'insert', slot: 1001, after: 20, html: `<p>${'inserted long paragraph. '.repeat(30)}</p>`, kind: 'paragraph' }],
  marks: [...extra, { slot: 1001, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}), Array.from({ length: 12 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' })));
const top65After = await page.evaluate(() => document.querySelector('.blk[data-slot="65"]').getBoundingClientRect().top);
check('slot 65 does not jump after patch above', Math.abs(top65After - top65Before) < 2, `shift=${top65After - top65Before}`);

// 12. Rail tick aria-labels come from the localized strings template.
// Tall blocks so the rail renders (it hides on short documents).
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
// 3.9 E3: one strength for every tick (an edited one at 55% was under 3:1);
// the label still says which kind.
const tickOpacity = await page.evaluate(() => [...document.querySelectorAll('#ro-rail button')].map(b => getComputedStyle(b).opacity));
check('an edited rail tick is as strong as an added one', tickOpacity.length === 2 && tickOpacity.every(o => o === '1'), JSON.stringify(tickOpacity));

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
    html: `<div class="code-block" data-lang="js"><pre><code>${'long line '.repeat(40)} ${i}</code></pre></div>` });
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
// Its cells cannot wrap (no-break spaces): short cells that can wrap do so
// before a table scrolls (typography.test.mjs).
{
  const cells = Array.from({ length: 4 }, (_, i) => `<td>column&nbsp;${i}&nbsp;value</td>`).join('');
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
    const ref = [...document.querySelectorAll('#ro-doc > .chunk > .blk')].find(b => b.getBoundingClientRect().top >= 0);
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
// View ▸ Show What Changed calls the page's D directly (no synthetic key press).
{
  const base = { rewrite: false, toc: [], tasks: { done: 0, total: 0 }, deletions: [] };
  await page.evaluate(p => window.readout.apply(p), { ...base, version: 145, reset: true,
    ops: [{ op: 'insert', slot: 1851, after: 0, kind: 'paragraph', html: '<p>First edited.</p>' },
          { op: 'insert', slot: 1852, after: 1851, kind: 'paragraph', html: '<p>Second edited.</p>' }],
    marks: [{ slot: 1851, kind: 'modified', diff: '<ins>First</ins> edited.' },
            { slot: 1852, kind: 'modified', diff: '<ins>Second</ins> edited.' }] });
  await page.evaluate(() => window.scrollTo(0, 0));
  const menu = () => page.evaluate(() => {
    if (typeof window.readout.toggleDiffInView !== 'function') return 'missing';
    window.readout.toggleDiffInView();
    return [1851, 1852].filter(s => document.querySelector(`.blk[data-slot="${s}"] > .wd-panel`));
  });
  const steps = [await menu(), await menu(), await menu()];
  check('Show What Changed walks the comparisons in view as D does',
    JSON.stringify(steps) === JSON.stringify([[1851], [1851, 1852], []]), JSON.stringify(steps));
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

// Chunks (chunks.js): a document's blocks are grouped in chunks of 32 (or
// about four screens' estimate). Order, spacing and the reader's place are the
// same across a chunk's edge: a heading right after a rule sits flush whether
// or not a chunk starts between them, and an agent inserting in the middle of
// a chunk, then removing blocks until chunks empty, keeps the blocks in
// order, no chunk empty or past 64, the reader where they were.
{
  // The rule and heading across the edge go where the first chunk ends (its
  // items are estimated alike: a rule there does not move the edge).
  let edge = -10;
  const kind = i => i === 10 || i === edge ? 'rule' : i === 11 || i === edge + 1 ? 'heading' : 'paragraph';
  const html = i => kind(i) === 'rule' ? '<hr>' : kind(i) === 'heading' ? `<h2>Section ${i}</h2>` : `<p>para ${i} lorem ipsum dolor</p>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(300, html, kind));
  edge = await page.evaluate(() => document.querySelector('#ro-doc > .chunk').childElementCount);
  await page.evaluate(p => window.readout.apply(p), fixReset(300, html, kind));
  const flush = await page.evaluate(edge => {
    const h = s => document.querySelector(`.blk[data-slot="${s}"]`);
    return { edge, sameChunk: h(10).parentElement === h(11).parentElement, acrossChunks: h(edge).parentElement !== h(edge + 1).parentElement,
      inner: getComputedStyle(h(11).firstElementChild).marginTop, edgeTop: getComputedStyle(h(edge + 1).firstElementChild).marginTop };
  }, edge);
  check('a heading after a rule sits flush across a chunk\'s edge as within one', flush.sameChunk && flush.acrossChunks && flush.inner === flush.edgeTop && flush.inner === '0px', JSON.stringify(flush));
  await toTop(150);
  await settled();
  const before = await topOf(150);
  // 40 blocks into the middle of the chunk holding 100 (it is split), then 120 blocks removed (chunks empty and merge).
  const ins = Array.from({ length: 40 }, (_, k) => ({ op: 'insert', slot: 1000 + k, after: k ? 1000 + k - 1 : 100, kind: 'paragraph', html: `<p>inserted ${k}</p>` }));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: ins }));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 120 }, (_, k) => ({ op: 'remove', slot: 20 + k })).filter(o => o.slot !== edge && o.slot !== edge + 1) }));
  // Chunks are split and joined once the page has been quiet a moment.
  await page.waitForTimeout(1200);
  await settled();
  const shape = await page.evaluate(() => {
    const chunks = [...document.querySelectorAll('#ro-doc > .chunk')];
    const order = [...document.querySelectorAll('#ro-doc .blk')].map(b => +b.dataset.slot);
    return { sizes: chunks.map(c => c.childElementCount), order, top150: Math.round(document.querySelector('.blk[data-slot="150"]').getBoundingClientRect().top) };
  });
  const expected = [];
  for (let i = 1; i <= 300; i++) {
    if (!(i >= 20 && i < 140 && i !== edge && i !== edge + 1)) expected.push(i);
    if (i === 100) for (let k = 0; k < 40; k++) expected.push(1000 + k);
  }
  check('blocks inserted into a full chunk and removed until chunks empty keep their order, chunks neither empty nor past 64, the reader in place',
    JSON.stringify(shape.order) === JSON.stringify(expected) && shape.sizes.every(n => n > 0 && n <= 64) && Math.abs(shape.top150 - before) <= 1,
    JSON.stringify({ sizes: shape.sizes, before, top150: shape.top150, n: shape.order.length }));
}

// An agent writes 40 blocks into a part of a large document the reader has
// read and left (a chunk laid out, skipped since). The page grows by about
// what was written (its estimate) at once (the rail and End count it), and the reader
// scrolling back up through it, 300 px a step, sees the text move by the
// step, not jump by the insert when that chunk is laid out again.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(3000, i => `<p style="min-height:${30 + (i * 13) % 90}px">para ${i}</p>`));
  // Read from the top (the reset keeps the place the last test left).
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  await page.waitForTimeout(300);
  await toTop(150, 200);
  await settled();
  await page.waitForTimeout(300);
  const h0 = await page.evaluate(() => document.scrollingElement.scrollHeight);
  const ins = Array.from({ length: 40 }, (_, k) => ({ op: 'insert', slot: 5000 + k, after: k ? 4999 + k : 20, kind: 'paragraph', html: `<p>new ${k} ${'grow '.repeat(30)}</p>` }));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: ins }));
  await settled();
  await page.waitForTimeout(1500);
  const h1 = await page.evaluate(() => document.scrollingElement.scrollHeight);
  const drift = await page.evaluate(async () => {
    const out = [];
    for (let k = 0; k < 100 && scrollY > 400; k++) {
      const el = document.elementFromPoint(450, 350).closest('.blk');
      const t = el.getBoundingClientRect().top;
      window.scrollBy(0, -300);
      await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
      out.push(Math.round(el.getBoundingClientRect().top - t - 300));
    }
    return out;
  });
  // Written in full: their heights as laid out.
  const written = await page.evaluate(() => { let h = 0; for (let k = 0; k < 40; k++) h += document.querySelector(`.blk[data-slot="${5000 + k}"]`).getBoundingClientRect().height; return Math.round(h); });
  const worst = Math.max(...drift.map(Math.abs));
  check('blocks written into a part read and left: the page grows by about them at once, scrolling back up through it keeps the text in step',
    worst <= 3 && h1 - h0 >= written / 2 && h1 - h0 <= written * 2, JSON.stringify({ grew: h1 - h0, written, worst, drift: drift.filter(Boolean) }));
  // Printed while such a chunk is skipped: it is as tall as its blocks (the height it has on screen until laid out is not printed).
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 20 }, (_, k) => ({ op: 'insert', slot: 6000 + k, after: k ? 5999 + k : 150, kind: 'paragraph', html: `<p>later ${k} ${'grow '.repeat(30)}</p>` })) }));
  await settled();
  const stale = await page.evaluate(() => document.querySelector('.blk[data-slot="6000"]').parentElement.classList.contains('stale'));
  await page.emulateMedia({ media: 'print' });
  const gap = await page.evaluate(() => {
    const c = document.querySelector('.blk[data-slot="6000"]').parentElement;
    return Math.round(c.getBoundingClientRect().height - (c.lastElementChild.getBoundingClientRect().bottom - c.firstElementChild.getBoundingClientRect().top));
  });
  await page.emulateMedia({ media: 'screen' });
  check('a chunk written into while skipped prints as tall as its blocks', stale && Math.abs(gap) <= 40, JSON.stringify({ stale, gap }));
}

// An agent writing a long section into the middle of a large document, 50
// blocks a patch, far from the reader: chunks stay within 64 blocks as it
// writes (the chunk is split where the next block goes in), not one chunk
// of all of them waiting to be split.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(2000));
  let prev = 1000;
  for (let k = 0; k < 400; k += 50) {
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 50 }, (_, j) => { const slot = 9000 + k + j; const o = { op: 'insert', slot, after: prev, kind: 'paragraph', html: `<p>section ${slot}</p>` }; prev = slot; return o; }) }));
  }
  const most = await page.evaluate(() => Math.max(...[...document.querySelectorAll('#ro-doc > .chunk')].map(c => c.childElementCount)));
  const order = await page.evaluate(() => { const b = [...document.querySelectorAll('#ro-doc .blk')].map(e => +e.dataset.slot); const i = b.indexOf(1000); return b[i + 1] === 9000 && b[i + 400] === 9399 && b[i + 401] === 1001; });
  check('a section written into the middle, 50 blocks a patch: no chunk past 64 blocks, in order', most <= 64 && order, JSON.stringify({ most, order }));
}

// Blocks far from the reader removed one by one, in a part read and left
// (its chunk laid out once, skipped since): each leaves a marker after the
// same block. The markers are items of their chunk like any other
// (marks.js: place), so it is split at its limit, not one chunk of a
// hundred and more; the page is as tall as when laid out, and the reader's
// text stays where it is.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(2000, i => `<p style="min-height:${30 + (i * 7) % 50}px">para ${i} lorem ipsum</p>`));
  for (const slot of [1380, 1460, 1540]) {
    await page.evaluate(s => window.readout.scrollToSlot(s), slot);
    await settled();
    await page.waitForTimeout(300);
  }
  await toTop(200);
  await settled();
  await page.waitForTimeout(300);
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  const dels = [];
  for (let k = 0; k < 120; k++) {
    dels.push({ id: 500 + k, after: 1399, count: 1, preview: `para ${1400 + k}` });
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 1400 + k }], deletions: dels }));
    if (k % 10 === 9) await page.evaluate(() => new Promise(r => requestAnimationFrame(r)));
  }
  await settled();
  await page.waitForTimeout(800);   // longer than a quiet page's rebalance
  // The chunks from the one before the markers to the one after them (all laid out once, on the visit).
  const span = () => page.evaluate(() => {
    const chunks = [...document.querySelectorAll('#ro-doc > .chunk')];
    const from = chunks.indexOf(document.querySelector('.blk[data-slot="1399"]').parentElement), to = chunks.indexOf(document.querySelector('.blk[data-slot="1520"]').parentElement);
    return { n: to - from + 1, skipped: chunks.slice(from, to + 1).every(c => !c.classList.contains('near')), height: Math.round(chunks.slice(from, to + 1).reduce((h, c) => h + c.getBoundingClientRect().height, 0)) };
  });
  const r = await page.evaluate(() => ({ most: Math.max(...[...document.querySelectorAll('#ro-doc > .chunk')].map(c => c.childElementCount)),
    marks: document.querySelectorAll('.del-mark').length, anchor: window.readout.captureAnchor() }));
  const skipped = await span();
  // Laid out: scrolled to, the same chunks.
  await page.evaluate(() => window.readout.scrollToSlot(1399));
  await settled();
  await page.waitForTimeout(300);
  const laid = await span();
  check('120 blocks removed one by one after the same block in a skipped chunk: chunks within 64 items, as tall skipped as laid out, the reader still',
    skipped.skipped && r.marks === 120 && r.most <= 64 && Math.abs(skipped.height - laid.height) <= 20 && r.anchor.slot === a0.slot && Math.abs(r.anchor.offset - a0.offset) <= 2,
    JSON.stringify({ ...r, skipped, laid, a0 }));
}

// A block replaced in a part read and left (its chunk laid out once,
// skipped since) by one of a very different height: the chunk's skipped
// size loses the old block's height as laid out, not its estimate
// (chunks.js: counted), so it is about as tall as it lays out, and the
// reader's text stays where it is.
{
  const tall = '<p style="min-height:600px">tall block</p>';
  await page.evaluate(p => window.readout.apply(p), fixReset(2000, i => i === 1400 ? tall : `<p>para ${i} lorem ipsum</p>`));
  for (const slot of [1390, 1420]) {
    await page.evaluate(s => window.readout.scrollToSlot(s), slot);
    await settled();
    await page.waitForTimeout(300);
  }
  await toTop(200);
  await settled();
  await page.waitForTimeout(300);
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 1400, change: 'content', kind: 'paragraph', html: '<p>short now</p>' }] }));
  await settled();
  await page.waitForTimeout(300);
  const chunk = () => page.evaluate(() => { const c = document.querySelector('.blk[data-slot="1400"]').parentElement; return { near: c.classList.contains('near'), height: Math.round(c.getBoundingClientRect().height) }; });
  const skipped = await chunk();
  const a1 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.scrollToSlot(1400));
  await settled();
  await page.waitForTimeout(300);
  const laid = await chunk();
  // Within what the new block's estimate is off by (it is not laid out yet).
  check('a block replaced in a skipped chunk by a much shorter one: the chunk about as tall skipped as laid out, the reader still',
    !skipped.near && laid.near && Math.abs(skipped.height - laid.height) <= 40 && a1.slot === a0.slot && Math.abs(a1.offset - a0.offset) <= 2,
    JSON.stringify({ skipped, laid, a0, a1 }));
}

// A chunk emptied by a removal goes, and the chunks either side meet: a
// heading first in the next one, now right after a rule, starts flush as in
// a document opened that way (chunks.js: dropChunk marks both touched).
{
  const html = i => i === 32 ? '<hr>' : i === 65 ? '<h2>After the rule</h2>' : `<p>para ${i}</p>`;
  const kind = i => i === 32 ? 'rule' : i === 65 ? 'heading' : 'paragraph';
  await page.evaluate(p => window.readout.apply(p), fixReset(120, html, kind));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 31 }, (_, k) => ({ op: 'remove', slot: 33 + k })) }));
  const look = () => page.evaluate(() => {
    const b = s => document.querySelector(`.blk[data-slot="${s}"]`);
    const h = b(65);
    return { alone: b(64)?.parentElement.childElementCount === 1, first: h.previousElementSibling === null, flush: h.classList.contains('h-flush'), mt: getComputedStyle(h.querySelector('h2')).marginTop, gap: Math.round(h.querySelector('h2').getBoundingClientRect().top - b(32).getBoundingClientRect().bottom) };
  });
  const before = await look();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 64 }] }));
  await settled();
  const after = await look();
  // Opened with the same blocks.
  const keep = i => i <= 32 || i >= 65;
  const fresh = fixReset(120, html, kind);
  fresh.ops = fresh.ops.filter(o => keep(o.slot));
  for (let i = 1; i < fresh.ops.length; i++) fresh.ops[i].after = fresh.ops[i - 1].slot;
  await page.evaluate(p => window.readout.apply(p), fresh);
  await settled();
  const opened = await look();
  check('a chunk emptied between a rule and a heading-led chunk: the heading starts as in a document opened that way',
    before.alone && !before.flush && after.first && after.flush === opened.flush && after.mt === opened.mt && after.gap === opened.gap,
    JSON.stringify({ before, after, opened }));
}

// A jump lays out the chunk it lands in, the one after when the screen
// below reaches it, and the one before only when the screen shows some of
// it above the target: a rail tick centring the first block of a chunk does;
// an outline jump to a block lower in its chunk does not (long code there
// would make the jump slower).
{
  const r = fixReset(3000, i => `<p style="min-height:${30 + (i * 13) % 90}px">para ${i}</p>`);
  r.marks = [{ slot: 2017, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  await page.waitForTimeout(300);
  const laid = () => page.evaluate(() => [...document.querySelectorAll('#ro-doc > .chunk')].map((c, i) => c.classList.contains('near') ? i : -1).filter(i => i >= 0));
  const at = s => page.evaluate(s => [...document.querySelectorAll('#ro-doc > .chunk')].indexOf(document.querySelector(`.blk[data-slot="${s}"]`).parentElement), s);
  const first = await page.evaluate(() => document.querySelector('.blk[data-slot="2017"]').previousElementSibling === null);
  // The rail is drawn at most every 250 ms, in a frame (rail.js): its tick, once there.
  const ticked = await until(() => !!document.querySelector('#ro-rail button'), null);
  check('a change far down a large document has its rail tick', ticked);
  const centred = await page.evaluate(() => { document.querySelector('#ro-rail button').click(); return [...document.querySelectorAll('#ro-doc > .chunk')].map((c, i) => c.classList.contains('near') ? i : -1).filter(i => i >= 0); });
  const c2017 = await at(2017);
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  await page.waitForTimeout(300);
  const before = await laid();
  const top = await page.evaluate(() => { window.readout.scrollToSlot(1220); return [...document.querySelectorAll('#ro-doc > .chunk')].map((c, i) => c.classList.contains('near') ? i : -1).filter(i => i >= 0); });
  const c1220 = await at(1220);
  check('a centred jump lays out the chunk before its target; a jump to the top of the window, to a block lower in its chunk, not',
    first && centred.includes(c2017 - 1) && centred.includes(c2017) && !before.includes(c1220 - 1) && top.includes(c1220) && !top.includes(c1220 - 1),
    JSON.stringify({ first, c2017, centred, c1220, top }));
}

// Long code opened at the top: only the code the first screen shows is
// highlighted (its spans are kept, and restyled with every theme switch),
// not every block of the chunks near it, and a block far down a chunk near
// the screen waits until that chunk is laid out.
{
  const code = i => `<div class="code-block" data-lang="js"><pre><code>${Array.from({ length: 90 }, (_, l) => `const v${i}_${l} = f(${l});`).join('\n')}</code></pre></div>`;
  // The first document a page opens (as a window does).
  const p = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  await p.evaluate(x => window.readout.apply(x), fixReset(300, i => i % 10 === 1 ? `<h2>Section ${i}</h2>` : code(i), i => i % 10 === 1 ? 'heading' : 'code'));
  await p.waitForTimeout(1500);
  const lit = await p.evaluate(() => [...document.querySelectorAll('.code-block')].filter(c => c.dataset.hl !== 'pending').map(c => +c.closest('.blk').dataset.slot));
  await p.close();
  check('long code opened at the top: the code within a screen of it highlighted, not the rest of its chunks', lit.length > 0 && lit.every(s => s <= 3), JSON.stringify(lit));
}

// Code is coloured whenever it shows: a long block on the first screen of a
// document opened is highlighted before its first paint (all of it at once:
// only a block ahead of the screen is highlighted a part at a time), and
// while the reader scrolls, every block that comes on screen is already
// highlighted.
{
  const code = (i, n) => `<div class="code-block" data-lang="ts"><pre><code>${Array.from({ length: n }, (_, l) => `export const v${i}_${l}: number = f(${l}); // line ${l}`).join('\n')}</code></pre></div>`;
  const p = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  // Let the grammar load first (a page's first TypeScript), as a window's spare page has it.
  await p.evaluate(x => window.readout.apply(x), fixReset(1, () => code(0, 3), () => 'code'));
  await p.waitForTimeout(1500);
  // Opened: a paragraph, then a 120-line block filling the rest of the screen and beyond, then more.
  const first = await p.evaluate(x => {
    window.readout.apply(x);
    // Before anything is painted: the lines on screen.
    // (A block of more than 40 lines is coloured as far as the screen shows
    // and 120 px more, its rest still plain text, the next lines a
    // slice at a time: enhance.js, showParts.)
    const cb = document.querySelector('.blk[data-slot="2"] .code-block');
    const shown = [...cb.querySelectorAll('pre .line')].filter(l => l.getBoundingClientRect().top < innerHeight);
    const rest = cb.querySelector('pre code').lastChild;
    const plainRest = !cb.querySelector('pre .line') || (rest.nodeType === 3 && rest.length > 1 && (() => { const r = new Range(); r.setStart(rest, 1); r.setEnd(rest, 2); return r.getBoundingClientRect().top < innerHeight; })());
    return { hl: cb.dataset.hl, shown: shown.length, plain: shown.filter(l => !l.querySelector('span[style]')).length, plainRest };
  }, fixReset(300, i => i === 2 ? code(i, 120) : i % 4 === 0 ? code(i, 80) : `<p>para ${i} lorem ipsum dolor</p>`, i => i === 2 || i % 4 === 0 ? 'code' : 'paragraph'));
  // Scrolling 25 px a frame down to 4,500 px (by position, not time: a slow
  // machine scrolls as far): each frame, the code on screen.
  const scrolled = await p.evaluate(async () => {
    // Plain code on screen: a block not coloured at all, or the plain rest of one coloured in part.
    const plainShown = c => {
      if (!c.querySelector('pre .line')) return true;
      const rest = c.querySelector('pre code').lastChild;
      if (rest.nodeType !== 3 || rest.length < 2) return false;
      const r = new Range(); r.setStart(rest, 1); r.setEnd(rest, 2);
      const b = r.getBoundingClientRect();
      return b.top < innerHeight && b.bottom > 0;
    };
    let frames = 0, plain = 0;
    await new Promise(res => { const f = () => { window.scrollBy(0, 25); frames++; for (const c of document.querySelectorAll('.code-block')) { const r = c.getBoundingClientRect(); if (r.bottom > 0 && r.top < innerHeight && c.dataset.hl !== 'done' && plainShown(c)) plain++; } if (scrollY < 4500 && frames < 2000) requestAnimationFrame(f); else res(); }; requestAnimationFrame(f); });
    return { frames, plain, y: Math.round(scrollY) };
  });
  await p.close();
  check('a long code block on the first screen is coloured in the first paint', first.shown > 5 && first.plain === 0 && !first.plainRest, JSON.stringify(first));
  check('while scrolling, every code block that comes on screen is already coloured', scrolled.frames > 60 && scrolled.y > 4000 && scrolled.plain === 0, JSON.stringify(scrolled));
}

// A cold grammar's first part of a long block ahead of the screen cut short
// by Shiki's guard (here a limit of 1 ms after a 300 ms hold, for that one
// part): the block is rechecked once assembled, and ends up right (its first
// line as its fifth, the same text, in the next part).
{
  const p = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    Object.defineProperty(globalThis, 'READOUT_TOKENIZE_LIMIT', { get() {
      if (!window.__cut) return 500;
      window.__cut = false; window.__wasCut = true;
      for (const t = performance.now(); performance.now() - t < 300;);
      return 1;
    } });
  });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  const long = Array.from({ length: 300 }, (_, k) => `local a${k} = b${k} + ${k} * c`).join('; ');
  const lua = `<div class="code-block" data-lang="lua"><pre><code>${[long, 'local p = 1', 'local q = 2', 'local r = 3', long, ...Array.from({ length: 55 }, (_, l) => `local x${l} = f(${l}) -- note`)].join('\n')}</code></pre></div>`;
  const r = await p.evaluate(async x => {
    window.readout.apply(x);
    const cb = document.querySelector('.blk[data-slot="9"] .code-block');
    const states = [];
    // Armed once the grammar is in: the block's first part is the next highlight.
    new MutationObserver(() => { states.push(cb.dataset.hl); if (cb.dataset.hl === 'pending' && !window.__wasCut) window.__cut = true; }).observe(cb, { attributes: true, attributeFilter: ['data-hl'] });
    const onScreen = cb.getBoundingClientRect().top < innerHeight;
    for (let i = 0; i < 400 && !(cb.dataset.hl === 'done' && states.includes('done')); i++) await new Promise(r => setTimeout(r, 25));
    await new Promise(r => setTimeout(r, 300));
    const lines = cb.querySelectorAll('pre .line');
    return { onScreen, cut: !!window.__wasCut, states, final: cb.dataset.hl, same: lines.length > 4 && lines[0].innerHTML === lines[4].innerHTML,
      spans: [lines[0]?.querySelectorAll('span').length, lines[4]?.querySelectorAll('span').length] };
  }, fixReset(20, i => i === 9 ? lua : '<p style="min-height:100px">para</p>', i => i === 9 ? 'code' : 'paragraph'));
  await p.close();
  check('a cold block whose first part was cut short is rechecked once assembled, and ends up right',
    !r.onScreen && r.cut && r.states.includes('recheck') && r.final === 'done' && r.same && r.spans[0] > 100, JSON.stringify(r));
}

// A long block of a cold grammar, every part of it quick, adds up to more
// than the slow limit: it is not highlighted twice (only a part that slow
// is a line cut short). Each clock reading here moves on 5 ms: a part takes
// about 5 ms, the block's 100 parts 500 ms.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(1));
  await page.evaluate(() => window.scrollTo(0, 0));
  const perl = `<div class="code-block" data-lang="perl"><pre><code>${Array.from({ length: 400 }, (_, l) => `my $x${l} = $y + ${l};`).join('\n')}</code></pre></div>`;
  const r = await page.evaluate(async x => {
    const real = performance.now.bind(performance);
    let skew = 0;
    window.readout.apply(x);
    const cb = document.querySelector('.blk[data-slot="9"] .code-block');
    const states = [];
    new MutationObserver(() => {
      states.push(cb.dataset.hl);
      if (cb.dataset.hl === 'pending') performance.now = () => (skew += 5) + real();
    }).observe(cb, { attributes: true, attributeFilter: ['data-hl'] });
    const onScreen = cb.getBoundingClientRect().top < innerHeight;
    for (let i = 0; i < 400 && cb.dataset.hl !== 'done'; i++) await new Promise(r => setTimeout(r, 25));
    performance.now = real;
    await new Promise(r => setTimeout(r, 300));
    return { onScreen, states, final: cb.dataset.hl, colored: !!cb.querySelector('pre.shiki span[style]') };
  }, fixReset(20, i => i === 9 ? perl : '<p style="min-height:100px">para</p>', i => i === 9 ? 'code' : 'paragraph'));
  check('a long cold-grammar block with every part quick is highlighted once, not redone',
    !r.onScreen && r.final === 'done' && !r.states.includes('recheck') && r.colored, JSON.stringify(r));
}

// An agent rewriting a long code block again and again, near the reader and
// far from them (in a chunk skipped, the reader still): lazy work keeps no
// old copy of it (enhance.js: forgetBlock), what it holds stays bounded.
{
  const code = (i, v) => `<div class="code-block" data-lang="ts"><pre><code>${Array.from({ length: 200 }, (_, l) => `export const v${i}_${l}_${v}: number = f(${l}); // ${'x'.repeat(40)}`).join('\n')}</code></pre></div>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(1));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i === 5 || i === 300 ? code(i, 0) : `<p>para ${i} lorem ipsum dolor</p>`, i => i === 5 || i === 300 ? 'code' : 'paragraph'));
  await page.waitForTimeout(800);
  const held = [];
  for (let v = 1; v <= 40; v++) {
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [5, 300].map(slot => ({ op: 'replace', slot, change: 'content', kind: 'code', html: code(slot, v) })) }));
    if (v % 5 === 0) { await page.waitForTimeout(60); held.push(await page.evaluate(() => window.readout.lazyHeld())); }
    else await page.evaluate(() => new Promise(r => requestAnimationFrame(r)));
  }
  await page.waitForTimeout(1000);
  const end = await page.evaluate(() => window.readout.lazyHeld());
  check('a code block rewritten 40 times, near and far: lazy work holds no old copy, and stays bounded',
    held.every(h => h.detached === 0 && h.waiting + h.queued <= 4) && end.detached === 0 && end.waiting + end.queued <= 2, JSON.stringify({ held, end }));
}

// An agent rewriting a diagram on screen while the reader scrolls: each
// rewrite waits for the scroll to pause, and only the last is drawn then;
// the queue holds none that left the page (mermaid.js: gone, pruneQueue).
{
  const mm = v => `<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Rewrite ${v}] --> B[Step ${v}]</pre></div>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(1));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(p => window.readout.apply(p), fixReset(60, i => i === 3 ? mm(0) : `<p>para ${i} ${'lorem ipsum '.repeat(8)}</p>`, i => i === 3 ? 'mermaid' : 'paragraph'));
  await until(() => !!document.querySelector('.blk[data-slot="3"] .mermaid-block.done'), null);
  await page.waitForTimeout(500);
  const d0 = await page.evaluate(() => window.readout.diagramWork().draws);
  // Scrolling a few pixels every 50 ms, the diagram on screen all along.
  await page.evaluate(() => { window.scrollTo(0, 100); let k = 0; window.__jiggle = setInterval(() => window.scrollTo(0, 100 + (k++ % 2) * 3), 50); });
  const held = [];
  for (let v = 1; v <= 8; v++) {
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 3, change: 'content', kind: 'mermaid', html: mm(v) }] }));
    await page.waitForTimeout(550);   // longer than a source's quiet wait (QUIET_MS): each is queued
    held.push(await page.evaluate(() => window.readout.diagramWork()));
  }
  await page.evaluate(() => clearInterval(window.__jiggle));
  const drawn = await until(() => /Rewrite 8/.test(document.querySelector('.blk[data-slot="3"] .mermaid-svg')?.textContent || ''), null);
  await page.waitForTimeout(1500);
  const end = await page.evaluate(() => window.readout.diagramWork());
  check('a diagram rewritten 8 times while scrolling: only the last is drawn once the scroll pauses, and the queue stays bounded',
    drawn && end.draws - d0 === 1 && held.every(h => h.queued <= 1 && h.detached === 0) && end.queued === 0, JSON.stringify({ drawn, draws: end.draws - d0, held, end }));
}

// Pages replaced and emptied in quick succession (resets back to back,
// a run of removals that empties chunks near the screen): nothing the
// observers, the lazy work or the read dwell keep holds an element that
// left the page (chunks.js: lookahead and show, marks.js: forgetMarks,
// enhance.js: forgetBlock).
{
  const mk = n => { const r = fixReset(n, i => i % 7 === 0 ? `<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[N${n}x${i}] --> B</pre></div>` : `<p>para ${i} lorem ipsum</p>`, i => i % 7 === 0 ? 'mermaid' : 'paragraph'); r.marks = Array.from({ length: 12 }, (_, k) => ({ slot: k + 1, kind: 'inserted' })); return r; };
  const samples = [];
  for (let round = 0; round < 12; round++) {
    // Two resets in one task: the first's observer records arrive after its chunks are gone.
    await page.evaluate(([a, b]) => { window.readout.apply(a); window.readout.apply(b); }, [mk(400 + round), mk(420 + round)]);
    // The read dwell armed for the blocks on screen, then the page reset again.
    await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    await page.waitForTimeout(60);
    await page.evaluate(p => window.readout.apply(p), mk(440 + round));
    await page.waitForTimeout(60);
    // Removals emptying the chunks near the screen.
    await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 70 }, (_, k) => ({ op: 'remove', slot: k + 1 })) }));
    await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    await page.waitForTimeout(100);
    samples.push(await page.evaluate(() => window.readout.lazyHeld()));
  }
  const bad = samples.filter(h => h.detached || h.chunksDetached || h.readDetached);
  check('pages reset back to back and emptied near the screen: no observer, lazy queue or read dwell holds an element out of the page',
    bad.length === 0, JSON.stringify({ bad, last: samples.at(-1) }));
}

// An agent streaming one diagram, 200 sources one after the other: the
// drawings kept stay within the cache's 64 (mermaid.js: cacheSet), and the
// last source shown again, after a rewrite and back, is not drawn again.
// (A source is drawn once still for READOUT_DIAGRAM_QUIET_MS, 30 ms here.)
{
  const p = await browser.newPage({ viewport: { width: 900, height: 700 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    globalThis.READOUT_DIAGRAM_QUIET_MS = 30;
    globalThis.READOUT_DIAGRAM_GRACE_MS = 300;
  });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  const mm = v => `<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Stream ${v}] --> B[End]</pre></div>`;
  const drawnAs = v => p.evaluate(v => new Promise(res => { const t0 = performance.now(); const f = () => { const t = document.querySelector('.blk[data-slot="2"] .mermaid-svg')?.textContent || ''; if (t.includes(`Stream ${v}`)) res(true); else if (performance.now() - t0 > 5000) res(false); else setTimeout(f, 10); }; f(); }), v);
  await p.evaluate(x => window.readout.apply(x), fixReset(5, i => i === 2 ? mm(0) : `<p>para ${i}</p>`, i => i === 2 ? 'mermaid' : 'paragraph'));
  let missed = 0, most = 0;
  for (let v = 1; v <= 200; v++) {
    await p.evaluate(x => window.readout.apply(x), fixPatch({ ops: [{ op: 'replace', slot: 2, change: 'content', kind: 'mermaid', html: mm(v) }] }));
    if (!await drawnAs(v)) missed++;
    most = Math.max(most, await p.evaluate(() => window.readout.diagramWork().cached));
  }
  const d0 = await p.evaluate(() => window.readout.diagramWork().draws);
  // A rewrite and straight back, as an undo: the last source from the cache.
  await p.evaluate(x => window.readout.apply(x), fixPatch({ ops: [{ op: 'replace', slot: 2, change: 'content', kind: 'mermaid', html: mm('tmp') }] }));
  await p.evaluate(x => window.readout.apply(x), fixPatch({ ops: [{ op: 'replace', slot: 2, change: 'content', kind: 'mermaid', html: mm(200) }] }));
  const back = await drawnAs(200);
  await p.waitForTimeout(500);
  const end = await p.evaluate(() => window.readout.diagramWork());
  // Left alone (the grace shortened to 300 ms): the drawings no diagram has go, and the sweep stops.
  await p.waitForTimeout(1500);
  const quiet = await p.evaluate(() => window.readout.diagramWork());
  await p.close();
  check('a diagram streamed through 200 sources: at most 64 drawings kept, and the last shown again without drawing',
    missed === 0 && most <= 64 && back && end.draws === d0, JSON.stringify({ missed, most, back, draws: end.draws - d0, cached: end.cached }));
  check('drawings no diagram in the page has are dropped after a while, and the sweep then stops', quiet.cached === 1 && !quiet.sweeping, JSON.stringify(quiet));
}

// ---- The audit of a001270: each case as it was found. ----
// The page's height as it is and with every chunk laid out (none skipped, no stale size).
// (`range`: only the chunks from the one holding the first slot to the one holding the second.)
const bothHeights = (range = null) => page.evaluate(range => {
  const st = document.createElement('style');
  st.textContent = '#ro-doc.cv > .chunk, #ro-doc.cv > .chunk:not(.near), #ro-doc.cv > .chunk.stale:not(.near) { content-visibility: visible !important; height: auto !important; }';
  let list = [...document.querySelectorAll('#ro-doc > .chunk')];
  if (range) { const at = sl => list.indexOf(document.querySelector(`.blk[data-slot="${sl}"]`).parentElement); list = list.slice(at(range[0]), at(range[1]) + 1); }
  const per = () => list.map(c => Math.round(c.getBoundingClientRect().height));
  const skipped = document.scrollingElement.scrollHeight, chunksSkipped = per();
  document.head.appendChild(st);
  const laid = document.scrollingElement.scrollHeight, chunksLaid = per();
  st.remove();
  void document.scrollingElement.scrollHeight;
  const sum = xs => xs.reduce((a, b) => a + b, 0);
  return { skipped, laid, chunks: list.length, spanSkipped: sum(chunksSkipped), spanLaid: sum(chunksLaid), worstChunk: Math.max(0, ...chunksSkipped.map((h, i) => Math.abs(h - chunksLaid[i]))) };
}, range);
const layAllOut = async () => {
  const H = await page.evaluate(() => document.scrollingElement.scrollHeight);
  for (let y = 0; y < H + 2000; y += 500) { await page.evaluate(y => window.scrollTo(0, y), y); await page.waitForTimeout(20); }
  await settled();
};
const heading = (slot, text = 'Section') => `<h2 id="s${slot}">${text}</h2>`;
// 1. A heading first in the next chunk starts flush once the block before
//    it becomes a rule: the patch keeps the reader's place for it once, not
//    once more by the resize observer (+23 px).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(300, i => i === 33 ? heading(i) : `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(4)}</p>`, i => i === 33 ? 'heading' : 'paragraph'));
  await settled();
  for (let k = 0; k < 3; k++) { await toTop(70, 50); await settled(); }
  const t0 = await topOf(70);
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 32, change: 'content', kind: 'rule', html: '<hr>' }] }));
  await settled();
  await page.waitForTimeout(100);
  const r = { flush: await page.evaluate(() => document.querySelector('.blk[data-slot="33"]').classList.contains('h-flush')), moved: (await topOf(70)) - t0 };
  check('a rule written before a heading first in the next chunk: the reader stays put', r.flush && Math.abs(r.moved) <= 1, JSON.stringify(r));
}
// 3. The reader's focus in a chunk an agent writes into, a block at a time:
//    the part with the focus stays, the part before it moves to a chunk of
//    its own (132 items in one chunk before).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(300));
  await settled();
  await page.evaluate(() => { const b = document.querySelector('.blk[data-slot="60"]'); b.tabIndex = -1; b.focus({ preventScroll: true }); window.scrollBy(0, b.getBoundingClientRect().top - 100); });
  await settled();
  let after = 40;
  for (let k = 0; k < 100; k++) { await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot: 2000 + k, after, kind: 'paragraph', html: `<p>new ${k}</p>` }] })); after = 2000 + k; }
  await page.waitForTimeout(800);
  const r = await page.evaluate(() => ({ focus: document.activeElement?.dataset.slot, most: Math.max(...[...document.querySelectorAll('#ro-doc > .chunk')].map(c => c.childElementCount)),
    order: [...document.querySelectorAll('#ro-doc .blk')].map(e => +e.dataset.slot).slice(39, 42).join() }));
  await page.evaluate(() => document.activeElement?.blur());
  check('100 blocks written one by one into the chunk holding the focus: the focus stays, no chunk past 64', r.focus === '60' && r.most <= 64 && r.order === '40,2000,2001', JSON.stringify(r));
}
// 4a. A removal marker between a rule and the heading after it, read and
//     gone (markAllRead): the heading starts flush again.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(300, i => i === 32 ? '<hr>' : i === 33 ? heading(i) : `<p>para ${i}</p>`, i => i === 32 ? 'rule' : i === 33 ? 'heading' : 'paragraph'));
  await settled();
  const flush = () => page.evaluate(() => { const h = document.querySelector('.blk[data-slot="33"]'); return { flush: h.classList.contains('h-flush'), mt: getComputedStyle(h.querySelector('h2')).marginTop }; });
  const initial = await flush();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 5 }], deletions: [{ id: 1, after: 32, count: 1, preview: 'gone' }] }));
  await settled();
  const marked = await flush();
  await page.evaluate(() => window.readout.markAllRead());
  await page.waitForTimeout(1200);
  const gone = { ...(await flush()), marks: await page.evaluate(() => document.querySelectorAll('.del-mark').length) };
  check('a marker between a rule and a heading, read and gone: the heading starts flush again', initial.flush && !marked.flush && gone.marks === 0 && gone.flush && gone.mt === '0px', JSON.stringify({ initial, marked, gone }));
}
// 4b. A heading's flush start changing in a chunk laid out and skipped: the
//     chunk's skipped size changes with it (23 px off before).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(300, i => i === 31 ? '<hr>' : i === 33 ? heading(i) : `<p>para ${i} ${'lorem ipsum '.repeat(8)}</p>`, i => i === 31 ? 'rule' : i === 33 ? 'heading' : 'paragraph'));
  await settled();
  await layAllOut();
  const before = await bothHeights();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'remove', slot: 32 }] }));
  await settled();
  const r = { before, after: await bothHeights(), flush: await page.evaluate(() => document.querySelector('.blk[data-slot="33"]').classList.contains('h-flush')),
    skipped: await page.evaluate(() => !document.querySelector('.blk[data-slot="33"]').parentElement.classList.contains('near')) };
  check('a heading starting flush in a chunk laid out and skipped: as tall skipped as laid out', r.flush && r.skipped && before.skipped === before.laid && Math.abs(r.after.skipped - r.after.laid) <= 2, JSON.stringify(r));
}
// 5. A patch taking a page laid out without content-visibility past 250
//    blocks: its chunks are skipped at the sizes they were laid out at, not
//    their estimates (-1,509 px before).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(240));
  await settled();
  await layAllOut();
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  const cv0 = await page.evaluate(() => document.getElementById('ro-doc').classList.contains('cv'));
  let after = 170;
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 20 }, (_, k) => { const o = { op: 'insert', slot: 1000 + k, after, kind: 'paragraph', html: `<p>${'inserted text that is fairly long '.repeat(30)}</p>` }; after = 1000 + k; return o; }) }));
  await settled();
  const r = { cv0, cv: await page.evaluate(() => document.getElementById('ro-doc').classList.contains('cv')), ...(await bothHeights()) };
  check('a patch taking the page past 250 blocks: as tall skipped as laid out', !cv0 && r.cv && Math.abs(r.skipped - r.laid) <= 2, JSON.stringify(r));
}
// 6. A wide table in a skipped chunk is measured as it comes within two
//    screens (with its chunk), not once it is on screen (drawn unmeasured, then reflowed).
{
  const words = ['Implementation', 'Responsibility', 'Configuration', 'Documentation', 'Compatibility', 'Infrastructure', 'Observability', 'Accountability'];
  const table = `<div class="table-wrap"><table><thead><tr>${words.map(w => `<th>${w}</th>`).join('')}</tr></thead><tbody><tr>${words.map(w => `<td>${w}</td>`).join('')}</tr></tbody></table></div>`;
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i === 200 ? table : `<p>para ${i}</p>`, i => i === 200 ? 'table' : 'paragraph'));
  await settled();
  // The table a screen and a half below the window.
  await page.evaluate(() => { const b = document.querySelector('.blk[data-slot="200"]').parentElement; window.scrollTo(0, b.getBoundingClientRect().top + scrollY - 2.5 * innerHeight); });
  await settled();
  await page.waitForTimeout(300);
  await settled();
  const r = await page.evaluate(() => { const t = document.querySelector('.blk[data-slot="200"] .table-wrap'); const r = t.getBoundingClientRect(); return { below: Math.round(r.top - innerHeight), measured: t.classList.contains('scrolls') || !!t.parentElement.style.getPropertyValue('--tb-w') }; });
  check('a wide table two screens ahead is measured before it comes on screen', r.below > 0 && r.measured, JSON.stringify(r));
}
// 7. A link jump lands on code: it is coloured in the first frame that shows it.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i === 1 ? '<p><a href="#far">to far</a></p>' : i === 300 ? '<h2 id="far">Far</h2>' : i > 300 && i < 306 ? `<div class="code-block" data-lang="json"><pre><code>{\n  "k": ${i}\n}</code></pre></div>` : `<p>para ${i}</p>`,
    i => i === 300 ? 'heading' : i > 300 && i < 306 ? 'code' : 'paragraph'));
  await settled();
  await page.waitForTimeout(800);   // JSON's grammar in
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  const r = await page.evaluate(() => new Promise(res => {
    document.querySelector('a[href="#far"]').click();
    const cbs = [...document.querySelectorAll('.blk[data-slot="301"] .code-block, .blk[data-slot="302"] .code-block')];
    requestAnimationFrame(() => res(cbs.map(cb => [cb.dataset.hl, Math.round(cb.getBoundingClientRect().top)])));
  }));
  check('code a link jump lands on is coloured in its first frame', r.length === 2 && r.every(([hl, top]) => hl === 'done' && top < 700), JSON.stringify(r));
}
// 7b. An outline jump into a page of long code blocks, the window toolbar
//     over its top: the frame that shows the landing has every line on
//     screen coloured, under the toolbar too (blocks of more than 40 lines
//     coloured only as far as the screen shows: enhance.js, showParts).
{
  const code = i => `<div class="code-block" data-lang="json"><pre><code>${Array.from({ length: 90 }, (_, l) => `{ "k${i}_${l}": [${l}, true, "v"] },`).join('\n')}</code></pre></div>`;
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i % 10 === 1 ? `<h2 id="j${i}">Part ${i}</h2>` : code(i), i => i % 10 === 1 ? 'heading' : 'code'));
  await settled();
  await page.waitForTimeout(800);
  const out = [];
  for (const slot of [121, 211, 301]) {
    await page.evaluate(() => window.scrollTo(0, 0));
    await settled();
    const plainNow = () => page.evaluate(() => new Promise(res => requestAnimationFrame(() => {
      let plain = 0;
      for (const cb of document.querySelectorAll('.code-block')) {
        const r = cb.getBoundingClientRect();
        if (r.bottom <= 0 || r.top >= innerHeight) continue;
        if (!cb.querySelector('pre .line')) { plain++; continue; }
        for (const l of cb.querySelectorAll('pre .line')) { const b = l.getBoundingClientRect(); if (b.bottom > 0 && b.top < innerHeight && l.textContent.trim() && !l.querySelector('span[style]')) plain++; }
        const rest = cb.querySelector('pre code').lastChild;
        if (rest.nodeType === 3 && rest.length > 1) { const g = new Range(); g.setStart(rest, 1); g.setEnd(rest, 2); const b = g.getBoundingClientRect(); if (b.top < innerHeight && b.bottom > 0) plain++; }
      }
      res(plain);
    })));
    out.push(await page.evaluate(slot => new Promise(res => {
      window.readout.scrollToSlot(slot);
      requestAnimationFrame(() => {
        let plain = 0;
        for (const cb of document.querySelectorAll('.code-block')) {
          const r = cb.getBoundingClientRect();
          if (r.bottom <= 0 || r.top >= innerHeight) continue;
          if (!cb.querySelector('pre .line')) { plain++; continue; }
          for (const l of cb.querySelectorAll('pre .line')) { const b = l.getBoundingClientRect(); if (b.bottom > 0 && b.top < innerHeight && l.textContent.trim() && !l.querySelector('span[style]')) plain++; }
          const rest = cb.querySelector('pre code').lastChild;
          if (rest.nodeType === 3 && rest.length > 1) { const g = new Range(); g.setStart(rest, 1); g.setEnd(rest, 2); const b = g.getBoundingClientRect(); if (b.top < innerHeight && b.bottom > 0) plain++; }
        }
        res({ slot, plain });
      });
    }), slot));
    // Then at once a screen down (Page Down), and another: the frames that show them.
    for (let k = 0; k < 2; k++) { await page.evaluate(() => window.scrollBy(0, innerHeight - 40)); out.at(-1)[`down${k}`] = await plainNow(); }
    await page.waitForTimeout(300);
  }
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check('an outline jump into long code blocks: every line on screen coloured in its first frame, under the toolbar too, and a screen down at once after it', out.every(o => o.plain === 0 && o.down0 === 0 && o.down1 === 0), JSON.stringify(out));
}
// 8. Scrolls of more than a screen at once (the scrollbar dragged, End,
//    Home, a page down): the frame that shows the landing has the chunks
//    on screen laid out, none skipped (blank) or at a stale size, and
//    nothing moves after it.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(3000, i => `<p>para ${i} ${'lorem ipsum dolor '.repeat(1 + i % 7)}</p>`));
  await settled();
  // A part read and left, then written into (its chunk stale).
  await page.evaluate(() => window.readout.scrollToSlot(1500));
  await settled();
  await page.waitForTimeout(300);
  await page.evaluate(() => window.scrollTo(0, 0));
  await settled();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [1, 2, 3].map(k => ({ op: 'insert', slot: 9000 + k, after: 1505 + k, kind: 'paragraph', html: `<p>written ${k}</p>` })) }));
  await settled();
  const stale = await page.evaluate(() => document.querySelector('.blk[data-slot="1506"]').parentElement.classList.contains('stale'));
  const land = how => page.evaluate(how => new Promise(res => {
    const H = document.scrollingElement.scrollHeight;
    if (how === 'stale') { const c = document.querySelector('.blk[data-slot="1506"]').parentElement; window.scrollTo(0, c.getBoundingClientRect().top + scrollY - 100); }
    else if (how === 'end') window.scrollTo(0, H);
    else if (how === 'home') window.scrollTo(0, 0);
    else if (how === 'pagedown') window.scrollBy(0, innerHeight * 0.9);
    else window.scrollTo(0, H * how);
    // In the frame (before it is laid out): the chunks on screen are laid
    // out (near). After it is painted: where the text there is.
    requestAnimationFrame(() => {
      const on = [...document.querySelectorAll('#ro-doc > .chunk')].filter(c => { const r = c.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight; });
      const skipped = on.filter(c => !c.classList.contains('near')).length;
      setTimeout(() => {
        const el = document.elementFromPoint(450, 350)?.closest('.blk');
        res({ how, skipped, slot: el?.dataset.slot, top: el?.getBoundingClientRect().top });
      }, 0);
    });
  }), how);
  const out = [];
  for (const how of [0.2, 0.4, 0.6, 0.8, 'stale', 'end', 'home', 'pagedown', 0.5]) {
    const r = await land(how);
    await settled();
    await page.waitForTimeout(100);
    r.moved = r.slot ? Math.round(await page.evaluate(sl => document.querySelector(`.blk[data-slot="${sl}"]`).getBoundingClientRect().top, r.slot) - r.top) : null;
    out.push(r);
  }
  check('scrolls of more than a screen at once: the landing frame shows its chunks laid out, and nothing moves after',
    stale && out.every(r => r.skipped === 0 && r.slot && (r.how === 'end' || Math.abs(r.moved) <= 1)), JSON.stringify({ stale, out }));
}
// 9. A code block an agent streams into, on screen, growing past the
//    chunk's height: the chunk is split once the page is quiet (one chunk of 22,199 px before).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(300));
  await settled();
  await toTop(40, 50);
  await settled();
  const code = n => `<div class="code-block" data-lang="text"><pre><code>${Array.from({ length: n }, (_, i) => 'line ' + i).join('\n')}</code></pre></div>`;
  for (const n of [50, 200, 500, 1000]) await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'replace', slot: 45, change: 'content', kind: 'code', html: code(n) }] }));
  await page.waitForTimeout(3000);
  const r = await page.evaluate(() => { const c = document.querySelector('.blk[data-slot="45"]').parentElement; return { items: c.childElementCount, overfull: window.readout.lazyHeld().overfull }; });
  check('a code block streamed past its chunk\'s height: the chunk is split', r.items === 1 && r.overfull === 0, JSON.stringify(r));
}
// P3. A chunk laid out and skipped, split by blocks written into it: each
//     part skipped at what its blocks were laid out at (the written blocks
//     made exactly as tall as they are estimated).
{
  await page.evaluate(p => window.readout.apply(p), fixReset(400));
  await settled();
  await page.evaluate(() => window.readout.scrollToSlot(210));
  await settled();
  await page.waitForTimeout(300);
  await toTop(30);
  await settled();
  const exact = k => { let h = 100; for (let i = 0; i < 3; i++) { const html = `<p style="height:${h}px;margin:0;overflow:hidden">written ${k} ${'x'.repeat(40)}</p>`; h = 30 + Math.ceil(html.length / 75) * 26; } return `<p style="height:${h}px;margin:0;overflow:hidden">written ${k} ${'x'.repeat(40)}</p>`; };
  // The chunk written into was laid out by the visit (at a height other than its estimate) and is skipped now.
  const was = await page.evaluate(() => { const c = document.querySelector('.blk[data-slot="205"]').parentElement; return { near: c.classList.contains('near'), laid: Math.round(c.getBoundingClientRect().height) !== parseInt(c.style.containIntrinsicSize.replace('auto ', '')) }; });
  let after = 205;
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: Array.from({ length: 40 }, (_, k) => { const o = { op: 'insert', slot: 7000 + k, after, kind: 'paragraph', html: exact(k) }; after = 7000 + k; return o; }) }));
  await settled();
  // Only the parts of that chunk (from the one holding block 205 to the one
  // holding 224, its last): a chunk beside it the visit did not lay out is
  // at its estimate, as any such chunk is.
  const r = { was, ...(await bothHeights([205, 224])) };
  check('a skipped chunk split by blocks written into it: each part as tall skipped as laid out', !was.near && was.laid && r.chunks >= 2 && Math.abs(r.spanSkipped - r.spanLaid) <= 2 && r.worstChunk <= 2, JSON.stringify(r));
}
// P3. Markers in a document with no block: in the order sent.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(0));
  await page.evaluate(p => window.readout.apply(p), fixPatch({ deletions: [1, 2, 3].map(id => ({ id, after: 0, count: 1, preview: `gone ${id}` })) }));
  const order = await page.evaluate(() => [...document.querySelectorAll('.del-mark')].map(m => m.dataset.del).join());
  check('removal markers in an empty document keep the order sent', order === '1,2,3', order);
}

// Long code: a chunk holds about four screens' estimate, not 32 code blocks
// (a theme change, a jump or find would lay all of them out), and one huge
// block is a chunk of its own, the blocks around it in chunks of their own.
{
  const code = (i, n) => `<div class="code-block" data-lang="js"><pre><code>${Array.from({ length: n }, (_, l) => `const v${i}_${l} = f(${l});`).join('\n')}</code></pre></div>`;
  const kinds = i => i === 150 ? 'code' : i > 300 ? 'code' : 'paragraph';
  await page.evaluate(p => window.readout.apply(p), fixReset(400, i => i === 150 ? code(i, 3000) : i > 300 ? code(i, 90) : `<p>para ${i} lorem ipsum dolor</p>`, kinds));
  const shape = await page.evaluate(() => {
    const b = s => document.querySelector(`.blk[data-slot="${s}"]`);
    const alone = b(150).parentElement.childElementCount === 1 && b(149).parentElement !== b(150).parentElement && b(151).parentElement !== b(150).parentElement;
    const codeChunks = [...document.querySelectorAll('#ro-doc > .chunk')].filter(c => +c.firstElementChild.dataset.slot > 300).map(c => c.childElementCount);
    return { alone, most: Math.max(...codeChunks) };
  });
  check('a huge code block is a chunk of its own; long code blocks are two or three a chunk', shape.alone && shape.most <= 3, JSON.stringify(shape));
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

// Font size and window size (which sizes the column) reflow every block: the reader keeps their place.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(100));
  await toTop(80);
  await settled();
  const a0 = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 20 }));
  const sync = await page.evaluate(() => window.readout.captureAnchor());
  await page.waitForTimeout(500);
  const font = await page.evaluate(() => window.readout.captureAnchor());
  await page.setViewportSize({ width: 560, height: 700 });
  await page.waitForTimeout(600);
  const narrow = await page.evaluate(() => window.readout.captureAnchor());
  await page.setViewportSize({ width: 900, height: 700 });
  await page.waitForTimeout(600);
  const back = await page.evaluate(() => window.readout.captureAnchor());
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 16 }));
  const restored = await page.evaluate(() => window.readout.captureAnchor());
  const steps = [sync, font, narrow, back, restored].map(a => a.slot);
  check('font size and window resize keep the reading position',
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

// Printing: preparePrint draws diagrams and highlights code far from the viewport.
{
  const mm = '<div class="mermaid-block"><pre class="mermaid-src">graph TD\n  A[Print] --> B[Me]</pre></div>';
  const code = '<div class="code-block" data-lang="js"><pre><code>const far = 1;</code></pre></div>';
  const r = fixReset(300, i => i === 280 ? mm : i === 290 ? code : `<p>para ${i}</p>`, i => i === 280 ? 'mermaid' : i === 290 ? 'code' : 'paragraph');
  r.marks = [{ slot: 50, kind: 'inserted' }];
  await page.evaluate(p => window.readout.apply(p), r);
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
    // A drawing's colors are in its markup and the page's sheet of its rules (mermaid.js: data-mmd).
    const d = b.querySelector('.mermaid-svg svg'), rules = d?.dataset.mmd ? [...document.querySelectorAll('head style')].filter(x => x.textContent.includes(`[data-mmd="${d.dataset.mmd}"]`)).map(x => x.textContent).join('') : '';
    const svg = ((d?.outerHTML || '') + rules).toLowerCase();
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
    // Its rules: in the page's sheet for them (mermaid.js), none in the drawing.
    const styled = svgs.every(svg => !svg.querySelector('style') && !!svg.dataset.mmd && [...document.querySelectorAll('head style')].some(x => x.textContent.includes(`[data-mmd="${svg.dataset.mmd}"]`)));
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
    // A drawing's colors are in its markup and the page's sheet of its rules (mermaid.js: data-mmd).
    const d = b.querySelector('.mermaid-svg svg'), rules = d?.dataset.mmd ? [...document.querySelectorAll('head style')].filter(x => x.textContent.includes(`[data-mmd="${d.dataset.mmd}"]`)).map(x => x.textContent).join('') : '';
    const svg = ((d?.outerHTML || '') + rules).toLowerCase();
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

// Font size, find mode and window size reflow the page: a
// reader following the end stays at the end, and goes on following.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(40));
  await toEnd();
  await page.waitForTimeout(300);
  const gaps = {};
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 19 }));
  await page.waitForTimeout(300);
  gaps.font = await gapToEnd();
  await page.setViewportSize({ width: 640, height: 700 });
  await page.waitForTimeout(600);
  gaps.resize = await gapToEnd();
  await page.evaluate(p => window.readout.apply(p), fixPatch({ ops: [{ op: 'insert', slot: 41, after: 40, html: `<p>${'appended live tail text '.repeat(40)}</p>`, kind: 'paragraph' }] }));
  gaps.append = await gapToEnd();
  await page.setViewportSize({ width: 900, height: 700 });
  await page.waitForTimeout(600);
  gaps.back = await gapToEnd();
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 16 }));
  await page.waitForTimeout(300);
  gaps.restored = await gapToEnd();
  check('font size and window resize keep a following reader at the end',
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
    const b = [...document.querySelectorAll('#ro-doc > .chunk > .blk')].find(e => e.getBoundingClientRect().bottom > 8);
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

// Headings are named by their text (3.9 E9: no link button beside them any more).
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
  await page.evaluate(() => {
    document.querySelector('.remote-img[data-src="https://badge.example/b.svg"]').dataset.remoteId = 'rb';
    window.readout.remoteReady({ id: 'rb', url: 'data:image/gif;base64,R0lGODlhAQABAAAAACw=' });
  });
  const loaded = await page.getByRole('heading', { name: 'Build Green', exact: true }).count();
  check('a heading is named by its content alone', named === 3 && loaded === 1, JSON.stringify({ named, loaded }));
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

// While the reader scrolls through a large document, blocks resize (laid
// out as they come near, images and diagrams arriving): the rail is redrawn a
// few times a second, not every frame, and its last state is drawn. Chunks
// lay their blocks out a few at a time, so a block on screen also grows by a
// pixel every frame: a resize in every frame, as per-block layout gave.
{
  const r = fixReset(400, i => `<p>para ${i} ${'lorem ipsum dolor sit amet '.repeat(1 + (i * 7) % 13)}</p>`);
  r.marks = Array.from({ length: 40 }, (_, i) => ({ slot: 5 + i * 10, kind: 'inserted' }));
  await page.evaluate(p => window.readout.apply(p), r);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(400);
  const r2 = await page.evaluate(() => new Promise(resolve => {
    const rail = document.getElementById('ro-rail');
    let rebuilds = 0, resizes = 0, frames = 0, grown = 0;
    const mo = new MutationObserver(recs => { for (const rec of recs) if (rec.removedNodes.length) rebuilds++; });
    mo.observe(rail, { childList: true });
    const ro = new ResizeObserver(() => { resizes++; });
    for (const b of document.querySelectorAll('#ro-doc > .chunk > .blk')) ro.observe(b);
    const start = performance.now();
    const step = () => {
      window.scrollBy(0, 120);
      frames++;
      const grow = document.elementFromPoint(400, 400)?.closest('.blk');
      if (grow) grown++;
      if (grow) grow.style.minHeight = `${grow.getBoundingClientRect().height + 1}px`;
      if (performance.now() - start < 1500) requestAnimationFrame(step);
      else setTimeout(() => { mo.disconnect(); ro.disconnect(); resolve({ rebuilds, resizes, frames, grown, ticks: rail.children.length }); }, 500);
    };
    requestAnimationFrame(step);
  }));
  const unread = await page.evaluate(() => document.querySelectorAll('#ro-doc > .chunk > .blk.m-inserted:not(.m-read)').length);
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
    // A drawing's colors are in its markup and the page's sheet of its rules (mermaid.js: data-mmd).
    const d = b.querySelector('.mermaid-svg svg'), rules = d?.dataset.mmd ? [...document.querySelectorAll('head style')].filter(x => x.textContent.includes(`[data-mmd="${d.dataset.mmd}"]`)).map(x => x.textContent).join('') : '';
    const svg = ((d?.outerHTML || '') + rules).toLowerCase();
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
  await short.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16, topInset: 80 }));
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

// The app sends the page only what it reads (RenderPatch.Page): no outline,
// task counts or title. A whole document and an update without them apply.
{
  const n0 = await page.evaluate(() => window.__msgs.filter(m => m.type === 'applied').length);
  const reset = resetPatch(3, 'page-only');
  delete reset.toc; delete reset.tasks;
  reset.version = 300;
  await page.evaluate(p => window.readout.apply(p), reset);
  await page.evaluate(p => window.readout.apply(p), {
    version: 301, reset: false, rewrite: false,
    ops: [{ op: 'insert', slot: 4, after: 3, html: '<p>page-only 4</p>', kind: 'paragraph', cjk: false }],
    marks: [{ slot: 4, kind: 'inserted' }], deletions: [],
  });
  const texts = await page.evaluate(() => [...document.querySelectorAll('.blk')].map(e => e.textContent.trim()));
  const applied = await page.evaluate(() => window.__msgs.filter(m => m.type === 'applied').length);
  check('a patch without outline, task counts and title applies',
    JSON.stringify(texts) === JSON.stringify(['page-only 1', 'page-only 2', 'page-only 3', 'page-only 4']) && applied - n0 === 2,
    JSON.stringify({ texts, applied: applied - n0 }));
}

// Every suite shares the one filter: WebKit's ResizeObserver loop notice is
// not a page error (it decided whether a run failed by how frames fell).
check('a ResizeObserver loop notice is not a page error, anything else is',
  benign('ResizeObserver loop completed with undelivered notifications.') && !benign('TypeError: undefined is not an object'));
// Drawing diagrams adds no style sheet to the page and takes none out
// (mermaid.js): either makes WebKit restyle the whole document, seconds in a
// 5 MB one. Two flowcharts and a sequence diagram: their rules go into the
// page's sheets for them, one per kind of drawing, added once.
{
  await page.evaluate(p => window.readout.apply(p), fixReset(3));
  await page.waitForTimeout(300);
  const sheets = await page.evaluate(async p => {
    const added = [], removed = [];
    const isSheet = n => n.nodeName.toLowerCase() === 'style' || (n.querySelectorAll && n.querySelectorAll('style').length > 0);
    const mo = new MutationObserver(rs => { for (const r of rs) { for (const n of r.addedNodes) if (isSheet(n)) added.push(r.target.nodeName); for (const n of r.removedNodes) if (isSheet(n)) removed.push(r.target.nodeName); } });
    mo.observe(document, { subtree: true, childList: true });
    window.readout.apply(p);
    for (let i = 0; i < 500 && document.querySelectorAll('.mermaid-block.done').length < 3; i++) await new Promise(r => setTimeout(r, 20));
    await new Promise(r => setTimeout(r, 50));
    mo.disconnect();
    return { done: document.querySelectorAll('.mermaid-block.done').length, inDrawings: document.querySelectorAll('.mermaid-svg style').length, added, removed };
  }, fixPatch({ ops: [
    ['flowchart LR\n  A[One] --> B[Two]', 'flowchart TD\n  C[Three] --> D[Four]', 'sequenceDiagram\n  Alice->>Bob: Hi'].map((src, k) => ({ op: 'insert', slot: 900 + k, after: k ? 899 + k : 3, kind: 'mermaid', html: `<div class="mermaid-block"><pre class="mermaid-src">${src}</pre></div>` })) ].flat() }));
  check('drawing diagrams adds no style sheet to the page beyond one per kind, and takes none out',
    sheets.done === 3 && sheets.inDrawings === 0 && sheets.removed.length === 0 && sheets.added.every(t => t === 'HEAD') && sheets.added.length <= 2, JSON.stringify(sheets));
}

// Two diagrams defining the same class name (classDef) differently keep
// their own colours, and a drawing's shared sheet is named by its rules, not
// by the order drawings finished in (a page draws the same every time).
{
  const diagram = (slot, after, color) => ({ op: 'insert', slot, after, kind: 'mermaid', html: `<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A${slot}[Node ${slot}]:::hot --> B${slot}[Other]\n  classDef hot fill:${color}</pre></div>` });
  // Each in a page of its own (a page keeps the sheets it made).
  const drawn = async ops => {
    const p = await browser.newPage({ viewport: { width: 900, height: 700 } });
    collectPageErrors(p, errors);
    await p.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
    await p.goto(`${base}/reader.html`);
    await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
    await p.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
    await p.evaluate(x => window.readout.apply(x), { ...fixReset(1), ops: [...fixReset(1).ops, ...ops] });
    for (let i = 0; i < 300 && await p.evaluate(() => document.querySelectorAll('.mermaid-block.done').length < 2); i++) await p.waitForTimeout(50);
    const r = await p.evaluate(() => Object.fromEntries([...document.querySelectorAll('.mermaid-block')].map(b => {
      const svg = b.querySelector('svg'), shape = svg?.querySelector('.node.hot rect, .node.hot polygon, .node.hot path');
      return [b.closest('.blk').dataset.slot, { fill: shape && getComputedStyle(shape).fill, sheet: svg?.dataset.mmd }];
    })));
    await p.close();
    return r;
  };
  const one = await drawn([diagram(950, 1, '#ff0000'), diagram(951, 950, '#0000ff')]);
  const two = await drawn([diagram(951, 1, '#0000ff'), diagram(950, 951, '#ff0000')]);
  check('two diagrams with the same classDef name keep their own colours; their sheets are named the same whichever is drawn first',
    one[950]?.fill === 'rgb(255, 0, 0)' && one[951]?.fill === 'rgb(0, 0, 255)' && two[950]?.fill === 'rgb(255, 0, 0)' && two[951]?.fill === 'rgb(0, 0, 255)'
    && one[950].sheet !== one[951].sheet && one[950].sheet === two[950].sheet && one[951].sheet === two[951].sheet, JSON.stringify({ one, two }));
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
