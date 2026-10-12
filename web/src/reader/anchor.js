// Reading position: capture and restore the block at the top of the viewport,
// compensate for blocks above it changing height, and resolve #fragments.
import { doc, root, slots, heights } from './core.js';
import { scheduleRail } from './rail.js';

export function isShown(e) { return !e.hidden && e.offsetParent !== null; }

function blockList() { return Array.from(doc.children).filter(e => e.classList.contains('blk') && isShown(e)); }

/** First block whose bottom edge is below the top of the viewport. */
function topBlock() {
  const list = blockList();
  let lo = 0, hi = list.length - 1, found = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const r = list[mid].getBoundingClientRect();
    if (r.bottom > 8) { found = list[mid]; hi = mid - 1; } else { lo = mid + 1; }
  }
  return found;
}

export function captureAnchor() {
  const el = topBlock();
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const offset = -r.top;
  let heading = null;
  for (let e = el; e; e = e.previousElementSibling) {
    if (e.classList.contains('k-heading')) { heading = e.dataset.anchor || null; break; }
  }
  // The neighbours stand in for the anchor block if a patch removes it.
  const prev = shownSibling(el, 'previousElementSibling');
  const next = shownSibling(el, 'nextElementSibling');
  return { slot: +el.dataset.slot, offset, ratio: r.height > 0 ? offset / r.height : 0, heading,
    prev: prev ? +prev.dataset.slot : null, next: next ? +next.dataset.slot : null };
}

function shownSibling(el, dir) {
  for (let e = el[dir]; e; e = e[dir]) if (e.classList.contains('blk') && isShown(e)) return e;
  return null;
}

export function restoreAnchor(a, changedSlots) {
  if (!a) return;
  let el = slots.get(a.slot);
  // The anchor block may have been hidden by the changes-only filter (or
  // removed): fall back to the nearest visible block in document order,
  // preferring the previous one so the reader stays with what they read.
  if (el && !isShown(el)) el = nearestVisible(el);
  if (el) {
    const r = el.getBoundingClientRect();
    const want = changedSlots.has(a.slot) ? a.ratio * r.height : a.offset;
    window.scrollBy(0, r.top + want);
    return;
  }
  // The anchor block is gone: the block that followed it takes its place at
  // the top (or, at the end of the document, the one before it ends there).
  // Only then the section heading, which can be far above.
  for (const [slot, edge] of [[a.next, 'top'], [a.prev, 'bottom']]) {
    let n = slot != null ? slots.get(slot) : null;
    if (n && !isShown(n)) n = nearestVisible(n);
    if (n) { window.scrollBy(0, n.getBoundingClientRect()[edge]); return; }
  }
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) { window.scrollBy(0, h.getBoundingClientRect().top); return; }
  }
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
 * place within it is kept as a fraction of its height.
 */
export function keepPlace(change, { ratio = false, anchor = captureAnchor() } = {}) {
  change();
  if (anchor) restoreAnchor(anchor, ratio ? new Set([anchor.slot]) : new Set());
  rebaselineHeights();
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

// Keep blocks above the viewport from pushing content down when their height changes later
// (diagrams, math, images, content-visibility estimates becoming real).
export const resizeObserver = new ResizeObserver(entries => {
  let delta = 0;
  for (const entry of entries) {
    const el = entry.target;
    const h = el.getBoundingClientRect().height;
    const prev = heights.get(el);
    heights.set(el, h);
    if (prev === undefined || prev === h) continue;
    const r = el.getBoundingClientRect();
    if (r.bottom <= 1) delta += h - prev; // entirely above the viewport
  }
  if (delta !== 0 && document.scrollingElement.scrollTop > 0) window.scrollBy(0, delta);
  scheduleRail();
});
