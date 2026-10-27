// Chunks: the page's items (blocks, removal markers) in groups of about
// CHUNK, so a large document's content-visibility is decided for a few
// hundred elements instead of every block. WebKit lays out a skipped element
// only once it touches the viewport, and checks every such element in every
// frame that scrolls (5 MB of blocks: tens of milliseconds a frame, and each
// block blank for the frame it came on screen in). Chunks within two screens
// of the viewport are laid out ahead (`near`), so what scrolls in is drawn.
import { doc, heights, isChunk } from './core.js';
import { resizeObserver } from './anchor.js';
import { nearChunk, renderLazy } from './enhance.js';

const CHUNK = 32;   // items a chunk is filled to as blocks arrive in order
const SPAN = 4000;  // or estimated px (about four screens): long code is two or three blocks a chunk, a huge block one of its own
const MAX = 64;     // a chunk with more items (or twice SPAN) is split where the next item goes in
const full = c => c.childElementCount >= CHUNK || estimateOf(c) >= SPAN;
const overfull = c => c.childElementCount > 1 && (c.childElementCount > MAX || estimateOf(c) > 2 * SPAN);
const sparse = c => c.childElementCount < CHUNK / 4 && estimateOf(c) < SPAN / 4;

/** Each item's estimated height, until a chunk is laid out (its size is their sum). */
const estimates = new WeakMap();
const chunkEstimates = new WeakMap();
/** Chunks seen at a size other than their estimate: laid out at least once. */
export const laidOut = new WeakSet();

export const cv = () => doc.classList.contains('cv');
export const chunkOf = el => el.parentElement;
export const estimateOf = c => chunkEstimates.get(c) || 0;
/** An item's estimated height (what its chunk's estimate sums). */
export const itemEstimate = el => estimates.get(el) || 0;
/** Whether WebKit has laid `c` out yet, in a large document (it is at its estimated height). */
export const neverLaidOut = c => cv() && !laidOut.has(c) && heights.get(c) === estimateOf(c);

// Laid out ahead of the viewport (class near, reader.css): content-visibility
// decides only for the element touching it, and that one would show blank
// for a frame.
const near = new Set();
const lookahead = new IntersectionObserver(entries => {
  for (const e of entries) {
    // A record queued for a chunk dropped since (dropChunk): not kept.
    if (!e.target.isConnected) { near.delete(e.target); continue; }
    if (e.isIntersecting) near.add(e.target); else near.delete(e.target);
    show(e.target);
    // Split or joined once laid out (rebalance).
    if (e.isIntersecting && (overfull(e.target) || sparse(e.target))) uneven(e.target);
  }
}, { rootMargin: '200% 0px' });
const forced = new Set();
function show(c) {
  if (!c.isConnected) { near.delete(c); forced.delete(c); return; }
  const on = near.has(c) || forced.has(c);
  if (on) mount(c);
  if (on === c.classList.contains('near')) return;
  c.classList.toggle('near', on);
  if (on) nearChunk(c); else queuePark(c);
  // Laid out from now on at its size, remembered when it is skipped again (account).
  if (on && stale.delete(c)) { c.classList.remove('stale'); c.style.removeProperty('--stale'); }
}

// A scroll of more than a screen at once (the scrollbar dragged, Home, End,
// Page Down past the lookahead) lands past what the lookahead laid out, and
// its records arrive after the frame that shows the landing: that frame
// would show the chunks there skipped (blank) or at a stale size. The
// scroll event comes before the frame is laid out: the chunks on screen are
// laid out from it, and the ones beside them (forceLayout: so nothing above
// moves after), found by their boxes (a skipped chunk's box needs no layout
// of its blocks) halving the list. A smaller scroll costs a compare.
// Not a jump of the page's own (aimAt): it laid out what it lands on, and
// laying out more there made the jump's frame 270 ms slower (scrolledTo).
let scrolledFrom = 0;
/** A jump of the page's own laid out what it lands on (aimAt): its scroll is not one to do it for. */
export function scrolledTo() { scrolledFrom = document.scrollingElement.scrollTop; }
window.addEventListener('scroll', () => {
  const y = document.scrollingElement.scrollTop;
  const far = Math.abs(y - scrolledFrom) > window.innerHeight;
  scrolledFrom = y;
  if (!far || !cv()) return;
  const cs = doc.children;
  let lo = 0, hi = cs.length - 1;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (cs[mid].getBoundingClientRect().bottom > 0) hi = mid; else lo = mid + 1; }
  for (let i = lo; i < cs.length; i++) {
    const c = cs[i];
    if (c.getBoundingClientRect().top >= window.innerHeight) break;
    if (isChunk(c)) forceLayout(c);
  }
}, { passive: true });

/**
 * The chunk of `el` (or chunk `el`) laid out now, whatever content-visibility
 * would skip, once a frame renders it: a jump's target, a place restored,
 * new blocks at the end a following reader goes to (WebKit lays a skipped
 * chunk out in the frame, not when asked: until then it places its blocks at
 * its top). Kept for two frames, then for as long as it is near the screen.
 * `room`: how much of the screen will show above `el` (a jump centring it).
 */
export function forceLayout(el, room = 0) {
  const pc = parkedIn.get(el);
  if (pc) mount(pc);
  const c = isChunk(el) ? el : el.closest('#ro-doc > .chunk');
  // Near the screen already: it is laid out, and so are its neighbours.
  if (!cv() || !isChunk(c) || c.classList.contains('near')) return;
  // The chunks before and after it, when what the screen shows above `el`
  // (room) or two screens below it reach into them by its items' estimates:
  // a target centred, or near its chunk's end. A chunk on screen is never
  // contained (its paint would clip what blocks draw past the gutters, wide
  // code and tables). Not otherwise: laying out long code there would make
  // the jump slower (what the window toolbar covers above a target at the
  // top is laid out in the next frame, as the chunk comes near).
  const item = el === c ? null : el.closest('#ro-doc > .chunk > *');
  let above = 0, below = 0;
  if (item) {
    for (let e = item.previousElementSibling; e && above < room; e = e.previousElementSibling) above += estimates.get(e) || 0;
    for (let e = item; e && below < 2 * innerHeight; e = e.nextElementSibling) below += estimates.get(e) || 0;
  }
  const around = [!item || above < room ? c.previousElementSibling : null, c, !item || below < 2 * innerHeight ? c.nextElementSibling : null];
  for (const x of around) {
    if (!isChunk(x) || forced.has(x) || x.classList.contains('near')) continue;
    forced.add(x);
    show(x);
    requestAnimationFrame(() => requestAnimationFrame(() => { forced.delete(x); show(x); }));
  }
}

/**
 * Where `el` is on screen, without laying out a chunk content-visibility
 * skips (WebKit would lay its blocks out to answer, in every frame that
 * asks): in a skipped chunk, its share of the chunk's box by its place
 * among the chunk's items.
 */
export function roughRect(el) {
  const pc = parkedIn.get(el);
  if (pc) {
    const r = pc.getBoundingClientRect(), items = parkedItems.get(pc), n = items.length;
    const i = items.indexOf(el);
    const top = r.top + r.height * i / n, height = r.height / n;
    return { top, bottom: top + height, height, left: r.left, right: r.right, width: r.width };
  }
  const c = el.parentElement;
  if (!cv() || !isChunk(c) || el.checkVisibility({ contentVisibilityAuto: true })) return el.getBoundingClientRect();
  const r = c.getBoundingClientRect(), n = c.childElementCount;
  const i = Array.prototype.indexOf.call(c.children, el);
  const top = r.top + r.height * i / n, height = r.height / n;
  return { top, bottom: top + height, height, left: r.left, right: r.right, width: r.width };
}

function makeChunk() {
  const c = document.createElement('div');
  c.className = 'chunk';
  chunkEstimates.set(c, 0);
  touched.add(c);
  resizeObserver.observe(c);
  lookahead.observe(c);
  return c;
}

function dropChunk(c) {
  // The chunks either side now meet: a heading first in the next one may
  // gain or lose its flush start (flushStarts).
  for (const x of [c.previousElementSibling, c.nextElementSibling]) if (isChunk(x)) touched.add(x);
  touched.delete(c);
  stale.delete(c);
  unevenChunks.delete(c);
  forgetParked(c);
  resizeObserver.unobserve(c);
  lookahead.unobserve(c);
  near.delete(c);
  forced.delete(c);
  c.remove();
}

// A chunk never laid out is as tall as its items' estimates; one laid out
// keeps the size it was last laid out at (contain-intrinsic-size: auto).
// One laid out and skipped since whose items change (an agent writing in a
// part the reader has read) is that size and the change's estimate, until it
// is laid out again: the page's height, the rail and End count them.
// The chunks a patch changed (patch.js takes their sizes afterwards, so the
// resize observer does not count what the patch itself keeps the place for).
export const touched = new Set();
const stale = new Map();   // chunk -> the size it is skipped at
function account(c, d, seen = d) {
  touched.add(c);
  if (!d && !seen) return;
  const est = estimateOf(c) + d;
  chunkEstimates.set(c, est);
  if (!laidOut.has(c)) c.style.containIntrinsicSize = `auto ${est}px`;
  else if (cv() && !c.classList.contains('near')) {
    // Its height set (reader.css: stale): WebKit does not lay a skipped
    // element out again for a new contain-intrinsic-size.
    const size = Math.max(0, (stale.get(c) ?? heights.get(c) ?? est) + seen);
    stale.set(c, size);
    c.style.setProperty('--stale', `${size}px`);
    c.classList.add('stale');
  }
}

/**
 * Puts `el` after item `after` (null: first in the document), estimated `est`
 * px tall. A block estimated at SPAN or more is a chunk of its own.
 */
export function place(el, after, est = 0) {
  let c = after ? chunkOf(after) : doc.firstElementChild;
  if (!isChunk(c)) { c = makeChunk(); doc.prepend(c); }
  const big = est >= SPAN;
  // In the middle of a chunk at its limit (an agent writing a section in the
  // middle), or a big block there: the chunk is split after `after` (split).
  if (after?.nextElementSibling && (big || c.childElementCount >= MAX || estimateOf(c) + est > 2 * SPAN)) { split(c, after); c = chunkOf(after); }
  const n = c.childElementCount;
  if (after && !after.nextElementSibling && n && (big || full(c))) {
    // After a full chunk's last item (an agent writing on): the next chunk, if it has room, else a new one.
    const next = c.nextElementSibling;
    if (!big && isChunk(next) && !parkedItems.has(next) && !full(next) && estimateOf(next) + est <= SPAN) { c = next; after = null; }
    else { const fresh = makeChunk(); c.after(fresh); c = fresh; after = null; }
  } else if (!after && n && (big || n >= MAX || estimateOf(c) + est > 2 * SPAN || estimates.get(c.firstElementChild) >= SPAN)) {
    // First in the document, before a chunk at its limit or a big block.
    const fresh = makeChunk(); c.before(fresh); c = fresh;
  }
  if (after) after.after(el); else c.prepend(el);
  estimates.set(el, est);
  account(c, est);
  // Not split (in use): when the page is quiet.
  if (overfull(c)) uneven(c);
}

/**
 * Chunk `c` split after `after`: the items after it into a new chunk after
 * `c`; when they hold the focus, the selection or a find mark (they must not
 * move), the items up to `after` into a new chunk before it instead. Neither
 * when both do.
 */
function split(c, after) {
  const tail = [];
  for (let e = after.nextElementSibling; e; e = e.nextElementSibling) tail.push(e);
  if (!tail.length) return;
  if (!holds(tail[0], tail.at(-1))) { moveOut(c, tail, false); return; }
  const head = [];
  for (let e = c.firstElementChild; e && e !== tail[0]; e = e.nextElementSibling) head.push(e);
  if (!holds(head[0], head.at(-1))) { moveOut(c, head, true); return; }
  // Both hold something (the focus on one side, a selection on the other):
  // the larger of the free ends moves out, the items before the first that
  // holds or after the last. What is written between them stays in the
  // chunk until they let go (the rebalance splits it then).
  const items = [...c.children];
  const held = items.map(e => holds(e, e));
  const first = held.indexOf(true), last = held.lastIndexOf(true);
  const before = items.slice(0, first), after_ = items.slice(last + 1);
  if (before.length >= after_.length && before.length) moveOut(c, before, true);
  else if (after_.length) moveOut(c, after_, false);
}
/** `items` of chunk `c` into a new chunk before or after it, each counting what it counted in `c`. */
function moveOut(c, items, before) {
  const fresh = makeChunk();
  fresh.classList.toggle('near', c.classList.contains('near'));
  if (before) c.before(fresh); else c.after(fresh);
  // Out of a chunk laid out and skipped since: the new one is skipped at
  // what they count for there (their heights as laid out), as `c` was.
  const skipped = laidOut.has(c) && cv() && !c.classList.contains('near');
  let d = 0, seen = 0;
  for (const e of items) { d += estimates.get(e) || 0; seen += counted(c, e); }
  fresh.append(...items);
  account(c, -d, -seen);
  if (skipped) { laidOut.add(fresh); stale.set(fresh, 0); }
  account(fresh, d, seen);
}

/** Puts `el` last in the document. */
export function placeLast(el, est = 0) {
  let c = doc.lastElementChild;
  while (c && !isChunk(c)) c = c.previousElementSibling;
  place(el, c ? c.lastElementChild : null, est);
}

// What an item counts for in its chunk's skipped size: in a chunk laid out
// and skipped since, its height as last laid out when known (that size holds
// it), else its estimate.
const counted = (c, el) => laidOut.has(c) && heights.has(el) ? heights.get(el) : (estimates.get(el) || 0);

/** Its estimate changed (new content). */
export function reestimate(el, est) {
  const c = chunkOf(el);
  const was = estimates.get(el) || 0, seen = counted(c, el);
  estimates.set(el, est);
  account(c, est - was, est - seen);
  // A block grown past the chunk's limit (an agent streaming long code into it): split when the page is quiet.
  if (overfull(c)) uneven(c);
}

/**
 * Takes `el` out of the document. An emptied chunk goes; one left with few
 * items joins a neighbour when the page is quiet.
 */
export function unplace(el) {
  const c = chunkOf(el);
  el.remove();
  if (!isChunk(c)) return;
  account(c, -(estimates.get(el) || 0), -counted(c, el));
  const n = c.childElementCount;
  if (!n) return dropChunk(c);
  if (sparse(c)) uneven(c);
}

// Splitting a chunk grown past MAX and joining one left with few items move
// blocks from one chunk to another, which would take the reader's selection,
// caret or focus, and find's marks, with them: never while a patch applies.
// Done when the page has been quiet a moment, only for chunks laid out (the
// page then lays out the same), none holding the selection, the focus or a
// find mark (they wait, and are done once they no longer do).
const unevenChunks = new Set();
let rebalanceTimer = null;
function uneven(c) {
  unevenChunks.add(c);
  clearTimeout(rebalanceTimer);
  rebalanceTimer = setTimeout(rebalance, 600);
}
function inUse(c) {
  return (cv() && !c.classList.contains('near')) || holds(c.firstElementChild, c.lastElementChild);
}
/** Whether the items `first` to `last` hold the focus, the selection or one of find's marks. */
function holds(first, last) {
  if (!first) return false;
  const span = new Range();
  span.setStartBefore(first);
  span.setEndAfter(last);
  const inside = n => !!n && span.comparePoint(n, 0) === 0 && n !== first.parentNode;
  if (document.activeElement !== document.body && inside(document.activeElement)) return true;
  const sel = getSelection();
  for (let i = 0; sel && i < sel.rangeCount; i++) {
    const r = sel.getRangeAt(i);
    if (span.comparePoint(r.endContainer, r.endOffset) >= 0 && span.comparePoint(r.startContainer, r.startOffset) <= 0) return true;
  }
  // Find's marks (static ranges: moved, they would point at nothing).
  if (typeof CSS !== 'undefined' && CSS.highlights) for (const name of ['ro-find', 'ro-find-cur']) {
    for (const r of CSS.highlights.get(name) || []) if (inside(r.startContainer) || inside(r.endContainer)) return true;
  }
  return false;
}
function rebalance() {
  rebalanceTimer = null;
  const done = [];
  // Its size as the resize observer last reported it: not one it has yet to
  // report (a change it has not made up for, which taking it here would lose).
  const reported = c => Math.abs(c.getBoundingClientRect().height - (heights.get(c) ?? -1)) < 0.5;
  for (const c of unevenChunks) {
    if (!c.isConnected) { unevenChunks.delete(c); continue; }
    // Skipped: done once it is laid out again (lookahead).
    if (cv() && !c.classList.contains('near')) { unevenChunks.delete(c); continue; }
    const n = c.childElementCount;
    if (overfull(c)) {
      if (inUse(c) || !reported(c)) continue;
      // Into chunks of CHUNK items or SPAN px, the first keeping its place.
      const items = [...c.children], parts = [[]];
      let px = 0;
      for (const e of items) {
        const est = estimates.get(e) || 0;
        if (parts.at(-1).length && (parts.at(-1).length >= CHUNK || px >= SPAN || px + est > 2 * SPAN || est >= SPAN)) { parts.push([]); px = 0; }
        parts.at(-1).push(e);
        px += est;
      }
      let at = c;
      for (const part of parts.slice(1)) {
        const fresh = makeChunk();
        fresh.classList.toggle('near', c.classList.contains('near'));
        at.after(fresh);
        fresh.append(...part);
        let d = 0;
        for (const e of part) d += estimates.get(e) || 0;
        account(c, -d); account(fresh, d);
        done.push(fresh);
        at = fresh;
      }
      done.push(c);
    } else if (sparse(c)) {
      const other = [c.previousElementSibling, c.nextElementSibling].find(o => isChunk(o) && o.childElementCount + n <= CHUNK && estimateOf(o) + estimateOf(c) <= SPAN);
      if (other) {
        if (inUse(c) || inUse(other) || !reported(c) || !reported(other)) continue;
        const items = [...c.children];
        let d = 0;
        for (const e of items) d += estimates.get(e) || 0;
        if (other === c.previousElementSibling) other.append(...items); else other.prepend(...items);
        account(other, d);
        dropChunk(c);
        done.push(other);
      }
    }
    unevenChunks.delete(c);
  }
  // The page lays out as before: the chunks' sizes taken as they are now.
  // Then a heading the moves put first after a rule (or no longer) starts
  // flush (or not): a change of the page's, the resize observer's to keep
  // the place for.
  for (const c of done) if (c.isConnected) heights.set(c, c.getBoundingClientRect().height);
  for (const c of done) touched.delete(c);
  itemsChanged();
  if (unevenChunks.size) rebalanceTimer = setTimeout(rebalance, 2000);
}

/**
 * A heading first in a chunk right after a rule (or after front matter, a
 * top-level heading) sits flush as it does after one in its own chunk
 * (reader.css: h-flush). For the chunks a patch changed and those after them.
 */
export function flushStarts() {
  const done = new Set();
  for (const c of [...touched]) for (const x of [c, c.nextElementSibling]) {
    if (!isChunk(x) || !x.isConnected || done.has(x)) continue;
    done.add(x);
    const h = x.firstElementChild;
    if (!h || !h.classList.contains('k-heading')) continue;
    const p = lastOf(x.previousElementSibling);
    const on = !!p && (p.classList.contains('k-rule') || (p.classList.contains('k-frontMatter') && !!h.querySelector(':scope > :is(h1, h2)')));
    if (on === h.classList.contains('h-flush')) continue;
    // Its top margin changes, and so does its chunk: taken like any change
    // (touched; flushed, the block's height taken again). In a chunk laid
    // out and skipped, its skipped size and the block's height as laid out
    // change by the margin (its style, no layout).
    const skipped = laidOut.has(x) && cv() && !x.classList.contains('near');
    const was = skipped ? topMargin(h) : 0;
    h.classList.toggle('h-flush', on);
    touched.add(x);
    flushed.add(h);
    if (skipped) {
      const d = topMargin(h) - was;
      if (d) { account(x, 0, d); if (heights.has(h)) heights.set(h, heights.get(h) + d); }
    }
  }
}
// A block written, replaced or removed changes the top margin of a heading
// right after it too (reader.css: after a rule, after front matter, first in
// the document). patch.js notes that heading before the change (noteNext);
// afterwards its height is taken again, and in a chunk laid out and skipped
// the chunk's skipped size changes by the margin's change (settleNext).
const nextHeadings = new Map();   // heading block -> its top margin before (in a chunk laid out and skipped), else null
export function noteNext(n) {
  if (!n || nextHeadings.has(n) || !n.classList.contains('k-heading')) return;
  const c = chunkOf(n);
  nextHeadings.set(n, laidOut.has(c) && cv() && !c.classList.contains('near') ? topMargin(n) : null);
}
/** After a patch's changes: the noted headings not in a skipped chunk, their heights to take again. */
export function settleNext() {
  const out = [];
  for (const [n, was] of nextHeadings) {
    if (!n.isConnected) continue;
    const c = chunkOf(n);
    if (was !== null && laidOut.has(c) && cv() && !c.classList.contains('near')) {
      const d = topMargin(n) - was;
      if (d) { account(c, 0, d); if (heights.has(n)) heights.set(n, heights.get(n) + d); }
    } else out.push(n);
  }
  nextHeadings.clear();
  return out;
}

/** Heading blocks flushStarts changed, their heights to take again (patch.js, rebalance). */
export const flushed = new Set();
const topMargin = h => parseFloat(getComputedStyle(h.firstElementChild || h).marginTop) || 0;
/**
 * Items changed outside a patch (a removal marker read and gone): headings
 * flush again, the change left to the resize observer (no patch keeps the
 * place for it).
 */
export function itemsChanged() {
  settleNext();
  flushStarts();
  touched.clear();
  flushed.clear();
}

/**
 * The document became large (a patch took it past 250 blocks): content-
 * visibility from now on. The chunks were all laid out until now (the
 * patch's new ones would be in the next frame), and none has a size
 * remembered for it to be skipped at: each not near the screen is skipped
 * at its height now (stale), measured first (one layout of a page of about
 * 250 blocks). A reset's chunks are all new: their estimates.
 */
export function cvOn(reset) {
  const sizes = new Map();
  if (!reset) for (const c of doc.children) if (isChunk(c)) sizes.set(c, c.getBoundingClientRect().height);
  doc.classList.add('cv');
  if (!reset) for (const c of doc.children) if (isChunk(c)) queuePark(c);
  for (const [c, h] of sizes) {
    if (c.classList.contains('near')) continue;
    laidOut.add(c);
    stale.set(c, h);
    c.style.setProperty('--stale', `${h}px`);
    c.classList.add('stale');
  }
}

/** The document no longer large (no chunk skipped): every chunk at its own height again. */
export function unstale() {
  for (const c of [...parkedItems.keys()]) mount(c);
  for (const c of stale.keys()) { c.classList.remove('stale'); c.style.removeProperty('--stale'); }
  stale.clear();
}

/** Every chunk out of the document (a reset). */
/** Tests: chunks the observers' sets hold that are no longer in the page, and chunks past their limits. */
export function chunksHeld() {
  const out = c => [...c].filter(x => !x.isConnected).length;
  const by = { near: out(near), forced: out(forced), touched: out(touched), stale: out(stale.keys()), uneven: out(unevenChunks) };
  return { chunksDetached: Object.values(by).reduce((a, b) => a + b, 0), chunksBy: by, overfull: [...doc.children].filter(c => isChunk(c) && overfull(c)).length };
}

export function clearChunks() {
  for (const c of [...doc.children]) if (isChunk(c)) dropChunk(c);
}

// ---------------------------------------------------------------- Windowing (spike: m16/proto-window)
//
// A large document keeps in the page only the chunks near the screen (the
// lookahead's two screens, and those forced). Every other chunk is parked: an
// empty element at the height it is skipped at, its items detached (blocks
// as empty shells: the slot, the kind, the marks' classes) and each block's
// HTML kept in a model (patch.js: model). It comes back (mount) when it comes
// near, when a jump forces it, or before a patch touches it; it is parked
// again once it has left (queuePark, a few at a time while the page is quiet).
// Parking changes no height (the chunk keeps the size it was skipped at), so
// nothing moves.
const parkedItems = new Map();     // chunk -> its items, in order
export const parkedIn = new WeakMap();   // item -> its parked chunk
const parkedMarkers = new Set();   // parked chunks holding a removal marker
export const isParked = c => parkedItems.has(c);
/** The parked chunks (patch.js, before a patch that changes removal markers). */
export const parkedWithMarkers = () => [...parkedMarkers];
/** The last item of chunk `c`, parked or not. */
export const lastOf = c => !isChunk(c) ? null : parkedItems.has(c) ? parkedItems.get(c).at(-1) : c.lastElementChild;

let filler = null;   // {fill(el), empty(el)}: patch.js puts a block's HTML in or takes it out
export function setFiller(f) { filler = f; }
let patching = false;
/** A patch is applying (its own renderLazy takes the code its mounts set up). */
export function setPatching(on) { patching = on; }
export const windowStats = { mounts: 0, parks: 0 };

function forgetParked(c) {
  const items = parkedItems.get(c);
  if (!items) return;
  for (const e of items) parkedIn.delete(e);
  parkedItems.delete(c);
  parkedMarkers.delete(c);
  parkQueue.delete(c);
}

/** Chunk `c` back in the page, its blocks filled from the model. Whether it was parked. */
export function mount(c) {
  const items = parkedItems.get(c);
  if (!items) return false;
  parkedItems.delete(c);
  parkedMarkers.delete(c);
  for (const e of items) parkedIn.delete(e);
  c.append(...items);
  for (const e of items) if (e.classList.contains('blk')) filler.fill(e);
  c.classList.remove('parked');
  c.style.removeProperty('height');
  windowStats.mounts++;
  if (!patching) renderLazy(() => false);
  return true;
}

/** Chunk `c` parked at `h` px (its height now). */
function park(c, h) {
  if (parkedItems.has(c) || !c.isConnected) return;
  const items = [...c.children];
  if (!items.length) return;
  c.style.height = `${h}px`;
  c.classList.add('parked');
  for (const e of items) if (e.classList.contains('blk')) filler.empty(e);
  c.replaceChildren();
  parkedItems.set(c, items);
  for (const e of items) { parkedIn.set(e, c); if (e.classList.contains('del-mark')) parkedMarkers.add(c); }
  windowStats.parks++;
}

/** A reset of a large document: every chunk not laid out ahead parked at once, at its estimate (none is laid out yet). */
export function parkFresh() {
  for (const c of doc.children) if (isChunk(c) && !c.classList.contains('near') && !forced.has(c)) park(c, estimateOf(c));
}

const parkQueue = new Set();
let parkTimer = null;
const PARK_MS = 4;
export function queuePark(c) {
  if (!cv() || parkedItems.has(c)) return;
  parkQueue.add(c);
  if (!parkTimer) parkTimer = setTimeout(parkTurn, 100);
}
function parkTurn() {
  parkTimer = null;
  const t0 = performance.now();
  const ready = [];
  for (const c of parkQueue) {
    if (ready.length >= 8) break;
    parkQueue.delete(c);
    if (!c.isConnected || !cv() || near.has(c) || forced.has(c) || c.classList.contains('near') || parkedItems.has(c)) continue;
    if (holds(c.firstElementChild, c.lastElementChild) || unevenChunks.has(c)) { setTimeout(() => queuePark(c), 2000); continue; }
    ready.push(c);
  }
  // All reads, then all writes: one layout.
  const hs = ready.map(c => c.getBoundingClientRect().height);
  for (let i = 0; i < ready.length; i++) {
    park(ready[i], hs[i]);
    if (performance.now() - t0 > PARK_MS) { for (const c of ready.slice(i + 1)) parkQueue.add(c); break; }
  }
  if (parkQueue.size) parkTimer = setTimeout(parkTurn, 50);
}

/** Tests (spike): the items' slots in order, parked or not; each chunk's item count; every chunk back in the page. */
export function windowProbe() {
  const order = [], counts = [];
  for (const c of doc.children) {
    if (!isChunk(c)) continue;
    const items = parkedItems.get(c) ?? [...c.children];
    counts.push(items.length);
    for (const e of items) if (e.classList.contains('blk')) order.push(+e.dataset.slot);
  }
  return { order, counts, parked: parkedItems.size, ...windowStats };
}
export function mountAll() { for (const c of [...parkedItems.keys()]) mount(c); }
