// Applies RenderPatches from the native side while keeping the reader's place.
import { doc, slots, heights, strings, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor, atBottom, resizeObserver } from './anchor.js';
import { renderMarks, applyChangesOnly } from './marks.js';
import { scheduleRail } from './rail.js';
import { enhance, renderLazy } from './enhance.js';
import { reportActiveHeading } from './heading.js';

const notice = document.getElementById('ro-notice');
let first = true;

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
  el.className = `blk k-${op.kind}${op.cjk ? ' cjk' : ''}`;
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
  const anchor = isFirst ? null : captureAnchor();
  const following = !isFirst && atBottom();
  // Only follow when the change is at (or below) the viewport: an insertion
  // at the top of the document must not yank a bottom-dwelling reader.
  // The anchor block itself counts: if it was edited, restoring it keeps us
  // at the end anyway.
  let changeNearViewport = false;
  if (following && !p.reset) {
    for (const op of p.ops) {
      if (op.op === 'remove') continue;
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
  const visibleChanged = [];

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
      if (wasMarked && op.change === 'silent') el.classList.add(wasMarked);
      if (op.change !== 'silent') { changed.add(op.slot); if (!p.reset && inViewport(el)) visibleChanged.push(el); }
    } else if (op.op === 'insert') {
      const el = makeBlock(op);
      const after = op.after ? slots.get(op.after) : null;
      if (after) after.after(el);
      else if (op.after) doc.appendChild(el);
      else doc.prepend(el);
      slots.set(op.slot, el);
      resizeObserver.observe(el);
      if (!p.reset) { changed.add(op.slot); if (inViewport(el)) visibleChanged.push(el); }
    }
  }

  doc.classList.toggle('cv', slots.size > 250);
  if (slots.size === 0) {
    const empty = document.createElement('div');
    empty.id = 'ro-empty';
    empty.textContent = strings.empty || 'This file is empty.';
    doc.appendChild(empty);
  }

  renderMarks(p.marks || [], p.deletions || []);

  // A silent re-render (checkbox HTML, CJK class) must not disturb the filter.
  applyChangesOnly();

  // Re-baseline heights of touched blocks so the resize compensator does not count this patch twice.
  for (const slot of changed) { const el = slots.get(slot); if (el) heights.set(el, el.getBoundingClientRect().height); }
  if (p.reset) for (const el of slots.values()) heights.set(el, el.getBoundingClientRect().height);

  if (p.rewrite) showNotice(strings.rewritten);

  // Restore position in the same task, before the browser paints.
  if (follow) window.scrollTo(0, document.scrollingElement.scrollHeight);
  else if (anchor) restoreAnchor(anchor, changed);

  for (const el of visibleChanged) {
    el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
  }

  renderLazy();
  scheduleRail();
  reportActiveHeading();
  post({ type: 'applied', version: p.version });
}

function showNotice(text) {
  notice.textContent = text;
  notice.hidden = false;
  clearTimeout(showNotice.t);
  showNotice.t = setTimeout(() => { notice.hidden = true; }, 6000);
}
