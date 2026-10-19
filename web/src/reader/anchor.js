// Reading position: capture and restore the block at the top of the viewport,
// compensate for blocks above it changing height, and resolve #fragments.
import { doc, root, slots, heights, trace, keptScroll, onKeptScroll, blocksHidden } from './core.js';
import { scheduleRail } from './rail.js';

// Only the changes-only filter hides blocks: without it nothing asks the
// layout (offsetParent makes WebKit lay out content-visibility's skipped
// blocks again, the whole page in a large document).
export function isShown(e) { return !e.hidden && (!blocksHidden || e.offsetParent !== null); }

function blockList() { return Array.from(doc.children).filter(e => e.classList.contains('blk') && isShown(e)); }

/** First block whose bottom edge is below the top of the viewport (under the window toolbar). */
function topBlock() {
  const line = topInset() + 8;
  // Nothing hidden (the usual case): a binary search over the page's
  // children themselves, with no list of every block and no offsetParent
  // read for each (a layout question per block, in every patch), and no
  // search of the whole page for a hidden one either.
  if (!blocksHidden || !doc.querySelector(':scope > .blk[hidden]')) {
    const kids = doc.children;
    const blkFrom = i => { for (let j = i; j < kids.length; j++) if (kids[j].classList.contains('blk')) return kids[j]; return null; };
    let lo = 0, hi = kids.length - 1, found = null;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const el = blkFrom(mid);
      if (!el) { hi = mid - 1; continue; }
      if (el.getBoundingClientRect().bottom > line) { found = el; hi = mid - 1; } else { lo = mid + 1; }
    }
    return found;
  }
  const list = blockList();
  let lo = 0, hi = list.length - 1, found = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const r = list[mid].getBoundingClientRect();
    if (r.bottom > line) { found = list[mid]; hi = mid - 1; } else { lo = mid + 1; }
  }
  return found;
}

export function captureAnchor() {
  const el = topBlock();
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const offset = -r.top;
  // The share of the block above the toolbar's edge, kept when its height changes.
  const ratio = r.height > 0 ? (topInset() - r.top) / r.height : 0;
  let heading = null;
  for (let e = el; e; e = e.previousElementSibling) {
    if (e.classList.contains('k-heading')) { heading = e.dataset.anchor || null; break; }
  }
  // The neighbours stand in for the anchor block if a patch removes it.
  const prev = shownSibling(el, 'previousElementSibling');
  const next = shownSibling(el, 'nextElementSibling');
  return { slot: +el.dataset.slot, offset, ratio, heading,
    prev: prev ? +prev.dataset.slot : null, next: next ? +next.dataset.slot : null };
}

function shownSibling(el, dir) {
  for (let e = el[dir]; e; e = e[dir]) if (e.classList.contains('blk') && isShown(e)) return e;
  return null;
}

/**
 * Returns whether the reader is back at the anchor: its own block was there,
 * and the page could scroll to put it where it was (a document cut short
 * cannot scroll that far).
 */
export function restoreAnchor(a, changedSlots) {
  return restoreAnchorTo(a, changedSlots);
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
  if (!el || !isShown(el)) return 0;
  const r = el.getBoundingClientRect();
  return r.top + (changedSlots.has(a.slot) ? a.ratio * r.height - topInset() : a.offset);
}

function restoreAnchorTo(a, changedSlots) {
  if (!a) return false;
  let el = slots.get(a.slot);
  // The anchor block may have been hidden by the changes-only filter (or
  // removed): fall back to the nearest visible block in document order,
  // preferring the previous one so the reader stays with what they read.
  if (el && !isShown(el)) el = nearestVisible(el);
  if (el) {
    const r = el.getBoundingClientRect();
    const want = changedSlots.has(a.slot) ? a.ratio * r.height - topInset() : a.offset;
    keepBy(r.top + want);
    return slots.has(a.slot) && Math.abs(el.getBoundingClientRect().top + want) <= 1;
  }
  // The anchor block is gone: the block that followed it takes its place at
  // the top (or, at the end of the document, the one before it ends there).
  // Only then the section heading, which can be far above. The top is the
  // bottom of the window toolbar the page scrolls under.
  const inset = topInset();
  for (const [slot, edge] of [[a.next, 'top'], [a.prev, 'bottom']]) {
    let n = slot != null ? slots.get(slot) : null;
    if (n && !isShown(n)) n = nearestVisible(n);
    if (n) { keepBy(n.getBoundingClientRect()[edge] - inset); return false; }
  }
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) keepBy(h.getBoundingClientRect().top - inset);
  }
  return false;
}

/** The height of the window toolbar the page scrolls under (set by the app). */
export function topInset() {
  return parseFloat(root.style.getPropertyValue('--top-inset')) || 0;
}

/**
 * Re-baselines every block's height for the resize compensator, after a
 * change that reflows the whole page (font size, width, theme, find mode)
 * and whose effect on the position the caller restores itself.
 */
export function rebaselineHeights() {
  for (const el of slots.values()) heights.set(el, el.hidden ? 0 : el.getBoundingClientRect().height);
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

/** Nearest visible block to `el` in document order (previous first, then next). */
function nearestVisible(el) {
  let p = el.previousElementSibling;
  while (p) {
    if (p.classList.contains('blk') && isShown(p)) return p;
    p = p.previousElementSibling;
  }
  let n = el.nextElementSibling;
  while (n) {
    if (n.classList.contains('blk') && isShown(n)) return n;
    n = n.nextElementSibling;
  }
  return null;
}

/**
 * Scrolls so `target` sits at the top of the viewport (`gap` above it, else its
 * scroll-margin) or, with `center`, in the middle.
 *
 * Not scrollIntoView: in a large document an off-screen block is laid out with
 * content-visibility, its content skipped; right after a scroll WebKit's
 * scrollIntoView on an element inside such a block scrolls nowhere. The block
 * is made visible for the measurement, so the position is the real one.
 */
export function scrollToElement(target, { center = false, gap } = {}) {
  const blk = target.closest('#ro-doc > .blk');
  if (blk) forceLayout(blk);
  const r = target.getBoundingClientRect();
  const margin = gap ?? (parseFloat(getComputedStyle(target).scrollMarginTop) || 0);
  // The top of the page lies under the window toolbar: aim below it.
  const inset = topInset();
  window.scrollBy(0, center ? r.top + r.height / 2 - (window.innerHeight + inset) / 2 : r.top - margin - inset);
}

/**
 * Blocks laid out at once whatever content-visibility would skip (a link's
 * target measured, new blocks at the end a following reader goes to). Once a
 * frame has rendered one, content-visibility could have it back and keep the
 * size it recorded; but handing a block back is itself a change WebKit answers
 * by laying out every skipped block of a large document again (5 MB: 0.1-3 s),
 * which a frame after each append of a streaming agent paid. They are handed
 * back together, at the start of a frame, once there are more than
 * FORCED_KEPT of them: one such layout per that many appends.
 */
const FORCED_KEPT = 32;
const forced = new Map();   // block -> whether a frame has rendered it since it was forced
export function forceLayout(el) {
  if (!doc.classList.contains('cv') || el.style.contentVisibility) return;
  el.style.contentVisibility = 'visible';
  forced.set(el, false);
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (forced.has(el)) forced.set(el, true);
    if (forced.size > FORCED_KEPT) releaseForced();
  }));
}
function releaseForced() {
  for (const [el, rendered] of forced) {
    if (el.isConnected && !rendered) continue;
    forced.delete(el);
    if (el.isConnected) el.style.contentVisibility = '';
  }
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
  for (let e = topBlock(); e; e = e.nextElementSibling) {
    if (!e.classList.contains('blk') || (blocksHidden && !isShown(e))) continue;
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

/** Blocks seen at a size other than their estimate: laid out at least once. */
const laidOut = new WeakSet();
const estimate = el => parseFloat(el.style.containIntrinsicSize.replace('auto ', '')) || 0;

/**
 * Where a jump landed (N, an outline click) stays put while the blocks
 * around it are laid out, for as long as the jump aims (or until the reader
 * scrolls): blocks above it that change size grow or shrink upward. Its own
 * top is kept, not a sum of the changes above it: near the end of the page
 * the page growing shorter has moved the scroll position already.
 */
let landed = null;   // {el, top, until, y}: its top on screen, and where the page was left
onKeptScroll(dy => { if (landed) landed.y += dy; });
export function pinLanding(el) {
  landed = doc.classList.contains('cv')
    ? { el, top: el.getBoundingClientRect().top, until: performance.now() + 1000, y: document.scrollingElement.scrollTop } : null;
}

/**
 * The block whose place on screen the compensation keeps: the landing of a
 * jump still settling, else the first block on screen that was laid out
 * before (not one this round resized, not one still at its estimate).
 * null: none on screen.
 */
function keptBlock(resized) {
  if (landed) {
    if (landed.el.isConnected && performance.now() < landed.until && Math.abs(document.scrollingElement.scrollTop - landed.y) <= 2) return landed.el;
    landed = null;
  }
  const cv = doc.classList.contains('cv');
  const first = topBlock();
  if (!first) return null;
  // On screen as the page was before these changes (a block's top then was
  // its top now less what the blocks before it grew by: blocks laid out at
  // once can push the kept one out of the window); failing that, as it is
  // now (blocks that shrank can bring it in: the screen showed only them).
  let before = 0;
  for (const [el, d] of resized) if (el !== first && (el.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING)) before += d;
  for (const then of [true, false]) {
    let grown = then ? before : 0;
    for (let e = first; e; e = e.nextElementSibling) {
      if (!e.classList.contains('blk') || !isShown(e)) continue;
      if (e.getBoundingClientRect().top - grown >= window.innerHeight) break;
      const d = resized.get(e);
      if (d !== undefined) { if (then) grown += d; continue; }
      if (cv && !laidOut.has(e) && heights.get(e) === estimate(e)) continue;
      return e;
    }
  }
  return null;
}

// Keeps the text the reader sees from moving when blocks change height later
// (diagrams, math, images, content-visibility estimates becoming real). In a
// large document WebKit lays a block out a frame after it came into view (it
// shows at its estimated height until then): scrolling up, those blocks
// change size on screen, above the text that was there. So every block before
// the kept one (keptBlock) that changed size grows or shrinks upward; with
// none on screen, those entirely above the viewport do.
export const resizeObserver = new ResizeObserver(entries => {
  let delta = 0;
  const inset = topInset();
  const resized = new Map();   // block -> change in height
  for (const entry of entries) {
    const el = entry.target;
    const h = el.getBoundingClientRect().height;
    const prev = heights.get(el);
    heights.set(el, h);
    if (prev === undefined || prev === h) continue;
    resized.set(el, h - prev);
    laidOut.add(el);
  }
  if (resized.size) {
    const kept = keptBlock(resized);
    if (kept && kept === landed?.el) {
      const d = kept.getBoundingClientRect().top - landed.top;
      if (Math.abs(d) >= 0.5) delta = d;
    }
    else for (const [el, d] of resized) {
      // Before the kept block; or, with none, entirely above the viewport (or under the toolbar) before it resized.
      if (kept ? el !== kept && (el.compareDocumentPosition(kept) & Node.DOCUMENT_POSITION_FOLLOWING)
        : el.getBoundingClientRect().bottom - d <= inset + 1) delta += d;
    }
  }
  if (delta !== 0 && document.scrollingElement.scrollTop > 0) {
    const y = document.scrollingElement.scrollTop;
    window.scrollBy(0, delta);
    keptScroll(document.scrollingElement.scrollTop - y);
    trace('compensate', { delta: Math.round(delta) });
  }
  // Blocks that content-visibility lays out once they come into view change
  // size again; measured at the start of the next frame, they settle before
  // its observations. Left to the frame's own layout, WebKit reports a
  // ResizeObserver loop. (3.3 got this measurement from redrawing the rail
  // on every callback; the rail is now redrawn at most every 250 ms.)
  if (!settleQueued) {
    settleQueued = true;
    requestAnimationFrame(() => { settleQueued = false; void document.scrollingElement.scrollHeight; });
  }
  scheduleRail();
});
