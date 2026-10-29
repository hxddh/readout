// Reading position: capture and restore the block at the top of the viewport,
// compensate for blocks above it changing height, and resolve #fragments.
import { doc, slots, heights, trace, keptScroll, onKeptScroll, isChunk, nextItem, prevItem, blockAfter, precedes } from './core.js';
import { scheduleRail } from './rail.js';
import { forceLayout, laidOut, estimateOf, neverLaidOut, cv, scrolledTo } from './chunks.js';
import { holdJump } from './enhance.js';

/** First block whose bottom edge is below the top of the viewport. */
function topBlock() {
  const line = 8;
  // Binary searches, over the chunks and then over the chunk's items, with
  // no list of every block and no offsetParent read for each (a layout
  // question per block, in every patch).
  const first = (kids, ok) => {
    let lo = 0, hi = kids.length - 1, found = null;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      let j = mid;
      while (j <= hi && !ok(kids[j])) j++;
      if (j > hi) { hi = mid - 1; continue; }
      if (kids[j].getBoundingClientRect().bottom > line) { found = kids[j]; hi = mid - 1; } else { lo = j + 1; }
    }
    return found;
  };
  const chunk = first(doc.children, isChunk);
  if (!chunk) return null;
  let el = first(chunk.children, e => e.classList.contains('blk'));
  if (!el) for (el = chunk.lastElementChild && nextItem(chunk.lastElementChild); el && !el.classList.contains('blk'); el = nextItem(el));
  return el;
}

export function captureAnchor() {
  const el = topBlock();
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const offset = -r.top;
  // The share of the block above the viewport's edge, kept when its height changes.
  const ratio = r.height > 0 ? -r.top / r.height : 0;
  let heading = null;
  for (let e = el; e; e = prevItem(e)) {
    if (e.classList.contains('k-heading')) { heading = e.dataset.anchor || null; break; }
  }
  // The neighbours stand in for the anchor block if a patch removes it.
  const prev = blockAfter(el, prevItem);
  const next = blockAfter(el);
  return { slot: +el.dataset.slot, offset, ratio, heading,
    prev: prev ? +prev.dataset.slot : null, next: next ? +next.dataset.slot : null };
}

/**
 * Returns whether the reader is back at the anchor: its own block was there,
 * and the page could scroll to put it where it was (a document cut short
 * cannot scroll that far).
 */
export function restoreAnchor(a, changedSlots) {
  if (!a) return false;
  const el = slots.get(a.slot);
  if (el) {
    forceLayout(el);
    const r = el.getBoundingClientRect();
    const want = changedSlots.has(a.slot) ? a.ratio * r.height : a.offset;
    keepBy(r.top + want);
    return slots.has(a.slot) && Math.abs(el.getBoundingClientRect().top + want) <= 1;
  }
  // The anchor block is gone: the block that followed it takes its place at
  // the top (or, at the end of the document, the one before it ends there).
  // Only then the section heading, which can be far above.
  for (const [slot, edge] of [[a.next, 'top'], [a.prev, 'bottom']]) {
    const n = slot != null ? slots.get(slot) : null;
    if (n) forceLayout(n);
    if (n) { keepBy(n.getBoundingClientRect()[edge]); return false; }
  }
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) { forceLayout(h); keepBy(h.getBoundingClientRect().top); }
  }
  return false;
}

/**
 * Scrolls by `dy` to keep the reader's place, and tells whoever tracks the
 * position. Nothing to scroll (the usual case: a patch below the reader)
 * scrolls nothing: in a large document a scroll, and reading where it left
 * the page, each cost a layout of the whole page.
 */
function keepBy(dy) {
  if (!(Math.abs(dy) >= 0.5)) return;
  const se = document.scrollingElement;
  const y = se.scrollTop;
  window.scrollBy(0, dy);
  keptScroll(se.scrollTop - y);
}

/**
 * How far below its place the anchor's own block sits (positive: the page
 * would have to scroll further down to put it back; negative: further up).
 */
export function anchorMiss(a, changedSlots) {
  const el = a && slots.get(a.slot);
  if (!el) return 0;
  const r = el.getBoundingClientRect();
  return r.top + (changedSlots.has(a.slot) ? a.ratio * r.height : a.offset);
}

/** `el`'s height (and its chunk's) taken as they are now, after a change whose place the caller kept. */
export function baseline(el) {
  heights.set(el, el.getBoundingClientRect().height);
  const c = el.parentElement;
  if (isChunk(c)) heights.set(c, c.getBoundingClientRect().height);
}

/**
 * Re-baselines the chunks' heights (and the blocks' in chunks laid out) for
 * the resize compensator, after a change that reflows the whole page (font
 * size, width, theme) and whose effect on the position the caller restores
 * itself.
 */
export function rebaselineHeights() {
  // A chunk skipped is not asked about its blocks: WebKit would lay each
  // one out to answer. They report their sizes when it is laid out again,
  // the chunk's change made up for as a whole.
  const all = !cv();
  for (const c of doc.children) {
    if (!isChunk(c)) continue;
    heights.set(c, c.getBoundingClientRect().height);
    if (all || c.classList.contains('near')) for (const el of c.children) if (el.dataset.slot) heights.set(el, el.getBoundingClientRect().height);
  }
}

/**
 * Runs `change` (which reflows the page) keeping the reader's place. With
 * `ratio`, the anchor block itself is expected to change height too, so the
 * place within it is kept as a fraction of its height. A reader following
 * the end of the document stays at the end (and so keeps following).
 */
export function keepPlace(change, { ratio = false, anchor = captureAnchor(), bottom = atBottom() } = {}) {
  change();
  holdPlace(anchor, bottom, ratio);
  rebaselineHeights();
}

/** Puts the reader back at `anchor`, or at the end when they were `bottom`. */
export function holdPlace(anchor, bottom, ratio = false) {
  if (bottom) {
    const y = document.scrollingElement.scrollTop;
    window.scrollTo(0, document.scrollingElement.scrollHeight);
    keptScroll(document.scrollingElement.scrollTop - y);
  }
  else if (anchor) restoreAnchor(anchor, ratio ? new Set([anchor.slot]) : new Set());
}


/**
 * Scrolls so `target` sits at the top of the viewport (`gap` above it, else its
 * scroll-margin) or, with `center`, in the middle: a jump (aimAt), so a target
 * in a chunk not laid out yet (a footnote deep in a long list) lands where it
 * should once the chunk is.
 *
 * Not scrollIntoView: in a large document an off-screen chunk is skipped
 * (content-visibility); right after a scroll WebKit's scrollIntoView on an
 * element inside one scrolls nowhere.
 */
export function scrollToElement(target, { center = false, gap, landed = () => {} } = {}) {
  const margin = gap ?? (parseFloat(getComputedStyle(target).scrollMarginTop) || 0);
  aimAt(target, () => {
    const r = target.getBoundingClientRect();
    return center ? r.top + r.height / 2 - window.innerHeight / 2 : r.top - margin;
  }, () => { pinLanding(target); landed(); }, center ? window.innerHeight / 2 : 0);
}

export function atBottom() {
  const se = document.scrollingElement;
  return se.scrollHeight - (se.scrollTop + window.innerHeight) < 48 && se.scrollTop > 0;
}

/** The whole document is on screen: the page does not scroll. */
export function fitsOnScreen() {
  return document.scrollingElement.scrollHeight <= window.innerHeight + 1;
}

/** The blocks on screen, top to bottom (at most a screenful's worth of layout questions). */
export function blocksOnScreen() {
  const out = [];
  for (let e = topBlock(); e; e = nextItem(e)) {
    if (!e.classList.contains('blk')) continue;
    if (e.getBoundingClientRect().top >= window.innerHeight) break;
    out.push(e);
  }
  return out;
}

/**
 * The one place a `#fragment` (in-document link or `file.md#section` open)
 * becomes an element. Scoped to the document container: chrome ids live under
 * ro-* and must never be a target. Matches an element id (as written, then
 * lowercased), falling back to a heading block's anchor.
 */
export function resolveFragment(raw) {
  if (!raw) return null;
  let id = raw.startsWith('#') ? raw.slice(1) : raw;
  try { id = decodeURIComponent(id); } catch { /* keep raw */ }
  if (!id) return null;
  const lower = id.toLowerCase();
  return doc.querySelector(`[id="${CSS.escape(id)}"], [id="${CSS.escape(lower)}"]`)
    || doc.querySelector(`.k-heading[data-anchor="${CSS.escape(lower)}"]`);
}

let settleQueued = false;

/**
 * Where a jump landed (N, an outline click) stays put while the blocks
 * around it are laid out, for as long as the jump aims (or until the reader
 * scrolls): blocks above it that change size grow or shrink upward. Its own
 * top is kept, not a sum of the changes above it: near the end of the page
 * the page growing shorter has moved the scroll position already.
 */
let landed = null;   // {el, top, until, y}: its top on screen, and where the page was left
// The page at its end: a scroll position moved since a jump left it may be
// the page growing shorter (a chunk near the end laid out), not the reader.
export const atEnd = () => { const se = document.scrollingElement; return se.scrollTop >= se.scrollHeight - window.innerHeight - 1; };
onKeptScroll(dy => { if (landed) landed.y += dy; });
export function pinLanding(el) {
  landed = cv()
    ? { el, top: el.getBoundingClientRect().top, until: performance.now() + 1000, y: document.scrollingElement.scrollTop } : null;
}

/** A long jump aims again every frame for this long (aimAt; reader.js's scrollToEdge). */
export const AIM_MS = 1000;

/**
 * Every jump (a link, a footnote and its back-link, an outline click, a
 * match found, N, a rail tick, a place restored): `off()` is how far the
 * page is from where `el` should be, `landed()` runs after each aim, `room`
 * how much of the screen shows above `el` where it lands (forceLayout). The
 * chunk it lands in is laid out by the frames after the jump (WebKit places
 * a skipped chunk's blocks at its top until then), the landing stays put
 * while they do (pinLanding), and the page aims again at whatever still
 * moves it, until another jump, or until the reader scrolls.
 */
let aiming = null;   // the jump being aimed: {y}, where its last aim left the page
onKeptScroll(dy => { if (aiming) aiming.y += dy; });
// The reader taking over (the wheel and a trackpad's momentum, keys, the
// mouse, a touch) ends the jump at once, before the scroll it makes: the
// page never aims against them. (A key or click that jumps again starts a
// new one after this.)
for (const type of ['wheel', 'keydown', 'mousedown', 'touchstart']) {
  window.addEventListener(type, () => { aiming = null; landed = null; }, { capture: true, passive: true });
}
export function aimAt(el, off, landed, room = 0, waited = false) {
  forceLayout(el, room);
  // Code the landing shows is coloured in the frame that shows it: the jump
  // waits for it (holdJump, a moment), unless it has arrived.
  if (!waited && holdJump(el, off, () => { if (el.isConnected) aimAt(el, off, landed, room, true); })) return;
  window.scrollBy(0, off());
  scrolledTo();
  landed();
  if (!cv()) return;
  const se = document.scrollingElement;
  const mine = aiming = { y: se.scrollTop };
  const until = performance.now() + AIM_MS;
  const reaim = () => {
    // Another jump since, or the reader scrolled (the scroll event telling
    // the TOC may not have run yet): leave the page where it is.
    if (aiming !== mine || !el.isConnected || (Math.abs(se.scrollTop - mine.y) > 2 && !atEnd())) return;
    const d = off();
    if (Math.abs(d) > 1) { window.scrollBy(0, d); scrolledTo(); mine.y = se.scrollTop; landed(); }
    if (performance.now() < until) requestAnimationFrame(reaim);
  };
  requestAnimationFrame(reaim);
}

/**
 * The block whose place on screen the compensation keeps: the landing of a
 * jump still settling, else the first block on screen that was laid out
 * before (not one this round resized, not one in a chunk laid out for the
 * first time, nor in one that was entirely above the window). null: none on
 * screen.
 */
function keptBlock(resized, chunks, firstChunks, above) {
  if (landed) {
    if (landed.el.isConnected && performance.now() < landed.until && (Math.abs(document.scrollingElement.scrollTop - landed.y) <= 2 || atEnd())) return landed.el;
    landed = null;
  }
  const first = topBlock();
  if (!first) return null;
  const own = first.parentElement;
  // On screen as the page was before these changes (a block's top then was
  // its top now less what the chunks and blocks before it grew by: chunks
  // laid out at once can push the kept one out of the window); failing that,
  // as it is now (what shrank can bring it in: the screen showed only that).
  let before = 0;
  for (const [c, d] of chunks) if (c !== own && precedes(c, first)) before += d;
  for (const [el, d] of resized) if (el !== first && el.parentElement === own && precedes(el, first)) before += d;
  for (const then of [true, false]) {
    let grown = then ? before : 0;
    for (let e = first; e;) {
      // A chunk laid out for the first time (or not yet), or one above the
      // window until it grew into it, had nothing on screen to keep.
      const c = e.parentElement;
      if (firstChunks.has(c) || neverLaidOut(c) || above.has(c)) {
        if (then) grown += chunks.get(c) || 0;
        e = nextItem(c.lastElementChild);
        continue;
      }
      if (e.classList.contains('blk')) {
        if (e.getBoundingClientRect().top - grown >= window.innerHeight) break;
        const d = resized.get(e);
        if (d === undefined) return e;
        if (then) grown += d;
      }
      e = nextItem(e);
    }
  }
  return null;
}

// Keeps the text the reader sees from moving when what is above it changes
// height later (diagrams, math, images, a chunk content-visibility skipped
// laid out). A chunk laid out for the first time before the kept block
// (keptBlock) grows or shrinks upward as a whole, wherever it is: it showed
// at its estimate until then. Any other change keeps the rule for a block
// changing size later (a <details> opened, an image loaded): only what was
// entirely above the viewport before it resized is made up for (a chunk as a
// whole, even one that grew into the window, blocks written into it while it
// was skipped; in the kept block's own chunk, block by block), so what the
// reader opened at the top of the window grows down from where it is.
export const resizeObserver = new ResizeObserver(entries => {
  let delta = 0;
  const resized = new Map();      // block -> change in height
  const chunks = new Map();       // chunk -> change in height
  const firstChunks = new Set();  // of those, the chunks laid out for the first time
  for (const entry of entries) {
    const el = entry.target;
    const h = el.getBoundingClientRect().height;
    const prev = heights.get(el);
    heights.set(el, h);
    if (isChunk(el)) {
      if (prev !== undefined && prev !== h && cv() && !laidOut.has(el) && prev === estimateOf(el)) firstChunks.add(el);
      if (h !== estimateOf(el)) laidOut.add(el);
      if (prev !== undefined && prev !== h) chunks.set(el, h - prev);
      continue;
    }
    if (prev !== undefined && prev !== h) resized.set(el, h - prev);
  }
  if (resized.size || chunks.size) {
    // The chunks entirely above the window before they resized: their bottom
    // then is their bottom now less what they and the chunks before them grew by.
    const above = new Set();
    let grew = 0;
    for (const c of [...chunks.keys()].sort((a, b) => precedes(a, b) ? -1 : 1)) {
      grew += chunks.get(c);
      if (c.getBoundingClientRect().bottom - grew <= 1) above.add(c);
    }
    const kept = keptBlock(resized, chunks, firstChunks, above);
    if (kept && kept === landed?.el) {
      const d = kept.getBoundingClientRect().top - landed.top;
      if (Math.abs(d) >= 0.5) delta = d;
    }
    else {
      const own = kept?.parentElement;
      for (const [c, d] of chunks) {
        if (c === own) continue;
        if (kept && firstChunks.has(c) ? precedes(c, kept) : above.has(c)) delta += d;
      }
      for (const [el, d] of resized) if (own && el.parentElement === own && el.getBoundingClientRect().bottom - d <= 1) delta += d;
    }
  }
  if (delta !== 0 && document.scrollingElement.scrollTop > 0) {
    const y = document.scrollingElement.scrollTop;
    window.scrollBy(0, delta);
    keptScroll(document.scrollingElement.scrollTop - y);
    trace('compensate', { delta: Math.round(delta) });
  }
  // Chunks laid out as they come near change size again; measured at the
  // start of the next frame, they settle before its observations (left to
  // the frame's own layout, WebKit reports a ResizeObserver loop).
  if (!settleQueued) {
    settleQueued = true;
    requestAnimationFrame(() => { settleQueued = false; void document.scrollingElement.scrollHeight; });
  }
  scheduleRail();
});
