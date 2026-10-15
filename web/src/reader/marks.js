// Unread changes: block marks and deletion markers, read detection, jumping
// between changes, and the "Show Only Changes" filter.
import { doc, slots, heights, strings, quicklook, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor, isShown, atBottom } from './anchor.js';
import { scheduleRail } from './rail.js';

let marked = new Map();   // slot -> kind (unread)
const diffOf = new Map();   // slot -> word-level comparison HTML of an edited block ("" = no earlier text)
const openDiffs = new Set(); // slots whose comparison is shown
const previewOf = new Map(); // deletion id -> removed text (each patch sends it once)
const readTimers = new Map();
let changesOnly = false;
let printing = false;   // printing shows the whole document

export function renderMarks(marks, deletions, reset = false) {
  // Comparisons and removed texts arrive once; later patches leave them out.
  if (reset) { diffOf.clear(); previewOf.clear(); }
  for (const el of doc.querySelectorAll('.m-inserted, .m-modified, .m-state')) {
    el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
  }
  // A removed-text popup the reader has open stays open across the rebuild.
  const openPops = reset ? new Set()
    : new Set([...doc.querySelectorAll('.del-mark')].filter(m => m.querySelector('.del-pop')).map(m => +m.dataset.del));
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
      showPop(mark, d.id);
    });
    mark.appendChild(btn);
    if (openPops.has(d.id)) showPop(mark, d.id);
    const after = d.after ? slots.get(d.after) : null;
    if (after) after.after(mark);
    else doc.insertBefore(mark, doc.querySelector('.blk'));
    readObserver.observe(mark);
  }
}

function showPop(mark, id) {
  const pop = document.createElement('pre');
  pop.className = 'del-pop';
  pop.textContent = previewOf.get(id) ?? '';
  mark.appendChild(pop);
}

// A click elsewhere closes it; one inside it is the reader selecting the text to copy.
document.addEventListener('click', ev => {
  if (ev.target.closest && ev.target.closest('.del-pop')) return;
  document.querySelectorAll('.del-pop').forEach(p => p.remove());
});

/** Escape: closes the removed-text popups and the comparisons open. Returns whether there were any. */
export function closePopups() {
  const pops = document.querySelectorAll('.del-pop');
  pops.forEach(p => p.remove());
  if (!openDiffs.size) return pops.length > 0;
  const anchor = captureAnchor();
  for (const slot of [...openDiffs]) {
    closeDiff(slot);
    const el = slots.get(slot);
    if (el) heights.set(el, el.getBoundingClientRect().height);
  }
  walk = [];
  restoreAnchor(anchor, new Set());
  scheduleRail();
  return true;
}

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

// A change counts as read once at least half of it (or, for a block taller
// than two screens, half a screen of it) has been visible for 800 ms while
// the window is focused. The fine thresholds report a tall block's visible
// part as it grows.
//
// A window on screen but not focused is the reader watching an agent from
// the terminal beside it: what arrives at the end they follow is read too,
// once it has been in view for 1.5 s while they still follow the end. Read
// anywhere else, or in a window hidden or minimised, a change waits for the
// window to come back.
const DWELL_MS = 800;
const DWELL_UNFOCUSED_MS = 1500;
const readSince = new Map();   // element -> when its dwell started
function armRead(el, ms = DWELL_MS) {
  waiting.delete(el);
  readSince.set(el, performance.now());
  readTimers.set(el, setTimeout(() => tryRead(el), ms));
}
function disarmRead(el) {
  clearTimeout(readTimers.get(el));
  readTimers.delete(el);
  readSince.delete(el);
  waiting.delete(el);
}
const readThresholds = [0];
for (let i = 1; i <= 10; i++) readThresholds.push(i / 100);
for (let i = 3; i <= 20; i++) readThresholds.push(i / 20);
const readObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const el = e.target;
    const screen = e.rootBounds ? e.rootBounds.height : window.innerHeight;
    if (e.isIntersecting && (e.intersectionRatio >= 0.5 || e.intersectionRect.height >= screen / 2)) {
      if (!readTimers.has(el)) armRead(el);
    } else {
      disarmRead(el);
    }
  }
}, { threshold: readThresholds });

/** On screen, but another window has the focus: read only at the end the reader follows. */
const watching = () => !document.hidden && !document.hasFocus();

// Seen long enough while the window was in the background (or away from
// the end): they wait, in view, for the reader to come back, and are read
// once seen for the full time after that (not right away: coming back is
// not reading them). Back at the end of an unfocused window counts as
// coming back, for the longer time.
const waiting = new Set();
function restartDwell() {
  if (document.hidden) return;
  if (!document.hasFocus()) {
    if (!waiting.size || !atBottom()) return;
    for (const el of waiting) if (el.isConnected) armRead(el, DWELL_UNFOCUSED_MS);
    waiting.clear();
    return;
  }
  for (const el of new Set([...waiting, ...readTimers.keys()])) {
    disarmRead(el);
    if (el.isConnected) armRead(el);
  }
  waiting.clear();
}
window.addEventListener('focus', restartDwell);
document.addEventListener('visibilitychange', restartDwell);
window.addEventListener('scroll', () => { if (waiting.size && watching()) restartDwell(); }, { passive: true });

function tryRead(el) {
  readTimers.delete(el);
  if (document.hidden) { waiting.add(el); return; }
  if (!document.hasFocus()) {
    if (!atBottom()) { waiting.add(el); return; }
    const left = DWELL_UNFOCUSED_MS - (performance.now() - (readSince.get(el) ?? 0));
    if (left > 1) { readTimers.set(el, setTimeout(() => tryRead(el), left)); return; }
  }
  markRead(el);
}

let pendingRead = { slots: [], deletions: [] };
function markRead(el) {
  if (el.classList.contains('m-read')) return;
  disarmRead(el);
  readObserver.unobserve(el);
  el.classList.add('m-read');
  if (el.classList.contains('del-mark')) pendingRead.deletions.push(+el.dataset.del);
  else { pendingRead.slots.push(+el.dataset.slot); marked.delete(+el.dataset.slot); }
  clearTimeout(markRead.flush);
  markRead.flush = setTimeout(() => {
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

// A change N, Shift-N or a rail tick went to is read once it has been on
// screen for 300 ms, or when N leaves it after 250 ms: pressing through the
// changes is reading them, faster than the dwell above.
const VISIT_READ_MS = 300;
const VISIT_LEAVE_MS = 250;
const VISIT_POLL_MS = 50;
const VISIT_GIVE_UP_MS = 3000;   // a scroll that never brings it on screen
let visited = null;   // {el, at, shown, timer}

/** The reader went to change `el` (N or a rail tick). */
export function visit(el) {
  leaveVisit();
  const v = visited = { el, at: performance.now(), shown: null, timer: 0 };
  const check = () => {
    if (visited !== v) return;
    const now = performance.now();
    if (!el.isConnected || el.classList.contains('m-read') || now - v.at > VISIT_GIVE_UP_MS) { visited = null; return; }
    if (!inViewport(el)) v.shown = null;
    else if (v.shown === null) v.shown = now;
    if (v.shown !== null && now - v.shown >= VISIT_READ_MS) { visited = null; markRead(el); return; }
    v.timer = setTimeout(check, VISIT_POLL_MS);
  };
  v.timer = setTimeout(check, VISIT_POLL_MS);
}

function leaveVisit() {
  const v = visited;
  if (!v) return;
  visited = null;
  clearTimeout(v.timer);
  if (v.el.isConnected && performance.now() - v.at >= VISIT_LEAVE_MS) markRead(v.el);
}

export function unreadElements() {
  // `offsetParent === null` covers `hidden` blocks in changes-only mode, so the
  // rail, jumps and the caught-up state all ignore filtered-out blocks.
  return Array.from(doc.querySelectorAll('.blk.m-inserted:not(.m-read), .blk.m-modified:not(.m-read), .blk.m-state:not(.m-read), .del-mark:not(.m-read)'))
    .filter(e => e.offsetParent !== null);
}

export function jump(dir) {
  leaveVisit();
  const list = unreadElements();
  // Nothing to go to: the app says so (a beep).
  if (!list.length) { post({ type: 'nothing' }); return; }
  const line = window.innerHeight / 3;
  let target = dir > 0 ? list.find(e => e.getBoundingClientRect().top > line + 4)
    : list.slice().reverse().find(e => e.getBoundingClientRect().top < line - 4);
  // Past the last change, back to the first (or the other way): the app says so too.
  if (!target) {
    target = dir > 0 ? list[0] : list[list.length - 1];
    post({ type: 'wrapped' });
  }
  const top = target.getBoundingClientRect().top - line;
  // In a large document the blocks a smooth scroll passes are laid out on
  // the way and change height, and the compensation for them fights the
  // animation: jump at once, then aim again once the blocks around the
  // target have their real heights.
  const smooth = !doc.classList.contains('cv') && !matchMedia('(prefers-reduced-motion: reduce)').matches;
  window.scrollBy({ top, behavior: smooth ? 'smooth' : 'auto' });
  focusBlock(target);
  visit(target);
  if (!smooth) {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!target.isConnected) return;
      const off = target.getBoundingClientRect().top - line;
      if (Math.abs(off) > 2) window.scrollBy(0, off);
    }));
  }
}

/**
 * Keyboard focus goes where a jump went, so Tab continues from there and
 * VoiceOver reads it; the jump has scrolled already.
 */
export function focusBlock(el) {
  if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '-1');
  el.focus({ preventScroll: true });
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
let filtered = false;   // the filter may have hidden blocks
export function applyChangesOnly() {
  const on = changesOnly && !printing;
  // Off, and nothing hidden by it: no walk over every block (each patch of
  // a large document comes here).
  if (!on && !filtered) {
    if (caughtup && !caughtup.hidden) { caughtup.textContent = ''; caughtup.hidden = true; }
    scheduleRail();
    return;
  }
  filtered = on;
  const toggled = [];
  for (const el of slots.values()) {
    const keep = el.classList.contains('k-heading')
      || el.classList.contains('m-inserted') || el.classList.contains('m-modified')
      || el.classList.contains('m-state') || el.nextElementSibling?.classList.contains('del-mark');
    const hide = on && !keep;
    if (el.hidden !== hide) { el.hidden = hide; toggled.push(el); }
  }
  // Hiding/showing is a filter, not a content change: re-baseline the
  // height so the resize compensator does not "correct" the reflow that
  // anchor restore already accounts for (double compensation scrolls away).
  // Read after all writes: one layout, not one per block.
  for (const el of toggled) heights.set(el, el.hidden ? 0 : el.getBoundingClientRect().height);
  for (const m of doc.querySelectorAll('.del-mark')) m.hidden = false;
  if (caughtup) {
    const anyVisible = on && unreadElements().length === 0 && slots.size > 0;
    caughtup.textContent = anyVisible ? (strings.caughtUp || 'All caught up') : '';
    caughtup.hidden = !anyVisible;
  }
  scheduleRail();
}

/** Lifts the filter while printing (the caller keeps the place). */
export function setPrinting(on) { printing = !!on; applyChangesOnly(); }

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
