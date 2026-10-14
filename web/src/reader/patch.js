// Applies RenderPatches from the native side while keeping the reader's place.
import { doc, slots, heights, strings, post, inViewport, trace, onKeptScroll } from './core.js';
import { captureAnchor, restoreAnchor, atBottom, resizeObserver, keepPlace, isShown } from './anchor.js';
import { renderMarks, applyChangesOnly, forgetDiff } from './marks.js';
import { scheduleRail } from './rail.js';
import { enhance, renderLazy } from './enhance.js';
import { reportActiveHeading, headingsChanged } from './heading.js';

const notice = document.getElementById('ro-notice');
let first = true;
// The reader's place when a patch emptied the document. An agent truncates a
// file before writing it again, and a read can land in between or catch the
// new text half written: the refill brings the reader back there (or to the
// end, when they were following), and so do the patches after it until
// their block is back (or they reach the end), or until they move.
let held = null;   // {anchor, following, top}
// Only the reader moving drops it: scrolls that keep the place (a diagram or
// formula above rendering, a restore) move the position it was left at too.
onKeptScroll(dy => { if (held) held.top += dy; });

function estimateHeight(kind, html) {
  const text = html.length;
  const perLine = 75;
  switch (kind) {
    case 'heading': return 48;
    case 'code': return 40 + (html.split('\n').length) * 20;
    case 'mermaid': return 320;
    case 'table': return 40 + (html.match(/<tr>/g) || []).length * 34;
    case 'listItem': return 28 + Math.floor(text / 160) * 26;
    default: return 30 + Math.ceil(text / perLine) * 26;
  }
}

function makeBlock(op) {
  const el = document.createElement('div');
  el.dataset.slot = op.slot;
  fillBlock(el, op);
  return el;
}

function fillBlock(el, op) {
  el.className = `blk k-${op.kind}${op.cjk ? ' cjk' : ''}`;   // drops marks and wd-has; renderMarks restores them
  if (op.anchor) el.dataset.anchor = op.anchor; else delete el.dataset.anchor;
  el.style.containIntrinsicSize = `auto ${estimateHeight(op.kind, op.html)}px`;
  el.innerHTML = op.html;
  enhance(el);
}

/**
 * Applies a RenderPatch: {version, reset, rewrite, ops, marks, deletions, toc, tasks, title}.
 */
export function apply(p) {
  const isFirst = first;
  first = false;
  // The document was emptied (truncated): the place it had before counts.
  if (held && slots.size > 0 && Math.abs(document.scrollingElement.scrollTop - held.top) > 2) held = null;   // the reader moved
  const place = held;
  held = null;
  const anchor = isFirst ? null : place ? place.anchor : captureAnchor();
  // An empty page is never following: there is no end being read. (It can
  // sit at its own bottom when it scrolls at all; following from there would
  // send the content that arrives to its end.)
  const following = !isFirst && (place ? place.following : slots.size > 0 && atBottom());
  // Only follow when the change is at (or below) the viewport: an insertion
  // at the top of the document must not yank a bottom-dwelling reader.
  // The anchor block itself counts: if it was edited, restoring it keeps us
  // at the end anyway.
  // Appending at the end is the live tail an agent writes: it counts as near
  // whatever its predecessor's position (the page's bottom padding keeps the
  // last block well above the bottom of the viewport). So does the agent
  // writing on into that last block (a replace of it).
  let changeNearViewport = false;
  if (following && !p.reset) {
    let last = doc.lastElementChild;
    while (last && !last.classList.contains('blk')) last = last.previousElementSibling;
    const lastSlot = last ? +last.dataset.slot : null;
    for (const op of p.ops) {
      if (op.op === 'remove') continue;
      if (op.op === 'insert' && op.after === lastSlot) { changeNearViewport = true; break; }
      if (op.op === 'replace' && op.slot === lastSlot) { changeNearViewport = true; break; }
      const el = slots.get(op.slot);
      // Inserted blocks have no element yet; locate via the predecessor.
      const ref = el || (op.after ? slots.get(op.after) : null);
      if (!ref) { changeNearViewport = true; break; }  // unknown position: stay safe, follow
      const r = ref.getBoundingClientRect();
      if (r.top > window.innerHeight - 200) { changeNearViewport = true; break; }
      if (anchor && op.slot === anchor.slot) { changeNearViewport = true; break; }
    }
  }
  const follow = following && (p.reset || p.rewrite || changeNearViewport);
  const changed = new Set();
  const rerendered = [];   // silent replaces: new HTML, no mark
  const visibleChanged = [];
  const inserted = [];
  // Measured once after all the ops: a measurement between two DOM changes
  // forces a layout each time.
  const maybeVisible = [];

  if (p.reset) {
    for (const el of slots.values()) resizeObserver.unobserve(el);
    slots.clear();
    doc.querySelectorAll('.blk, .del-mark, #ro-empty').forEach(e => e.remove());
  }

  for (const op of p.ops) {
    if (op.op === 'remove') {
      const el = slots.get(op.slot);
      if (el) { resizeObserver.unobserve(el); el.remove(); slots.delete(op.slot); }
    } else if (op.op === 'replace') {
      const el = slots.get(op.slot);
      if (!el) continue;
      const wasMarked = el.className.match(/m-(inserted|modified|state)/)?.[0];
      fillBlock(el, op);
      if (op.change === 'content') forgetDiff(op.slot);
      if (wasMarked && op.change === 'silent') el.classList.add(wasMarked);
      if (op.change !== 'silent') { changed.add(op.slot); if (!p.reset) maybeVisible.push(el); }
      else rerendered.push(el);
    } else if (op.op === 'insert') {
      const el = makeBlock(op);
      const after = op.after ? slots.get(op.after) : null;
      if (after) after.after(el);
      else if (op.after) doc.appendChild(el);
      else doc.prepend(el);
      slots.set(op.slot, el);
      resizeObserver.observe(el);
      if (!p.reset) { changed.add(op.slot); inserted.push(el); maybeVisible.push(el); }
    }
  }

  for (const el of maybeVisible) if (el.isConnected && inViewport(el)) visibleChanged.push(el);

  updateCv();
  // Content can arrive in a patch that is not a reset (a file that was empty).
  const empty = document.getElementById('ro-empty');
  if (slots.size > 0) empty?.remove();
  else if (!empty) {
    const e = document.createElement('div');
    e.id = 'ro-empty';
    e.textContent = strings.empty || 'This file is empty.';
    doc.appendChild(e);
  }

  renderMarks(p.marks || [], p.deletions || [], !!p.reset);

  // A silent re-render (checkbox HTML, CJK class) must not disturb the filter.
  applyChangesOnly();

  // Re-baseline heights of touched blocks so the resize compensator does not count this patch twice.
  for (const slot of changed) { const el = slots.get(slot); if (el) heights.set(el, el.getBoundingClientRect().height); }
  for (const el of rerendered) if (el.isConnected) heights.set(el, el.getBoundingClientRect().height);
  if (p.reset) for (const el of slots.values()) heights.set(el, el.getBoundingClientRect().height);

  if (p.rewrite) showNotice(strings.rewritten);

  // Restore position in the same task, before the browser paints.
  let restored = false;
  if (follow) {
    // In a large document a new block counts at its estimated height until
    // it is laid out: lay out the new ones now so the end is the real end.
    const forced = doc.classList.contains('cv') ? inserted.filter(el => el.isConnected) : [];
    for (const el of forced) el.style.contentVisibility = 'visible';
    window.scrollTo(0, document.scrollingElement.scrollHeight);
    for (const el of forced) heights.set(el, el.getBoundingClientRect().height);
    // Handed back once a frame has rendered them, which records their real
    // size: content-visibility then keeps that size (and they are on screen).
    if (forced.length) requestAnimationFrame(() => requestAnimationFrame(() => { for (const el of forced) el.style.contentVisibility = ''; }));
  }
  else if (anchor) restored = restoreAnchor(anchor, changed);
  // Emptied, refilled only in part, or cut short so the page cannot scroll
  // to the reader's place (it then sits at the end, which is not following):
  // hold on to the place until a later patch can restore it.
  const own = anchor && slots.get(anchor.slot);
  const cutShort = !follow && !restored && !!own && isShown(own);
  if (anchor && (slots.size === 0 || cutShort || (place && (following ? !atBottom() : !restored)))) {
    held = { anchor, following, top: document.scrollingElement.scrollTop };
  }
  trace('apply', { version: p.version, reset: !!p.reset, ops: p.ops.length, blocks: slots.size, place: !!place,
    anchor: anchor && { slot: anchor.slot, offset: Math.round(anchor.offset) }, following, follow, restored, held: !!held,
    height: document.scrollingElement.scrollHeight });

  for (const el of visibleChanged) {
    el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
  }

  renderLazy();
  scheduleRail();
  if (p.reset || p.ops.length) headingsChanged();
  reportActiveHeading();
  post({ type: 'applied', version: p.version });
  // After the frame that shows it: rAF runs before the paint, the task it
  // queues runs after.
  requestAnimationFrame(() => setTimeout(() => post({ type: 'painted', version: p.version }), 0));
}

const NOTICE_MS = 6000;
const NOTICE_FADE_MS = 400;   // reader.css: #ro-notice's opacity transition

function showNotice(text) {
  notice.textContent = text;
  notice.hidden = false;
  notice.style.opacity = '';
  clearTimeout(showNotice.t);
  // It fades out, then leaves the flow above the document: hiding it keeps
  // the reader's place.
  showNotice.t = setTimeout(() => {
    notice.style.opacity = '0';
    showNotice.t = setTimeout(() => {
      const anchor = captureAnchor();
      notice.hidden = true;
      notice.style.opacity = '';
      restoreAnchor(anchor, new Set());
    }, NOTICE_FADE_MS);
  }, NOTICE_MS);
}

// Large documents let WebKit skip laying out off-screen blocks
// (content-visibility), but find in page skips that content too: while the
// find bar is open the whole document is laid out.
let finding = false;
function updateCv() { doc.classList.toggle('cv', slots.size > 250 && !finding); }

export function findMode(on) {
  on = !!on;
  if (on === finding) return;
  keepPlace(() => { finding = on; updateCv(); });
}
