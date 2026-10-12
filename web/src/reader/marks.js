// Unread changes: block marks and deletion markers, read detection, jumping
// between changes, and the "Show Only Changes" filter.
import { doc, slots, heights, strings, quicklook, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor, isShown } from './anchor.js';
import { scheduleRail } from './rail.js';

let marked = new Map();   // slot -> kind (unread)
const diffOf = new Map();   // slot -> word-level comparison HTML of an edited block ("" = no earlier text)
const openDiffs = new Set(); // slots whose comparison is shown
const previewOf = new Map(); // deletion id -> removed text (each patch sends it once)
const readTimers = new Map();
let changesOnly = false;

export function renderMarks(marks, deletions, reset = false) {
  // Comparisons and removed texts arrive once; later patches leave them out.
  if (reset) { diffOf.clear(); previewOf.clear(); }
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
    if (m.kind === 'modified' && typeof m.diff === 'string') diffOf.set(m.slot, m.diff);
    else if (m.kind === 'inserted') diffOf.delete(m.slot);
    readObserver.observe(el);
  }
  // Once read, the mark fades, but the comparison stays one click away in
  // the same place (the gutter of the block) until the block changes again.
  for (const [slot] of diffOf) slots.get(slot)?.classList.add('wd-has');
  // An open comparison stays open across patches (reading it marks the
  // block read, which must not take it away); it follows the latest one.
  for (const slot of [...openDiffs]) {
    const el = slots.get(slot);
    if (!el || !diffOf.has(slot)) { closeDiff(slot); continue; }
    showDiff(el, diffOf.get(slot));
  }
  for (const slot of [...diffOf.keys()]) if (!slots.has(slot)) diffOf.delete(slot);
  for (const d of deletions) if (typeof d.preview === 'string') previewOf.set(d.id, d.preview);
  const live = new Set(deletions.map(d => d.id));
  for (const id of [...previewOf.keys()]) if (!live.has(id)) previewOf.delete(id);
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
      pop.textContent = previewOf.get(d.id) ?? '';
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

// ---------------------------------------------------------------- What changed in an edited block

/** The comparison panel at the end of an edited block (shown, or refreshed). */
function showDiff(el, html) {
  let panel = el.querySelector(':scope > .wd-panel');
  if (!panel) {
    panel = document.createElement('div');
    panel.className = 'wd-panel';
    panel.setAttribute('role', 'region');
    const label = document.createElement('div');
    label.className = 'wd-label';
    panel.appendChild(label);
    const body = document.createElement('pre');
    body.className = 'wd-body';
    panel.appendChild(body);
    el.appendChild(panel);
  }
  const label = strings.changesSince || 'Changes since you last read';
  panel.setAttribute('aria-label', label);
  panel.firstChild.textContent = label;
  const body = panel.lastChild;
  if (html) { body.innerHTML = html; body.classList.remove('wd-none'); }
  else { body.textContent = strings.noEarlierText || 'The earlier text was not kept, so there is nothing to compare with.'; body.classList.add('wd-none'); }
  el.classList.add('wd-open');
  openDiffs.add(+el.dataset.slot);
}

function closeDiff(slot) {
  openDiffs.delete(slot);
  const el = slots.get(slot);
  if (!el) return;
  el.querySelector(':scope > .wd-panel')?.remove();
  el.classList.remove('wd-open');
}

/** A block's content was replaced: its old comparison no longer applies (the patch's marks bring a new one). */
export function forgetDiff(slot) { diffOf.delete(slot); }

/**
 * D: opens the comparison of the topmost edited block in view that is still
 * closed, so repeated presses walk down the screen; once every one in view
 * is open, closes them all. The blocks in view when the walk started stay in
 * it while one of them is still in view, so a tall comparison that pushes
 * the next block off screen does not skip it.
 */
let walk = [];
export function toggleDiffInView() {
  const live = slot => { const el = slots.get(slot); return el && diffOf.has(slot) && isShown(el) ? el : null; };
  const inView = [...diffOf.keys()].map(live).filter(el => el && inViewport(el));
  if (!inView.length) { walk = []; return false; }
  const viewed = new Set(inView.map(el => +el.dataset.slot));
  if (!walk.some(slot => viewed.has(slot))) walk = [];
  const all = [...new Set([...walk, ...viewed])].map(live).filter(Boolean)
    .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
  walk = all.map(el => +el.dataset.slot);
  const closed = all.find(el => !openDiffs.has(+el.dataset.slot));
  if (closed) return toggleDiff(+closed.dataset.slot);
  walk = [];
  const anchor = captureAnchor();
  for (const el of all) { closeDiff(+el.dataset.slot); heights.set(el, el.getBoundingClientRect().height); }
  restoreAnchor(anchor, new Set());
  scheduleRail();
  return false;
}

/** Shows or hides what changed in an edited block, keeping the reader's place. */
export function toggleDiff(slot) {
  const el = slots.get(slot);
  if (!el || !diffOf.has(slot)) return false;
  const anchor = captureAnchor();
  if (openDiffs.has(slot)) closeDiff(slot); else showDiff(el, diffOf.get(slot));
  // The panel is part of the block, not new content: keep the height baseline.
  heights.set(el, el.getBoundingClientRect().height);
  restoreAnchor(anchor, new Set());
  scheduleRail();
  return openDiffs.has(slot);
}

// The edit mark in the gutter opens the comparison: a click on an edited
// block left of its text.
doc.addEventListener('click', ev => {
  const el = ev.target.closest('#ro-doc > .blk.wd-has');
  if (!el || ev.target.closest('a, button, .wd-panel')) return;
  const text = el.firstElementChild;
  if (!text || ev.clientX >= text.getBoundingClientRect().left) return;
  ev.stopPropagation();
  toggleDiff(+el.dataset.slot);
});

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
  const toggled = [];
  for (const el of slots.values()) {
    const keep = el.classList.contains('k-heading')
      || el.classList.contains('m-inserted') || el.classList.contains('m-modified')
      || el.classList.contains('m-state') || el.nextElementSibling?.classList.contains('del-mark');
    const hide = changesOnly && !keep;
    if (el.hidden !== hide) { el.hidden = hide; toggled.push(el); }
  }
  // Hiding/showing is a filter, not a content change: re-baseline the
  // height so the resize compensator does not "correct" the reflow that
  // anchor restore already accounts for (double compensation scrolls away).
  // Read after all writes: one layout, not one per block.
  for (const el of toggled) heights.set(el, el.hidden ? 0 : el.getBoundingClientRect().height);
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
