// Unread changes: block marks and deletion markers, read detection, jumping
// between changes, and the "Show Only Changes" filter.
import { doc, slots, heights, strings, quicklook, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor } from './anchor.js';
import { scheduleRail } from './rail.js';

let marked = new Map();   // slot -> kind (unread)
const readTimers = new Map();
let changesOnly = false;

export function renderMarks(marks, deletions) {
  for (const el of doc.querySelectorAll('.m-inserted, .m-modified, .m-state')) {
    el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
  }
  doc.querySelectorAll('.del-mark').forEach(e => e.remove());
  marked = new Map();
  if (quicklook) return;
  for (const m of marks) {
    const el = slots.get(m.slot);
    if (!el) continue;
    el.classList.add(`m-${m.kind}`);
    marked.set(m.slot, m.kind);
    readObserver.observe(el);
  }
  for (const d of deletions) {
    const mark = document.createElement('div');
    mark.className = 'del-mark';
    mark.dataset.del = d.id;
    const btn = document.createElement('button');
    btn.title = d.count === 1 ? (strings.deletedOne || '1 block removed') : (strings.deletedMany || '%d blocks removed').replace('%d', d.count);
    btn.setAttribute('aria-label', btn.title);
    btn.addEventListener('click', ev => {
      ev.stopPropagation();
      const open = mark.querySelector('.del-pop');
      document.querySelectorAll('.del-pop').forEach(p => p.remove());
      if (open) return;
      const pop = document.createElement('pre');
      pop.className = 'del-pop';
      pop.textContent = d.preview;
      mark.appendChild(pop);
    });
    mark.appendChild(btn);
    const after = d.after ? slots.get(d.after) : null;
    if (after) after.after(mark);
    else doc.insertBefore(mark, doc.querySelector('.blk'));
    readObserver.observe(mark);
  }
}

document.addEventListener('click', () => document.querySelectorAll('.del-pop').forEach(p => p.remove()));

// A change counts as read once at least half of it has been visible for 800 ms while the window is focused.
const readObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const el = e.target;
    if (e.isIntersecting && e.intersectionRatio >= 0.5) {
      if (!readTimers.has(el)) readTimers.set(el, setTimeout(() => tryRead(el), 800));
    } else {
      clearTimeout(readTimers.get(el));
      readTimers.delete(el);
    }
  }
}, { threshold: [0, 0.5, 1] });

let pendingRead = { slots: [], deletions: [] };
function tryRead(el) {
  readTimers.delete(el);
  if (!document.hasFocus() || document.hidden) {
    // Try again when focus returns.
    readTimers.set(el, setTimeout(() => inViewport(el) && tryRead(el), 1000));
    return;
  }
  readObserver.unobserve(el);
  el.classList.add('m-read');
  if (el.classList.contains('del-mark')) pendingRead.deletions.push(+el.dataset.del);
  else { pendingRead.slots.push(+el.dataset.slot); marked.delete(+el.dataset.slot); }
  clearTimeout(tryRead.flush);
  tryRead.flush = setTimeout(() => {
    post({ type: 'read', ...pendingRead });
    pendingRead = { slots: [], deletions: [] };
    scheduleRail();
  }, 150);
  setTimeout(() => {
    if (el.classList.contains('m-read')) {
      el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
      if (el.classList.contains('del-mark')) el.remove();
    }
  }, 10000);
}

export function unreadElements() {
  // `offsetParent === null` covers `hidden` blocks in changes-only mode, so the
  // rail, jumps and the caught-up state all ignore filtered-out blocks.
  return Array.from(doc.querySelectorAll('.blk.m-inserted:not(.m-read), .blk.m-modified:not(.m-read), .blk.m-state:not(.m-read), .del-mark:not(.m-read)'))
    .filter(e => e.offsetParent !== null);
}

export function jump(dir) {
  const list = unreadElements();
  if (!list.length) return;
  const line = window.innerHeight / 3;
  let target;
  if (dir > 0) target = list.find(e => e.getBoundingClientRect().top > line + 4) || list[0];
  else target = list.slice().reverse().find(e => e.getBoundingClientRect().top < line - 4) || list[list.length - 1];
  const top = target.getBoundingClientRect().top - line;
  window.scrollBy({ top, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
}

export function markAllRead() {
  for (const el of unreadElements()) {
    el.classList.add('m-read');
    readObserver.unobserve(el);
  }
  marked.clear();
  setTimeout(() => {
    doc.querySelectorAll('.m-read').forEach(el => {
      el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
      if (el.classList.contains('del-mark')) el.remove();
    });
    applyChangesOnly();
    scheduleRail();
  }, 700);
}

// ---------------------------------------------------------------- Show Only Changes

const caughtup = document.getElementById('ro-caughtup');

/**
 * "Show Only Changes": hides read blocks so the reader sees just what's new.
 * Headings stay visible as context; blocks with unread marks or deletion
 * markers (and headings) are kept. Hidden blocks leave the anchor and jump
 * math untouched — `unreadElements()` already skips them via offsetParent.
 */
export function applyChangesOnly() {
  for (const el of slots.values()) {
    const keep = el.classList.contains('k-heading')
      || el.classList.contains('m-inserted') || el.classList.contains('m-modified')
      || el.classList.contains('m-state') || el.nextElementSibling?.classList.contains('del-mark');
    el.hidden = changesOnly && !keep;
    // Hiding/showing is a filter, not a content change: re-baseline the
    // height so the resize compensator does not "correct" the reflow that
    // anchor restore already accounts for (double compensation scrolls away).
    heights.set(el, el.hidden ? 0 : el.getBoundingClientRect().height);
  }
  for (const m of doc.querySelectorAll('.del-mark')) m.hidden = false;
  if (caughtup) {
    const anyVisible = changesOnly && unreadElements().length === 0 && slots.size > 0;
    caughtup.textContent = anyVisible ? (strings.caughtUp || 'All caught up') : '';
    caughtup.hidden = !anyVisible;
  }
  scheduleRail();
}

/** Sets the filter without moving (initial appearance). */
export function initChangesOnly(on) { changesOnly = !!on; applyChangesOnly(); }

export function setChangesOnly(on) {
  // Toggling the filter reflows the document: capture first, restore after,
  // so the reader keeps their place (with nearest-visible fallback).
  const anchor = captureAnchor();
  changesOnly = !!on;
  applyChangesOnly();
  restoreAnchor(anchor, new Set());
}
