// Per-block enhancement after a block's HTML is set: code tools (its
// highlighting: code.js), table overflow, remote-image placeholders, heading
// links, math. Expensive work (highlighting, in a worker; diagrams) runs
// lazily near the viewport.
import * as hl from '../highlight.js';
import { doc, root, strings, post, inViewport, prevItem, nextItem, WIDE } from './core.js';
import { keepPlace } from './anchor.js';
import { waitingForChunk, skippedChunk } from './chunks.js';
import { setupCode, keepColours, keptIn, forgetCode, askedBlocks, takeFresh, askOnScreen, newDocument } from './code.js';
import { hold, drop, shown, waits, pending, isCode, holdFirst, shownAnew, unpainted } from './holds.js';
import { setupRemoteImage } from './remote.js';
import { renderMath, typesetting } from './math.js';
import { renderMermaid, setupMermaid, sweepLater, placeCached } from './mermaid.js';

export function enhance(el) {
  hl.stopWarmUp();   // a document is shown: its own blocks load what they need
  const old = keptIn(el);
  [...el.querySelectorAll('.code-block')].forEach((cb, i) => { if (addTools(cb)) setupCode(cb, old?.[i]); });
  for (const t of el.querySelectorAll('.table-wrap')) { setupTable(t); queueTable(t); }
  for (const r of el.querySelectorAll('.remote-img')) setupRemoteImage(r);
  for (const m of el.querySelectorAll('.mermaid-block')) { setupMermaid(m); diagrams.add(m); }
  if (el.querySelector('.math, .math-block')) renderMath(el);
  for (const img of el.querySelectorAll('img')) if (!img.complete && !(img.getAttribute('width') && img.getAttribute('height'))) { images.push(img); sizeless = true; }
  setLang(el);
  markCjkEmphasis(el);
  markCodeBeforePunct(el);
}

// Inline code right before full-width punctuation (`results/` 。): the
// punctuation's glyph already brings its own space, which the code's padding
// doubled into a gap. Such code keeps only a sliver of padding on that side
// (reader.css: code.before-punct).
const FULLWIDTH_PUNCT = /^[、。，．：；！？）］｝」』】〕〗〙〛》〉]/;
const INLINE = 'a, strong, b, em, i, del, s, mark, u, span';
function markCodeBeforePunct(el) {
  for (const code of el.querySelectorAll('code')) {
    if (code.closest('pre')) continue;
    let node = code;
    while (!node.nextSibling && node.parentElement !== el && node.parentElement?.matches(INLINE)) node = node.parentElement;
    const next = node.nextSibling;
    code.classList.toggle('before-punct', !!next && next.nodeType === Node.TEXT_NODE && FULLWIDTH_PUNCT.test(next.data));
  }
}

// Han characters take Japanese forms in a block with kana, Chinese otherwise
// (the page itself is lang="en", which leaves the choice to the font).
const KANA = /[\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9f]/;
const HAN = /[\u3400-\u9fff\uf900-\ufaff]/;
function setLang(el) {
  const text = el.textContent;
  const lang = KANA.test(text) ? 'ja' : HAN.test(text) ? 'zh' : null;
  if (lang) el.lang = lang; else el.removeAttribute('lang');
}

// Emphasis that is mostly CJK (at least as many CJK characters as Latin
// letters) is upright and takes emphasis dots instead of a slant (reader.css:
// em.cjk-em). The dots are drawn by CSS, one per Han, kana or Hangul
// character, each in a span of its own (.em-dot): never on punctuation
// (clreq, jlreq), outside the line box (text-emphasis made the line taller),
// and never part of copied text. A long run (more than 20 such characters,
// or a whole paragraph) takes a slightly heavier weight instead: a line of
// dots under a whole sentence is noise, not emphasis (.cjk-em-long).
const CJK_CHARS = /[぀-ヿㇰ-ㇿｦ-ﾟ㐀-鿿豈-﫿가-힯]/g;
const LATIN_LETTERS = /[A-Za-zÀ-ɏ]/g;
const DOTTED = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]/u;
const DOTTED_ALL = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]/gu;
const LONG_EMPHASIS = 20;
function markCjkEmphasis(el) {
  for (const em of el.querySelectorAll('em')) {
    if (em.classList.contains('cjk-em') || em.classList.contains('cjk-em-long')) continue;
    const text = em.textContent;
    const cjk = (text.match(CJK_CHARS) || []).length;
    if (!cjk || cjk < (text.match(LATIN_LETTERS) || []).length) continue;
    const dotted = (text.match(DOTTED_ALL) || []).length;
    const para = em.parentElement.closest('p, li, td, th, h1, h2, h3, h4, h5, h6');
    const whole = para && para.textContent.trim() === text.trim();
    if (dotted > LONG_EMPHASIS || whole) { em.classList.add('cjk-em-long'); continue; }
    em.classList.add('cjk-em');
    const walker = document.createTreeWalker(em, NodeFilter.SHOW_TEXT);
    const nodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (DOTTED.test(n.data) && !n.parentElement.closest('code, kbd, samp, .katex, .math')) nodes.push(n);
    }
    for (const n of nodes) {
      const frag = document.createDocumentFragment();
      let plain = '';
      for (const ch of n.data) {
        if (!DOTTED.test(ch)) { plain += ch; continue; }
        if (plain) { frag.append(plain); plain = ''; }
        const dot = document.createElement('span');
        dot.className = 'em-dot';
        dot.textContent = ch;
        frag.append(dot);
      }
      if (plain) frag.append(plain);
      n.replaceWith(frag);
    }
  }
}

// Table cells. A short cell (16 columns or fewer, a CJK character counting
// two) and a short identifier in code (32 characters or fewer) stay on one
// line while the column has room: "S1 / GREEN" or `actions/configure-pages`
// broken in two read badly. A longer one may break after a slash (a <wbr>
// the page adds, here only: a path in a cell would otherwise squeeze the
// column of sentences beside it). Only while the table fits that way: one
// they would push past the column wraps them again, and scrolls only if it
// is still too wide (measureTables).
function columns(s) {
  let n = 0;
  for (const ch of s) n += WIDE.test(ch) ? 2 : 1;
  return n;
}

// Not so many that they starve a column of sentences: the columns' longest
// kept lines together take at most NW_ROOM characters (a little over half
// the column at the table's size, 42.5 em), else the column of the longest
// identifiers wraps them as any text. Counted, not measured:
// no layout, and the same in any window.
const NW_ROOM = 40;
function setupTable(t) {
  const kept = [];      // per column: its longest kept line, and its kept code
  let prose = false;    // a cell of words wider than a kept one
  for (const row of t.querySelectorAll('tr')) {
    let i = 0;
    for (const cell of row.children) {
      const col = kept[i] ??= { most: 0, codes: [] };
      i += cell.colSpan || 1;
      const n = columns(cell.textContent.trim());
      if (n && n <= 16 && !cell.querySelector('br')) { cell.dataset.nw = ''; col.most = Math.max(col.most, n); continue; }
      let codes = 0;
      for (const c of cell.querySelectorAll('code')) {
        const len = c.textContent.length;
        if (len > 32) { breakAfterSlashes(c); continue; }
        c.dataset.nw = '';
        col.codes.push(c);
        col.most = Math.max(col.most, len);
        codes += len;
      }
      if (n > codes + 16) prose = true;
    }
  }
  if (!prose) return;
  let room = kept.reduce((s, c) => s + c.most, 0);
  for (const col of kept.filter(c => c.codes.length).sort((a, b) => b.most - a.most)) {
    if (room <= NW_ROOM) break;
    for (const c of col.codes) delete c.dataset.nw;
    room -= col.most;
  }
}

function breakAfterSlashes(el) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  const nodes = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.data.includes('/')) nodes.push(n);
  for (const n of nodes) {
    const frag = document.createDocumentFragment();
    n.data.split('/').forEach((part, i, all) => {
      if (part) frag.append(part);
      if (i < all.length - 1) frag.append('/', document.createElement('wbr'));
    });
    n.replaceWith(frag);
  }
}

/**
 * A table wider than the column scrolls sideways (and pins its first column);
 * one of its own block widens into the margin first when the window has room
 * (reader.css). A scrolling table takes its natural width, so it is measured
 * without the class: otherwise one that scrolled once would never fit again.
 * Short cells stay on one line only while the table fits that way, widened
 * or not: otherwise they wrap again (.nw-off), and the table scrolls only if
 * it is still too wide. Writes and reads alternate per step, never per table:
 * the page lays out twice, and twice more when a table had to wrap again.
 */
export function measureTables(tables = doc.querySelectorAll('.table-wrap')) {
  // A table in a chunk content-visibility skips is measured when it comes
  // on screen (skippedTables): asked now, WebKit would lay the chunk out to
  // answer, every such chunk once.
  const list = [];
  for (const t of tables) {
    if (!t.isConnected) continue;
    if (t.checkVisibility({ contentVisibilityAuto: true })) list.push(t); else skippedTables.observe(t);
  }
  for (const t of list) t.classList.remove('scrolls', 'nw-off');
  const wide = list.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of wide) t.classList.add('scrolls');
  // How far a table of its own block widens: its width, read once it takes it.
  const own = wide.filter(t => t.parentElement.matches('#ro-doc > .chunk > .blk.k-table'));
  const widths = own.map(t => t.firstElementChild.getBoundingClientRect().width);
  // (Set only when it changed: a style change on a block makes WebKit lay out
  // a large document's skipped blocks again.)
  own.forEach((t, i) => {
    const w = `${Math.ceil(widths[i])}px`;
    if (t.parentElement.style.getPropertyValue('--tb-w') !== w) t.parentElement.style.setProperty('--tb-w', w);
  });
  const retry = wide.filter(t => t.scrollWidth > t.clientWidth + 1 && t.querySelector('[data-nw], th'));
  if (!retry.length) return;
  for (const t of retry) t.classList.replace('scrolls', 'nw-off');
  const still = retry.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of still) t.classList.replace('nw-off', 'scrolls');
}

/**
 * Tables in chunks not laid out, measured as they come within two screens
 * (as their chunk is laid out ahead), so one is not drawn unmeasured and
 * then reflowed on screen; their chunk laid out by then (not all at once, laid out for the moment: 1 MB,
 * 66 tables, ~1 s).
 */
const skippedTables = new IntersectionObserver(entries => {
  const shown = [];
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    skippedTables.unobserve(e.target);
    // Its chunk still skipped (WebKit places its content at its top until
    // a frame lays it out): asked again in the next frame.
    if (e.target.checkVisibility({ contentVisibilityAuto: true })) shown.push(e.target);
    else requestAnimationFrame(() => { if (e.target.isConnected) skippedTables.observe(e.target); });
  }
  if (shown.length) measureTables(shown);
}, { rootMargin: '200% 0px' });   // the lookahead's (chunks.js): measured before it is on screen

/**
 * `el` (a block) is replaced, removed or reset away: nothing of its keeps
 * watching or waiting (its tables, its code and diagrams for lazy work),
 * so an agent rewriting a block keeps no old copy of it alive.
 */
export function forgetBlock(el) {
  keepColours(el);
  for (const t of el.querySelectorAll('.table-wrap')) skippedTables.unobserve(t);
  for (const x of el.querySelectorAll('.code-block, .mermaid-block')) {
    lazyObserver.unobserve(x);
    if (isCode(x)) forgetCode(x);
    waitingForChunk.delete(x);
    if (diagrams.delete(x)) sweepLater();   // a diagram gone: its drawing kept a while, then dropped
    shown(x);
    const i = queue.indexOf(x);
    if (i >= 0) queue.splice(i, 1);
  }
}

/** What lazy work holds on to (a test checks it stays bounded). */
export function lazyHeld() {
  const asked = askedBlocks();
  const held = [...waitingForChunk.keys(), ...queue, ...diagrams, ...asked];
  return { waiting: waitingForChunk.size, queued: queue.length + asked.size, diagrams: diagrams.size, detached: held.filter(x => !x.isConnected).length };
}

// New tables are measured together, in the next frame.
const queuedTables = new Set();
function queueTable(t) {
  if (!queuedTables.size) requestAnimationFrame(() => { const list = [...queuedTables]; queuedTables.clear(); measureTables(list); });
  queuedTables.add(t);
}

// The window width decides which tables scroll.
let tablesQueued = false;
window.addEventListener('resize', () => {
  if (tablesQueued) return;
  tablesQueued = true;
  requestAnimationFrame(() => { tablesQueued = false; measureTables(); });
});

/**
 * Code wrapping is one choice for every code block, remembered by the app.
 * Wrapping reflows the page, so the reading position is kept.
 */
export function setCodeWrap(on) {
  if ((root.dataset.codeWrap === 'on') === on) return;
  // The block read may be code: its place is kept as a share of it.
  keepPlace(() => { root.dataset.codeWrap = on ? 'on' : 'off'; }, { ratio: true });
}

function toggleCodeWrap() {
  const on = root.dataset.codeWrap !== 'on';
  setCodeWrap(on);
  post({ type: 'setCodeWrap', on });
}

/** Re-labels the code blocks' buttons after the strings change. */
export function relabelButtons() {
  for (const w of doc.querySelectorAll('.cb-wrap')) {
    setLabel(w, strings.wrap || w.dataset.label);
    w.title = strings.wrapTitle || w.title;
  }
  for (const c of doc.querySelectorAll('.cb-copy')) setLabel(c, strings.copy || c.dataset.label);
}

/**
 * Control labels are CSS generated content (see reader.css), so a selection
 * across a code block never copies "Copy", "Wrap" or the language.
 */
function setLabel(el, text) {
  el.dataset.label = text;
  if (el.tagName === 'BUTTON') el.setAttribute('aria-label', text);
}

/** Its tools (language, Wrap, Copy) added to code block `cb`; false: it has them already. */
function addTools(cb) {
  if (cb.querySelector('.cb-tools')) return false;
  const tools = document.createElement('div');
  tools.className = 'cb-tools';
  if (cb.dataset.lang) {
    const lang = document.createElement('span');
    lang.className = 'cb-lang';
    lang.dataset.label = cb.dataset.lang;
    lang.setAttribute('aria-hidden', 'true');
    tools.appendChild(lang);
  }
  const wrap = document.createElement('button');
  wrap.className = 'cb-wrap';
  wrap.type = 'button';
  setLabel(wrap, strings.wrap || 'Wrap');
  wrap.title = strings.wrapTitle || 'Wrap long lines in code blocks';
  wrap.addEventListener('click', ev => {
    ev.stopPropagation();
    toggleCodeWrap();
  });
  tools.appendChild(wrap);
  const btn = document.createElement('button');
  btn.className = 'cb-copy';
  btn.type = 'button';
  setLabel(btn, strings.copy || 'Copy');
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    const code = cb.querySelector('pre').innerText.replace(/\n$/, '');
    post({ type: 'copy', text: code });
    setLabel(btn, strings.copied || 'Copied');
    setTimeout(() => setLabel(btn, strings.copy || 'Copy'), 1400);
  });
  tools.appendChild(btn);
  cb.appendChild(tools);
  return true;
}

const isDiagram = x => x.classList.contains('mermaid-block');

// Diagrams and images a landing shows (a first paint, a jump) not drawn or
// loaded yet are not waited for: Mermaid's load and layout, or an image's
// load, take up to seconds. A diagram shows its source until it is drawn
// (when it would be anyway, lazyObserver: once the page is still; one drawn
// before, in the cache, is put in at once); an image without its size (a
// local one has it from ReadoutCore) a box for a picture (reader.css:
// .reserved). Drawn or loaded, each takes its own size at once, the
// reader's place kept (grows): what is below it moves down, once; the text
// they are on does not.
const landedOn = new WeakMap();   // what a landing showed not drawn or loaded yet -> the block it landed on (null: the top)
const finished = x => isDiagram(x) ? x.classList.contains('done') || !!x.querySelector('.mermaid-error') : x.complete;
/** The diagrams and images in `xs` not drawn or loaded (a landing on `at`): marked, an image given its box. */
function reserve(xs, at = null) {
  for (const x of xs) {
    if (landedOn.has(x) || !x.isConnected || finished(x)) continue;
    if (isDiagram(x)) {
      if (!x.dataset.waiting && !placeCached(x)) landedOn.set(x, at);
      continue;
    }
    if (x.getAttribute('width') && x.getAttribute('height')) continue;
    landedOn.set(x, at);
    x.classList.add('reserved');
    for (const type of ['load', 'error']) x.addEventListener(type, () => grows(x, () => x.classList.remove('reserved')), { once: true });
  }
}
/**
 * `change` (a diagram's drawing put in, mermaid.js; an image loaded): to
 * one a landing showed, with the reader's place kept (anchor.js: keepPlace):
 * the block the landing put them on, while it is on screen, else the block
 * at the top, stays where it is; what is on its far side moves.
 */
export function grows(x, change) {
  if (!landedOn.has(x)) return change();
  const at = landedOn.get(x);
  landedOn.delete(x);
  const r = at?.isConnected ? at.getBoundingClientRect() : null;
  if (r && r.bottom > 0 && r.top < innerHeight) keepPlace(change, { anchor: { slot: +at.dataset.slot, offset: -r.top, ratio: 0 } });
  else keepPlace(change);
}
const toReserve = blocks => blocks.flatMap(b => [...b.querySelectorAll('.mermaid-block, img')]);

/**
 * A jump about to scroll by `off()` (aimAt): whether it waits for the code
 * (the math) it would show, `again` called then (its diagrams and images
 * are not waited for: reserve). Before
 * a document shown anew has been painted (its place restored), or while
 * its first paint waits, it is hidden: what the jump shows waits with it,
 * and the jump goes now.
 */
export function holdJump(el, off, again) {
  cancelJump();
  const blk = el.closest('#ro-doc > .chunk > .blk');
  if (!blk) return false;
  const d = off();
  const shows = e => { const r = e.getBoundingClientRect(); return r.bottom - d > 0 && r.top - d < innerHeight; };
  const blocks = [blk];
  for (let e = prevItem(blk); e; e = prevItem(e)) { if (!e.classList.contains('blk')) continue; if (!shows(e)) break; blocks.unshift(e); }
  for (let e = nextItem(blk); e; e = nextItem(e)) { if (!e.classList.contains('blk')) continue; if (!shows(e)) break; blocks.push(e); }
  if (diagrams.size || sizeless) reserve(toReserve(blocks), blk);
  // (Its code not before the highlighter has started, as a first paint's:
  // the first window at launch lands at once, its code plain first.)
  const cbs = pending(blocks).filter(x => hl.started || !isCode(x));
  if (!cbs.length) return false;
  if (unpainted()) { holdFirst(cbs, d); return false; }
  jumpHold = hold(cbs, () => { jumpHold = null; again(); }, d);
  return !!jumpHold;
}
let jumpHold = null;
function cancelJump() { drop(jumpHold); jumpHold = null; }
// The reader taking over (as aimAt ends a jump) drops a jump still waiting.
for (const type of ['wheel', 'keydown', 'mousedown', 'touchstart']) window.addEventListener(type, cancelJump, { capture: true, passive: true });

// Lazy work is triggered for anything near the viewport: code within four
// screens is asked for (code.js), a diagram within one is drawn a turn
// after the next frame. One in a chunk content-visibility skips waits for
// the chunk to be laid out (chunks.js: waitingForChunk).
export const lazyObserver = new IntersectionObserver(entries => {
  for (const el of waitingForChunk.keys()) if (!el.isConnected) waitingForChunk.delete(el);
  for (const e of entries) {
    if (!e.target.isConnected) { waitingForChunk.delete(e.target); lazyObserver.unobserve(e.target); continue; }
    if (!e.isIntersecting) { waitingForChunk.delete(e.target); continue; }
    if (skippedChunk(e.target)) { waitingForChunk.set(e.target, lazyObserver); continue; }
    waitingForChunk.delete(e.target);
    lazyObserver.unobserve(e.target);
    queue.push(e.target);
  }
  pump();
}, { rootMargin: '100% 0px 100% 0px' });

const SLICE_MS = 6;
const queue = [];
let pumping = false;

// A turn after each frame (not one task after another: the frames between
// them would wait), or after 50 ms when no frame comes (a window not shown).
function pump() {
  if (pumping || !queue.length) return;
  pumping = true;
  let done = false;
  const turn = () => {
    if (done) return;
    done = true;
    pumping = false;
    const start = performance.now();
    let n = 0;
    // At least one a turn, however slow the clock says it is.
    while (queue.length && (n++ === 0 || performance.now() - start < SLICE_MS)) {
      const el = queue.shift();
      if (el.isConnected) renderMermaid(el);
    }
    pump();
  };
  requestAnimationFrame(() => setTimeout(turn, 0));
  setTimeout(turn, 50);
}

/**
 * `near`: whether a code block counts as on screen (a first open estimates
 * it without layout); `first`: a document shown anew (a reset): its first
 * paint waits for that code.
 */
export function renderLazy(near = inViewport, first = false) {
  if (first) newDocument();
  const imgs = images;
  images = [];
  const onScreen = takeFresh(near);
  // (A first open estimating what is on screen reads no layout: as much
  // of each block as a screen could show, lines of at least 18 px.)
  const upto = near === inViewport ? undefined : Math.ceil((innerHeight + 120) / 18);
  if (first) {
    shownAnew();
    // Its math on screen too (its diagrams and images: reserve).
    // (Its code not before the highlighter has started: the first window at
    // launch shows its code plain first, as before, rather than wait for that.)
    if (diagrams.size || imgs.length) reserve([...diagrams, ...imgs].filter(x => x.isConnected && near(x)));
    const later = typesetting.size ? [...typesetting].filter(x => x.isConnected && waits(x) && near(x)) : [];
    holdFirst(hl.started ? [...onScreen, ...later] : later, 0, upto);
  }
  if (!first || !hl.started) for (const cb of onScreen) askOnScreen(cb, upto);
  // The page's diagrams, without a search of the whole page in every patch.
  for (const m of diagrams) {
    if (!m.isConnected) { diagrams.delete(m); continue; }
    if (!m.classList.contains('done') && !m.classList.contains('busy') && !m.dataset.waiting) lazyObserver.observe(m);
  }
}
let images = [];   // images set up since the last renderLazy(), still loading, their size not given
let sizeless = false;   // the page has had such an image (a jump looks for them only then)
const diagrams = new Set();   // every diagram block set up (enhance), until it leaves the page
