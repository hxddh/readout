// Chunks: the page's items (blocks, removal markers) in groups of about
// CHUNK, so a large document's content-visibility is decided for a few
// hundred elements instead of every block. WebKit lays out a skipped element
// only once it touches the viewport, and checks every such element in every
// frame that scrolls (5 MB of blocks: tens of milliseconds a frame, and each
// block blank for the frame it came on screen in). Chunks within two screens
// of the viewport are laid out ahead (`near`), so what scrolls in is drawn.
import { doc, heights, isChunk } from './core.js';
import { resizeObserver } from './anchor.js';

const CHUNK = 32;   // items a chunk is filled to as blocks arrive in order
const MAX = 64;     // a chunk with more is split where the next item goes in

/** Each item's estimated height, until a chunk is laid out (its size is their sum). */
const estimates = new WeakMap();
const chunkEstimates = new WeakMap();
/** Chunks seen at a size other than their estimate: laid out at least once. */
export const laidOut = new WeakSet();

export const cv = () => doc.classList.contains('cv');
export const chunkOf = el => el.parentElement;
export const estimateOf = c => chunkEstimates.get(c) || 0;
/** Whether WebKit has laid `c` out yet, in a large document (it is at its estimated height). */
export const neverLaidOut = c => cv() && !laidOut.has(c) && heights.get(c) === estimateOf(c);

// Laid out ahead of the viewport (class near, reader.css): content-visibility
// decides only for the element touching it, and that one would show blank
// for a frame.
const near = new Set();
const lookahead = new IntersectionObserver(entries => {
  for (const e of entries) {
    if (e.isIntersecting) near.add(e.target); else near.delete(e.target);
    show(e.target);
  }
}, { rootMargin: '200% 0px' });
const forced = new Set();
function show(c) {
  const on = near.has(c) || forced.has(c);
  if (on !== c.classList.contains('near')) c.classList.toggle('near', on);
}

/**
 * The chunk of `el` (or chunk `el`) laid out now, whatever content-visibility
 * would skip, once a frame renders it: a jump's target, a place restored,
 * new blocks at the end a following reader goes to (WebKit lays a skipped
 * chunk out in the frame, not when asked: until then it places its blocks at
 * its top). Kept for two frames, then for as long as it is near the screen.
 */
export function forceLayout(el) {
  const c = isChunk(el) ? el : el.closest('#ro-doc > .chunk');
  // Near the screen already: it is laid out, and so are its neighbours.
  if (!cv() || !isChunk(c) || c.classList.contains('near')) return;
  // And the chunk after it, which the rest of the screen below it shows:
  // a chunk on screen is never contained (its paint would clip what blocks
  // draw past the gutters, wide code and tables).
  for (const x of [c, c.nextElementSibling]) {
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
  touched.delete(c);
  resizeObserver.unobserve(c);
  lookahead.unobserve(c);
  near.delete(c);
  forced.delete(c);
  c.remove();
}

// A chunk never laid out is as tall as its items' estimates; one laid out
// keeps the size it was last laid out at (contain-intrinsic-size: auto).
// The chunks a patch changed (patch.js takes their sizes afterwards, so the
// resize observer does not count what the patch itself keeps the place for).
export const touched = new Set();
function account(c, d) {
  touched.add(c);
  if (!d) return;
  const est = estimateOf(c) + d;
  chunkEstimates.set(c, est);
  if (!laidOut.has(c)) c.style.containIntrinsicSize = `auto ${est}px`;
}

/** Puts `el` after item `after` (null: first in the document), estimated `est` px tall. */
export function place(el, after, est = 0) {
  let c = after ? chunkOf(after) : doc.firstElementChild;
  if (!isChunk(c)) { c = makeChunk(); doc.prepend(c); }
  const n = c.childElementCount;
  if (after && !after.nextElementSibling && n >= CHUNK) {
    // After a full chunk's last item (an agent writing on): the next chunk, if it has room, else a new one.
    const next = c.nextElementSibling;
    if (isChunk(next) && next.childElementCount < CHUNK) { c = next; after = null; }
    else { const fresh = makeChunk(); c.after(fresh); c = fresh; after = null; }
  } else if (!after && n >= MAX) {
    const fresh = makeChunk(); c.before(fresh); c = fresh;
  }
  // In the middle of a chunk: it grows (past MAX it is split when the page is quiet).
  if (after) after.after(el); else c.prepend(el);
  estimates.set(el, est);
  account(c, est);
  if (c.childElementCount > MAX) uneven(c);
}

/** Puts `el` last in the document. */
export function placeLast(el, est = 0) {
  let c = doc.lastElementChild;
  while (c && !isChunk(c)) c = c.previousElementSibling;
  place(el, c ? c.lastElementChild : null, est);
}

/** Its estimate changed (new content). */
export function reestimate(el, est) {
  const was = estimates.get(el) || 0;
  estimates.set(el, est);
  account(chunkOf(el), est - was);
}

/**
 * Takes `el` out of the document. An emptied chunk goes; one left with few
 * items joins a neighbour when the page is quiet.
 */
export function unplace(el) {
  const c = chunkOf(el);
  el.remove();
  if (!isChunk(c)) return;
  account(c, -(estimates.get(el) || 0));
  const n = c.childElementCount;
  if (!n) return dropChunk(c);
  if (n < CHUNK / 4) uneven(c);
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
  if (cv() && !c.classList.contains('near')) return true;
  if (c.contains(document.activeElement)) return true;
  const sel = getSelection();
  for (let i = 0; sel && i < sel.rangeCount; i++) if (sel.getRangeAt(i).intersectsNode(c)) return true;
  // Find's marks (static ranges: moved, they would point at nothing) in it.
  if (typeof CSS !== 'undefined' && CSS.highlights) for (const name of ['ro-find', 'ro-find-cur']) {
    for (const r of CSS.highlights.get(name) || []) if (c.contains(r.startContainer) || c.contains(r.endContainer)) return true;
  }
  return false;
}
function rebalance() {
  rebalanceTimer = null;
  const done = [];
  for (const c of unevenChunks) {
    if (!c.isConnected) { unevenChunks.delete(c); continue; }
    const n = c.childElementCount;
    if (n > MAX) {
      if (inUse(c)) continue;
      // Into chunks of CHUNK, the first keeping its place.
      let at = c;
      const items = [...c.children].slice(CHUNK);
      for (let k = 0; k < items.length; k += CHUNK) {
        const fresh = makeChunk();
        fresh.classList.toggle('near', c.classList.contains('near'));
        at.after(fresh);
        const part = items.slice(k, k + CHUNK);
        fresh.append(...part);
        let d = 0;
        for (const e of part) d += estimates.get(e) || 0;
        account(c, -d); account(fresh, d);
        done.push(fresh);
        at = fresh;
      }
      done.push(c);
    } else if (n < CHUNK / 4) {
      const other = [c.previousElementSibling, c.nextElementSibling].find(o => isChunk(o) && o.childElementCount + n <= CHUNK);
      if (other) {
        if (inUse(c) || inUse(other)) continue;
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
  flushStarts();
  for (const c of done) if (c.isConnected) heights.set(c, c.getBoundingClientRect().height);
  for (const c of done) touched.delete(c);
  if (unevenChunks.size) rebalanceTimer = setTimeout(rebalance, 2000);
}

/**
 * A heading first in a chunk right after a rule (or after front matter, a
 * top-level heading) sits flush as it does after one in its own chunk
 * (reader.css: h-flush). For the chunks a patch changed and those after them.
 */
export function flushStarts() {
  for (const c of touched) for (const x of [c, c.nextElementSibling]) {
    const h = isChunk(x) && x.isConnected ? x.firstElementChild : null;
    if (!h || !h.classList.contains('k-heading')) continue;
    const p = x.previousElementSibling?.lastElementChild;
    h.classList.toggle('h-flush', !!p && (p.classList.contains('k-rule') || (p.classList.contains('k-frontMatter') && !!h.querySelector(':scope > :is(h1, h2)'))));
  }
}

/** Every chunk out of the document (a reset). */
export function clearChunks() {
  for (const c of [...doc.children]) if (isChunk(c)) dropChunk(c);
}
