// Reading position: capture and restore the block at the top of the viewport,
// compensate for blocks above it changing height, and resolve #fragments.
import { doc, slots, heights } from './core.js';
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
  return { slot: +el.dataset.slot, offset, ratio: r.height > 0 ? offset / r.height : 0, heading };
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
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) { window.scrollBy(0, h.getBoundingClientRect().top); return; }
  }
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
