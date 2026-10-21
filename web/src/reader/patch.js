// Applies RenderPatches from the native side while keeping the reader's place.
import { doc, slots, heights, strings, post, inViewport, trace, onKeptScroll, focused } from './core.js';
import { captureAnchor, restoreAnchor, anchorMiss, atBottom, fitsOnScreen, resizeObserver, scrollToElement, forceLayout, neverLaidOut } from './anchor.js';
import { renderMarks, forgetDiff, watching } from './marks.js';
import { scheduleRail } from './rail.js';
import { enhance, renderLazy, measureTables } from './enhance.js';
import { sources, tight, setLinks } from './copy.js';
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
// Following the end (the live tail an agent writes) starts when the reader is
// at the end, and stops only when the reader scrolls (wheel, keys, the
// scrollbar, a jump): the page moving under them does not stop it. A block at
// the end laid out taller than its estimate, or a patch the page has not caught
// up with yet, leaves the reader short of the end without them having moved;
// the next patch takes them to the end again.
let tail = null;   // {y}: where the page left a reader following the end
onKeptScroll(dy => { if (tail) tail.y += dy; });
/** The reader came to rest at the end of the page (reader.js, after a scroll settles). */
export function restedAtEnd() { tail = { y: document.scrollingElement.scrollTop }; }

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
  // A flash running stays (apply restarts it under its other name).
  const flash = ['flash', 'flash-alt'].filter(c => el.classList.contains(c));
  el.className = `blk k-${op.kind}${op.cjk ? ' cjk' : ''}`;   // drops marks and wd-has; renderMarks restores them
  if (flash.length) el.classList.add(...flash);
  if (op.anchor) el.dataset.anchor = op.anchor; else delete el.dataset.anchor;
  // The estimate is only for a block never laid out: one that has been keeps
  // its last remembered size while skipped (contain-intrinsic-size: auto).
  // Changing the property makes WebKit lay out every skipped block again
  // (5 MB, 25,000 blocks: 1.5-4 s per edit), on a block never laid out too:
  // its estimate is renewed only when the new content is far off it (a
  // paragraph become a long code block), for the page's height.
  const est = estimateHeight(op.kind, op.html);
  const was = parseFloat(el.style.containIntrinsicSize.replace('auto ', '')) || 0;
  if (!el.style.containIntrinsicSize || (Math.abs(est - was) > Math.max(1000, was) && neverLaidOut(el))) el.style.containIntrinsicSize = `auto ${est}px`;
  el.innerHTML = op.html;
  if (op.src != null) sources.set(el, op.src); else sources.delete(el);
  if (op.tight) tight.add(el); else tight.delete(el);
  enhance(el);
  titleLinks(el);
  pathLinks(el);
}

/**
 * A path in a code span opens in the editor: it is a link, to the keyboard
 * (Tab reaches it, Return or Space opens it: reader.js) and to VoiceOver,
 * and its tooltip says which file, at which line.
 */
function pathLinks(el) {
  for (const c of el.querySelectorAll('code.path-link')) {
    c.setAttribute('role', 'link');
    c.tabIndex = 0;
    if (c.hasAttribute('title')) continue;
    const line = +c.dataset.line || 0, col = +c.dataset.col || 0;
    c.title = (c.dataset.path || c.textContent) + (line ? `:${line}${col ? `:${col}` : ''}` : '');
  }
}

/**
 * A link's tooltip says where it goes: the address of a web page, the path
 * of a file as written (the app resolves it), the section of this document.
 * A title the author gave stays; footnote links say nothing (their number
 * is the point).
 */
function titleLinks(el) {
  for (const a of el.querySelectorAll('a[href]')) {
    if (a.hasAttribute('title') || a.matches('[data-footnote-ref], [data-footnote-backref]')) continue;
    let href = a.getAttribute('href');
    if (!href) continue;
    // Never the page's own scheme: what is behind it is a file path.
    const own = /^readout:\/\/[^/]*(\/.*)$/i.exec(href);
    if (own) href = own[1];
    try { href = decodeURI(href); } catch { /* keep it as written */ }
    a.title = href;
  }
}

/**
 * Applies a RenderPatch: {version, reset, rewrite, ops, marks, deletions, toc, tasks, title}.
 */
export function apply(p) {
  const B = l => window.__boot?.push(['ap_' + l, Date.now() / 1000]);
  B('start');
  // Link definitions (copy.js): every reset sends them (none: absent), another patch when they changed.
  if (p.reset || p.links) setLinks(p.links);
  const isFirst = first;
  first = false;
  // The document was emptied (truncated): the place it had before counts.
  if (held && slots.size > 0 && Math.abs(document.scrollingElement.scrollTop - held.top) > 2) held = null;   // the reader moved
  if (tail && Math.abs(document.scrollingElement.scrollTop - tail.y) > 2) tail = null;   // the reader scrolled away
  const place = held;
  held = null;
  const anchor = isFirst ? null : place ? place.anchor : captureAnchor();
  // A place taken now at the top of the page.
  const fromTop = !place && (isFirst || document.scrollingElement.scrollTop <= 0);
  // An empty page is never following: there is no end being read. (It can
  // sit at its own bottom when it scrolls at all; following from there would
  // send the content that arrives to its end.) A reader watching a page that
  // fits the window (Readout beside the terminal the agent writes from)
  // follows it too: once it grows past the window, they see its end.
  const following = !isFirst && (place ? place.following : slots.size > 0 && (!!tail || atBottom() || (watching() && fitsOnScreen())));
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
  // A rewrite is a new document: read from the reader's section, or its top,
  // with the notice saying so (not from its end, even for a reader who had
  // followed the old one to its end).
  const follow = following && !p.rewrite && (p.reset || changeNearViewport);
  const changed = new Set();
  const rerendered = [];   // silent replaces: new HTML, no mark
  const visibleChanged = [];
  const inserted = [];
  // Measured once after all the ops: a measurement between two DOM changes
  // forces a layout each time.
  const maybeVisible = [];
  // The outline's headings are looked for again only when one changed.
  let headingsTouched = !!p.reset;

  if (p.reset) {
    for (const el of slots.values()) resizeObserver.unobserve(el);
    slots.clear();
    doc.querySelectorAll('.blk, .del-mark, #ro-empty').forEach(e => e.remove());
  }

  for (const op of p.ops) {
    if (op.op === 'remove') {
      const el = slots.get(op.slot);
      if (el) { headingsTouched ||= el.classList.contains('k-heading'); resizeObserver.unobserve(el); el.remove(); slots.delete(op.slot); }
    } else if (op.op === 'replace') {
      const el = slots.get(op.slot);
      if (!el) continue;
      // Only the source changed (it renders the same): the block stays as it
      // is (an open <details>, a diagram drawn, the selection); copying sees the new source.
      if (op.html == null) {
        if (op.src != null) sources.set(el, op.src); else sources.delete(el);
        if (op.tight) tight.add(el); else tight.delete(el);
        continue;
      }
      headingsTouched ||= op.kind === 'heading' || el.classList.contains('k-heading');
      const wasMarked = el.className.match(/m-(inserted|modified|state)/)?.[0];
      const wasRead = el.classList.contains('m-read');
      fillBlock(el, op);
      if (op.change === 'content') forgetDiff(op.slot);
      // A silent re-render keeps the mark as it was, read or not.
      if (wasMarked && op.change === 'silent') { el.classList.add(wasMarked); if (wasRead) el.classList.add('m-read'); }
      if (op.change !== 'silent') { changed.add(op.slot); if (!p.reset) maybeVisible.push(el); }
      else rerendered.push(el);
    } else if (op.op === 'insert') {
      headingsTouched ||= op.kind === 'heading';
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

  B('ops');
  updateCv();
  // The first open of a large document reads no layout before its first
  // frame: in that frame WebKit lays out only the blocks on screen (the rest
  // are skipped, content-visibility), where a layout forced before it would
  // lay out every block. Block heights then come from the resize observer's
  // first notifications, the code highlighted at once is what an estimate
  // of the heights puts on screen, and the current section is told after
  // the frame.
  const firstLarge = isFirst && p.reset && doc.classList.contains('cv');
  // Content can arrive in a patch that is not a reset (a file that was empty).
  const empty = document.getElementById('ro-empty');
  if (slots.size > 0) empty?.remove();
  else if (!empty) {
    const e = document.createElement('div');
    e.id = 'ro-empty';
    e.textContent = strings.empty || 'This file is empty.';
    doc.appendChild(e);
  }

  B('pre_marks');
  renderMarks(p.marks || [], p.deletions || [], !!p.reset);

  scheduleRail();

  if (p.rewrite) showNotice(strings.rewritten);

  // In a large document a new block counts at its estimated height until
  // it is laid out: lay out the new ones now so the end is the real end.
  // (They go back to content-visibility later, many together: forceLayout.)
  const forced = follow ? inserted.filter(el => el.isConnected) : [];
  for (const el of forced) forceLayout(el);

  // Every change to the page is made by now: what follows reads its layout,
  // which is laid out once (a read between two changes lays it out again,
  // in a large document the cost of the whole patch over again).
  B('marks_rail');
  for (const el of maybeVisible) if (el.isConnected && inViewport(el)) visibleChanged.push(el);

  // Re-baseline heights of touched blocks so the resize compensator does not count this patch twice.
  for (const slot of changed) { const el = slots.get(slot); if (el) heights.set(el, el.getBoundingClientRect().height); }
  for (const el of rerendered) if (el.isConnected) heights.set(el, el.getBoundingClientRect().height);
  if (p.reset && !firstLarge) for (const el of slots.values()) heights.set(el, el.getBoundingClientRect().height);
  // The first open of a large document reads no layout, but the resize
  // compensator still needs a baseline: a block the first frame skips is its
  // estimate, so blocks above a resumed position that are laid out at another
  // height still keep the place.
  if (firstLarge) for (const el of slots.values()) heights.set(el, parseFloat(el.style.containIntrinsicSize.replace('auto ', '')) || 0);

  B('layout_reads');
  // Restore position in the same task, before the browser paints.
  let restored = false;
  if (follow) {
    window.scrollTo(0, document.scrollingElement.scrollHeight);
    for (const el of forced) heights.set(el, el.getBoundingClientRect().height);
  }
  // Rewritten: none of the old blocks is left to keep the place by. The
  // reader goes to the section they were in, if it is still there, else to
  // the top (not wherever the old offset lands in the new text).
  else if (p.rewrite && anchor) {
    const h = anchor.heading && doc.querySelector(`.k-heading[data-anchor="${CSS.escape(anchor.heading)}"]`);
    if (h) scrollToElement(h, { gap: 16 }); else window.scrollTo(0, 0);
  }
  else if (anchor) restored = restoreAnchor(anchor, changed);
  // Emptied, refilled only in part, or cut short so the page cannot scroll
  // to the reader's place (it then sits at the end, which is not following):
  // hold on to the place until a later patch can restore it. Not a reader at
  // the top (a short page that grew above them: they stay at the top, not
  // carried down as soon as it scrolls), nor a place the page would have to
  // scroll up to (it is at the top already).
  const own = anchor && slots.get(anchor.slot);
  const cutShort = !follow && !restored && !!own && !fromTop && anchorMiss(anchor, changed) > 1;
  if (anchor && !p.rewrite && (slots.size === 0 || cutShort || (place && (following ? !atBottom() : !restored)))) {
    held = { anchor, following, top: document.scrollingElement.scrollTop };
  }
  // Following goes on from where this patch left the reader (a rewrite is
  // read from the reader's section or its top, not followed).
  tail = following && !p.rewrite && slots.size > 0 ? { y: document.scrollingElement.scrollTop } : null;
  // Where the page stands is filled in once it is painted (read now, it
  // would lay the page out once more).
  const entry = trace('apply', { y: null, version: p.version, reset: !!p.reset, ops: p.ops.length, blocks: slots.size, place: !!place,
    anchor: anchor && { slot: anchor.slot, offset: Math.round(anchor.offset) }, following, follow, restored, held: !!held,
    height: null });

  // (Code coming on screen is highlighted before the flash's class changes
  // make the page's style stale again: it measures first.)
  B('restore_trace');
  renderLazy(firstLarge ? estimatedOnScreen() : undefined);

  B('lazy');
  // A flash still running restarts under the other animation name
  // (reader.css), without a forced style and layout to restart it. A block
  // with a change bar has its arrival in the bar: no flash (it blinked with
  // every write while an agent streamed into it).
  for (const el of visibleChanged) {
    if (el.matches('.m-inserted, .m-modified, .m-state')) continue;
    const again = el.classList.contains('flash') && !el.classList.contains('flash-alt');
    el.classList.add('flash');
    el.classList.toggle('flash-alt', again);
  }

  scheduleRail();
  if (headingsTouched) headingsChanged();
  B('end');
  post({ type: 'applied', version: p.version, boot: window.__boot });
  // After the frame that shows it: rAF runs before the paint, the task it
  // queues runs after. The current section is found then too: the page is
  // laid out by that frame, so asking costs no layout of its own.
  requestAnimationFrame(() => setTimeout(() => {
    const se = document.scrollingElement;
    entry.y = Math.round(se.scrollTop);
    entry.height = se.scrollHeight;
    reportActiveHeading();
    if (firstLarge) measureSkippedTables();
    post({ type: 'painted', version: p.version });
  }, 0));
}

/**
 * Whether a table scrolls is measured in the frame after it arrives; on a
 * first open that no longer laid out every block, a table in a block the
 * frame skipped (content-visibility) measured as fitting. Each such table is
 * measured again when it comes on screen, its block laid out by then (not all
 * of them at once, laid out for the moment: 1 MB, 66 tables, ~1 s, and every
 * skipped block laid out again after).
 */
const skippedTables = new IntersectionObserver(entries => {
  const shown = entries.filter(e => e.isIntersecting && e.target.clientWidth > 0).map(e => e.target);
  for (const t of shown) skippedTables.unobserve(t);
  if (shown.length) measureTables(shown);
});
function measureSkippedTables() {
  for (const t of doc.querySelectorAll(':scope > .blk .table-wrap')) skippedTables.observe(t);
}

/**
 * Which code blocks a first open counts as on screen, from the blocks'
 * estimated heights (their intrinsic size) instead of a layout: those from
 * the top of the document through two screens.
 */
function estimatedOnScreen() {
  const near = new Set();
  let y = 0;
  for (let e = doc.firstElementChild; e && y < innerHeight * 2; e = e.nextElementSibling) {
    near.add(e);
    y += parseFloat(e.style.containIntrinsicSize.replace('auto ', '')) || 0;
  }
  return cb => near.has(cb.closest('#ro-doc > .blk'));
}

const NOTICE_MS = 6000;
const NOTICE_FADE_MS = 400;   // reader.css: #ro-notice's opacity transition

// The notice counts down only while the reader can see it: a rewrite that
// lands while Readout is in the background is still there when they come
// back to it.
let noticeWaiting = false;
const noticeSeen = focused;

export function showNotice(text) {
  notice.textContent = text;
  notice.hidden = false;
  notice.style.opacity = '';
  clearTimeout(showNotice.t);
  noticeWaiting = !noticeSeen();
  if (!noticeWaiting) countDownNotice();
}

/** Hides the notice at once, if it says `text` (another one stays). */
export function hideNotice(text) {
  if (notice.hidden || notice.textContent !== text) return;
  clearTimeout(showNotice.t);
  noticeWaiting = false;
  const anchor = captureAnchor();
  notice.hidden = true;
  notice.style.opacity = '';
  restoreAnchor(anchor, new Set());
}

export function noticeMaybeSeen() {
  if (noticeWaiting && noticeSeen()) { noticeWaiting = false; countDownNotice(); }
}
window.addEventListener('focus', noticeMaybeSeen);
document.addEventListener('visibilitychange', noticeMaybeSeen);

function countDownNotice() {
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

// Large documents let WebKit skip laying out off-screen blocks (content-visibility).
function updateCv() { doc.classList.toggle('cv', slots.size > 250); }
