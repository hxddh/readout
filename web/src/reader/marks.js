// Unread changes: block marks and deletion markers, read detection, jumping
// between changes, and the "Show Only Changes" filter.
import { doc, slots, heights, strings, quicklook, post, inViewport, onKeptScroll, blocksHidden, setBlocksHidden, focused } from './core.js';
import { captureAnchor, restoreAnchor, isShown, atBottom, fitsOnScreen, topInset, pinLanding } from './anchor.js';
import { scheduleRail } from './rail.js';

let marked = new Map();   // slot -> kind (unread)
const classed = new Map(); // slot -> the mark its block carries (unread, or read and fading)
const delMarks = new Map(); // deletion id -> its marker
let unreadOrder = null;    // the unread elements in document order (null: not worked out since the last patch)
const diffOf = new Map();   // slot -> word-level comparison HTML of an edited block ("" = no earlier text)
const openDiffs = new Set(); // slots whose comparison is shown
const previewOf = new Map(); // deletion id -> removed text (each patch sends it once)
const readTimers = new Map();
let changesOnly = false;
let printing = false;   // printing shows the whole document

export function renderMarks(marks, deletions, reset = false) {
  // Comparisons and removed texts arrive once; later patches leave them out.
  if (reset) { diffOf.clear(); previewOf.clear(); arrivals.clear(); }
  unreadOrder = null;
  if (quicklook) return;
  const next = new Map();
  for (const m of marks) if (slots.has(m.slot)) next.set(m.slot, m);
  // Only blocks whose mark changed are touched: a patch to a large document
  // restyles none of the others (and searches none of them out).
  for (const [slot, kind] of classed) {
    const el = slots.get(slot);
    if (el && next.get(slot)?.kind === kind) continue;
    classed.delete(slot);
    if (!el) continue;
    el.classList.remove(`m-${kind}`, 'm-read');
    if (!next.has(slot)) { disarmRead(el); readObserver.unobserve(el); }
  }
  const before = marked;
  marked = new Map();
  const now = performance.now();
  for (const [slot, m] of next) {
    const el = slots.get(slot);
    const cls = `m-${m.kind}`;
    // (A replaced block lost its classes: it gets them again.)
    if (!el.classList.contains(cls)) {
      el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
      el.classList.add(cls);
    }
    classed.set(slot, m.kind);
    if (m.kind === 'modified' && typeof m.diff === 'string') diffOf.set(slot, m.diff);
    else if (m.kind === 'inserted') diffOf.delete(slot);
    // Read here, and the app has not heard yet (or this patch was on its
    // way when it did): it stays read.
    if (el.classList.contains('m-read')) continue;
    marked.set(slot, m.kind);
    if (!reset && !before.has(slot)) arrivals.set(el, now);
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
  // Markers stay from patch to patch (a removed-text popup open in one
  // stays open; one read stays read); those no longer sent go.
  for (const [id, mark] of delMarks) if (!live.has(id)) dropDelMark(id, mark);
  let firstBlock;
  for (const d of deletions) {
    let mark = delMarks.get(d.id);
    if (!mark) {
      mark = makeDelMark(d.id);
      delMarks.set(d.id, mark);
      if (!reset) arrivals.set(mark, now);
      readObserver.observe(mark);
    }
    const title = d.count === 1 ? (strings.deletedOne || '1 block removed') : (strings.deletedMany || '%d blocks removed').replace('%d', d.count);
    const btn = mark.firstChild;
    if (btn.title !== title) { btn.title = title; btn.setAttribute('aria-label', title); }
    const after = d.after ? slots.get(d.after) : null;
    if (after) { if (after.nextElementSibling !== mark) after.after(mark); }
    else {
      if (firstBlock === undefined) firstBlock = doc.querySelector(':scope > .blk');
      if (mark.nextElementSibling !== firstBlock || !mark.isConnected) doc.insertBefore(mark, firstBlock);
    }
  }
  scheduleShow();
}

function makeDelMark(id) {
  const mark = document.createElement('div');
  mark.className = 'del-mark';
  mark.dataset.del = id;
  const btn = document.createElement('button');
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    const open = mark.querySelector('.del-pop');
    document.querySelectorAll('.del-pop').forEach(p => p.remove());
    if (open) return;
    showPop(mark, id);
  });
  mark.appendChild(btn);
  return mark;
}

function dropDelMark(id, mark) {
  readObserver.unobserve(mark);
  disarmRead(mark);
  mark.remove();
  if (delMarks.get(id) === mark) delMarks.delete(id);
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
  // Nothing in view to compare: the app says so (a beep), as for N.
  if (!inView.length) { walk = []; post({ type: 'nothing' }); return false; }
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
const readDue = new Map();     // element -> when its dwell ends
function armRead(el, ms = DWELL_MS) {
  waiting.delete(el);
  readSince.set(el, performance.now());
  readAt(el, ms);
}
function readAt(el, ms) {
  readDue.set(el, performance.now() + ms);
  readTimers.set(el, setTimeout(() => tryRead(el), ms));
}
function disarmRead(el) {
  clearTimeout(readTimers.get(el));
  readTimers.delete(el);
  readSince.delete(el);
  readDue.delete(el);
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
export const watching = () => !document.hidden && !focused();
/**
 * At the end the reader follows, or with the whole document on screen: a
 * page that fits the window has no end to scroll to, and a reader watching
 * it sees all of it.
 */
const atEnd = () => atBottom() || fitsOnScreen();

// Seen long enough while the window was in the background (or away from
// the end): they wait, in view, for the reader to come back, and are read
// once seen for the full time after that (not right away: coming back is
// not reading them). Back at the end of an unfocused window counts as
// coming back, for the longer time.
const waiting = new Set();
export function restartDwell() {
  if (document.hidden) return;
  if (!focused()) {
    if (!waiting.size || !atEnd()) return;
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
  readDue.delete(el);
  if (document.hidden) { waiting.add(el); return; }
  if (!focused()) {
    if (!atEnd()) { waiting.add(el); return; }
    const left = DWELL_UNFOCUSED_MS - (performance.now() - (readSince.get(el) ?? 0));
    if (left > 1) { readAt(el, left); return; }
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
  markRead.flush = setTimeout(flushRead, 150);
  setTimeout(() => { if (el.classList.contains('m-read')) unmark(el); }, 10000);
}

/** A read mark's fade is over: the block carries no mark, a removal marker goes. */
function unmark(el) {
  if (el.classList.contains('del-mark')) { dropDelMark(+el.dataset.del, el); return; }
  el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
  const slot = +el.dataset.slot;
  if (slots.get(slot) === el) classed.delete(slot);
}

function flushRead() {
  clearTimeout(markRead.flush);
  if (!pendingRead.slots.length && !pendingRead.deletions.length) return;
  post({ type: 'read', ...pendingRead });
  pendingRead = { slots: [], deletions: [] };
  scheduleRail();
}

// The app shows how many changes are unread (the toolbar badge, the
// outline's dots, the tab's dot). A change that arrives where the reader is
// reading (the end they follow while an agent writes) is read within its
// dwell: shown as unread meanwhile, the badge and dots blink with every
// paragraph. So the page tells the app when what a patch added is to be
// shown ({type:'showUnread'}): at once for changes nobody is reading (off
// screen, a hidden window), after SHOW_HOLD_MS for changes whose dwell is
// running (a dwell running then holds it until the dwell ends, up to
// SHOW_HOLD_MAX_MS), and after their read once they are all read. The read
// is posted first, so the app never counts them. Fewer unread changes (a
// read, a removal) show at once; that is the app's own.
const SHOW_SETTLE_MS = 100;   // the read observer has had its look at what arrived
const SHOW_HOLD_MS = 1200;
const SHOW_HOLD_MAX_MS = 2000;
const arrivals = new Map();   // newly unread element -> when it arrived
let showTimer = 0;
function scheduleShow() {
  if (!showTimer && arrivals.size) showTimer = setTimeout(checkShow, SHOW_SETTLE_MS);
}
function checkShow() {
  showTimer = 0;
  const now = performance.now();
  let show = false;
  for (const [el, at] of arrivals) {
    if (!isUnread(el)) { arrivals.delete(el); continue; }
    const age = now - at;
    const due = readDue.get(el);
    const reading = due !== undefined && age < SHOW_HOLD_MAX_MS && (age < SHOW_HOLD_MS || now < due + 50);
    if (age >= SHOW_SETTLE_MS && !reading) show = true;
  }
  if (show || !arrivals.size) {
    arrivals.clear();
    flushRead();
    post({ type: 'showUnread' });
    return;
  }
  showTimer = setTimeout(checkShow, VISIT_POLL_MS * 2);
}

// A change N, Shift-N or a rail tick went to is read once it has been on
// screen for 300 ms, or when N leaves it after 250 ms: pressing through the
// changes is reading them, faster than the dwell above. N goes to a run of
// unread blocks (blocks one after the other) as one change: what of the
// run is on screen is read the same way.
const VISIT_READ_MS = 300;
const VISIT_LEAVE_MS = 250;
const VISIT_POLL_MS = 50;
const VISIT_GIVE_UP_MS = 3000;   // a scroll that never brings it on screen
let visited = null;   // {el, run, at, shown, timer}

/** Most of it on screen (all of a short block, half of a tall one, half a screen of a very tall one). */
function seen(el) {
  const r = el.getBoundingClientRect();
  const inset = topInset();
  if (r.bottom < inset || r.top > window.innerHeight) return false;
  const visible = Math.min(r.bottom, window.innerHeight) - Math.max(r.top, inset);
  return visible >= Math.min(r.height / 2, window.innerHeight / 2);
}

/** The reader went to change `el` (N or a rail tick); `run`: the unread blocks it begins. */
export function visit(el, run = [el]) {
  leaveVisit();
  const v = visited = { el, run, at: performance.now(), shown: new Map(), timer: 0 };
  const check = () => {
    if (visited !== v) return;
    const now = performance.now();
    if (now - v.at > VISIT_GIVE_UP_MS) { visited = null; return; }
    let left = 0;
    for (const m of v.run) {
      if (!m.isConnected || m.classList.contains('m-read')) continue;
      if (!(m === el ? inViewport(m) : seen(m))) { v.shown.delete(m); left++; continue; }
      if (!v.shown.has(m)) v.shown.set(m, now);
      if (now - v.shown.get(m) >= VISIT_READ_MS) markRead(m); else left++;
    }
    if (!left) { visited = null; return; }
    v.timer = setTimeout(check, VISIT_POLL_MS);
  };
  v.timer = setTimeout(check, VISIT_POLL_MS);
}

function leaveVisit() {
  const v = visited;
  if (!v) return;
  visited = null;
  clearTimeout(v.timer);
  if (performance.now() - v.at < VISIT_LEAVE_MS) return;
  for (const m of v.run) if (m.isConnected && (m === v.el || seen(m))) markRead(m);
}

/** Whether `el` is an unread change (a block with an unread mark, or a removal marker not read). */
function isUnread(el) {
  if (!el.isConnected || el.classList.contains('m-read')) return false;
  if (el.classList.contains('del-mark')) return delMarks.get(+el.dataset.del) === el;
  const slot = +el.dataset.slot;
  return marked.has(slot) && slots.get(slot) === el;
}

export function unreadElements() {
  if (!unreadOrder) {
    const els = [];
    for (const slot of marked.keys()) { const el = slots.get(slot); if (el) els.push(el); }
    for (const m of delMarks.values()) els.push(m);
    unreadOrder = inDocumentOrder(els);
  }
  // `offsetParent === null` covers `hidden` blocks in changes-only mode, so the
  // rail, jumps and the caught-up state all ignore filtered-out blocks.
  return unreadOrder.filter(e => isUnread(e) && (!blocksHidden || e.offsetParent !== null));
}

function inDocumentOrder(els) {
  if (els.length < 2) return els;
  // Many of them: one walk over the page costs less than sorting them.
  if (els.length * 16 > doc.children.length) {
    const want = new Set(els);
    const out = [];
    for (let e = doc.firstElementChild; e; e = e.nextElementSibling) if (want.has(e)) out.push(e);
    return out;
  }
  return els.sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
}

/** The block or removal marker shown right after `el` (null: none). */
function nextShown(el) {
  for (let e = el.nextElementSibling; e; e = e.nextElementSibling) {
    if (!e.classList.contains('blk') && !e.classList.contains('del-mark')) continue;
    if (blocksHidden && e.offsetParent === null) continue;
    return e;
  }
  return null;
}

// Where an outline click, G, Home / End or a #section landed: N goes on
// from the top of what landed there (not from a third down the screen, past
// the changes right under the heading clicked), until the reader scrolls.
let landing = null;   // {el, y}: el null for the top of the screen
onKeptScroll(dy => { if (landing) landing.y += dy; });
export function noteLanding(el = null) {
  landing = { el, y: document.scrollingElement.scrollTop };
}

/** `first`: to the first unread change of the document (N arriving from another document). */
export function jump(dir, first = false) {
  const left = visited;
  leaveVisit();
  const land = landing && Math.abs(document.scrollingElement.scrollTop - landing.y) <= 2
    && (!landing.el || landing.el.isConnected) ? landing : null;
  landing = null;
  const list = unreadElements();
  // Nothing to go to: the app goes on to the next document with unread
  // changes, and beeps when there is none (`jump`: N's, not D's).
  if (!list.length) { post({ type: 'nothing', jump: true }); return; }
  // Runs: unread blocks one right after the other.
  const run = [0];
  for (let i = 1; i < list.length; i++) run.push(nextShown(list[i - 1]) === list[i] ? run[i - 1] : run[i - 1] + 1);
  // What the change left behind showed of its run is read (or about to be).
  const skip = new Set(left ? left.run.filter(m => m !== left.el && m.isConnected && seen(m)) : []);
  const line = window.innerHeight / 3;
  const from = land ? (land.el ? land.el.getBoundingClientRect().top : topInset()) : null;
  const tops = list.map(e => e.getBoundingClientRect().top);
  let i = -1;
  if (first) i = 0;
  else if (dir > 0) i = list.findIndex((e, k) => !skip.has(e) && (from !== null ? tops[k] >= from - 4 : tops[k] > line + 4));
  else for (let k = list.length - 1; k >= 0; k--) if (!skip.has(list[k]) && tops[k] < (from !== null ? from : line) - 4) { i = k; break; }
  // Past the last change, back to the first (or the other way): the app says so too.
  if (i < 0) {
    i = dir > 0 ? 0 : list.length - 1;
    post({ type: 'wrapped' });
  }
  // Back to a run: to its first block.
  if (dir < 0) while (i > 0 && run[i - 1] === run[i] && !skip.has(list[i - 1])) i--;
  const target = list[i];
  const members = list.filter((e, k) => k >= i && run[k] === run[i]);
  const top = target.getBoundingClientRect().top - line;
  // In a large document the blocks a smooth scroll passes are laid out on
  // the way and change height, and the compensation for them fights the
  // animation: jump at once, then aim again once the blocks around the
  // target have their real heights.
  const smooth = !doc.classList.contains('cv') && !matchMedia('(prefers-reduced-motion: reduce)').matches;
  window.scrollBy({ top, behavior: smooth ? 'smooth' : 'auto' });
  // The change it lands on stays where it landed while the blocks around it
  // are laid out (not the first block on screen, the resize compensation's
  // usual choice).
  if (!smooth) pinLanding(target);
  focusBlock(target);
  pulse(target);
  visit(target, members);
  if (!smooth) {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!target.isConnected) return;
      const off = target.getBoundingClientRect().top - line;
      if (Math.abs(off) > 2) { window.scrollBy(0, off); pinLanding(target); }
    }));
  }
}

/**
 * Where a jump went shows for a moment (reader.css: .landed, none with
 * reduced motion), most of all when the page could not scroll there: the
 * change was on screen already, or the document is too short.
 */
export function pulse(el) {
  el.classList.remove('landed');
  void el.offsetWidth;
  el.classList.add('landed');
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
  const read = unreadElements();
  for (const el of read) {
    el.classList.add('m-read');
    readObserver.unobserve(el);
    disarmRead(el);
  }
  marked.clear();
  setTimeout(() => {
    for (const el of read) if (el.classList.contains('m-read')) unmark(el);
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
  setBlocksHidden(on);
  for (const el of toggled) heights.set(el, el.hidden ? 0 : el.getBoundingClientRect().height);
  for (const m of delMarks.values()) m.hidden = false;
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
