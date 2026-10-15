// Reading position: capture and restore the block at the top of the viewport,
// compensate for blocks above it changing height, and resolve #fragments.
import { doc, root, slots, heights, trace, keptScroll } from './core.js';
import { scheduleRail } from './rail.js';

export function isShown(e) { return !e.hidden && e.offsetParent !== null; }

function blockList() { return Array.from(doc.children).filter(e => e.classList.contains('blk') && isShown(e)); }

/** First block whose bottom edge is below the top of the viewport (under the window toolbar). */
function topBlock() {
  const line = topInset() + 8;
  // Nothing hidden (the usual case): a binary search over the page's
  // children themselves, with no list of every block and no offsetParent
  // read for each (a layout question per block, in every patch).
  if (!doc.querySelector(':scope > .blk[hidden]')) {
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
  const y = document.scrollingElement.scrollTop;
  const back = restoreAnchorTo(a, changedSlots);
  keptScroll(document.scrollingElement.scrollTop - y);
  return back;
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
    window.scrollBy(0, r.top + want);
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
    if (n) { window.scrollBy(0, n.getBoundingClientRect()[edge] - inset); return false; }
  }
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) window.scrollBy(0, h.getBoundingClientRect().top - inset);
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
  const forced = blk && blk.style.contentVisibility !== 'visible';
  if (forced) blk.style.contentVisibility = 'visible';
  const r = target.getBoundingClientRect();
  const margin = gap ?? (parseFloat(getComputedStyle(target).scrollMarginTop) || 0);
  // The top of the page lies under the window toolbar: aim below it.
  const inset = topInset();
  window.scrollBy(0, center ? r.top + r.height / 2 - (window.innerHeight + inset) / 2 : r.top - margin - inset);
  // On screen now: content-visibility keeps it rendered, as it would any block in view.
  if (forced) requestAnimationFrame(() => { blk.style.contentVisibility = ''; });
}

export function atBottom() {
  const se = document.scrollingElement;
  return se.scrollHeight - (se.scrollTop + window.innerHeight) < 48 && se.scrollTop > 0;
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

// Keep blocks above the viewport from pushing content down when their height changes later
// (diagrams, math, images, content-visibility estimates becoming real).
export const resizeObserver = new ResizeObserver(entries => {
  let delta = 0;
  const inset = topInset();
  for (const entry of entries) {
    const el = entry.target;
    const h = el.getBoundingClientRect().height;
    const prev = heights.get(el);
    heights.set(el, h);
    if (prev === undefined || prev === h) continue;
    const r = el.getBoundingClientRect();
    // Entirely above the viewport, or under the toolbar, before it resized.
    if (r.bottom - (h - prev) <= inset + 1) delta += h - prev;
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
