// Applies RenderPatches from the native side while keeping the reader's place.
import { firstTimings, doc, slots, heights, strings, post, inViewport, trace, onKeptScroll, focused, isChunk, firstItem, nextItem, lastItem, prevItem } from './core.js';
import { captureAnchor, restoreAnchor, keepPlace, anchorMiss, atBottom, fitsOnScreen, resizeObserver, scrollToElement, baseline } from './anchor.js';
import { forceLayout, place as placeItem, placeLast, unplace, reestimate, clearChunks, touched, estimateOf, itemEstimate, flushStarts, flushed, noteNext, settleNext, noteLead, leadIns, prevBlock, roughRect, unstale, cvOn } from './chunks.js';
import { renderMarks, forgetDiff, watching, forgetMarks } from './marks.js';
import { scheduleRail } from './rail.js';
import { enhance, renderLazy, forgetBlock } from './enhance.js';
import { askOnScreen } from './code.js';
import { afterShown } from './holds.js';
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

/** What a chunk not laid out yet counts for the block: its height estimated from its HTML. */
const estimateOp = op => estimateHeight(op.kind, op.html);

function fillBlock(el, op) {
  // A flash running stays (apply restarts it under its other name), and a
  // lead-in's shorter gap (decided again after the patch: chunks.js leadIns).
  const flash = ['flash', 'flash-alt', 'lead-list'].filter(c => el.classList.contains(c));
  el.className = `blk k-${op.kind}${op.cjk ? ' cjk' : ''}`;   // drops marks and wd-has; renderMarks restores them
  if (flash.length) el.classList.add(...flash);
  if (op.anchor) el.dataset.anchor = op.anchor; else delete el.dataset.anchor;
  // A block in the document: its chunk's estimate follows the new content.
  if (isChunk(el.parentElement)) reestimate(el, estimateOp(op));
  forgetBlock(el);
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
  // Link definitions (copy.js): every reset sends them (none: absent), another patch when they changed.
  if (p.reset || p.links) setLinks(p.links);
  const isFirst = first;
  first = false;
  const t0 = performance.now();
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
  // A rewrite is a new document: read from the reader's section, or its top,
  // with the notice saying so (not from its end, even for a reader who had
  // followed the old one to its end).
  const follow = following && !p.rewrite && (p.reset || nearViewport(p, anchor));
  const { changed, rerendered, inserted, maybeVisible, headingsTouched } = applyOps(p, p.reset && fromTop);

  const t1 = performance.now();
  updateCv(!!p.reset);
  // The first open of a large document reads no layout before its first
  // frame: in that frame WebKit lays out only the blocks on screen (the rest
  // are skipped, content-visibility), where a layout forced before it would
  // lay out every block. Block heights then come from the resize observer's
  // first notifications, the code highlighted at once is what an estimate
  // of the heights puts on screen, and the current section is told after
  // the frame.
  const firstLarge = isFirst && p.reset && doc.classList.contains('cv');
  // The top of the document, which the first frame shows unless a place is restored.
  if (firstLarge && doc.firstElementChild) forceLayout(doc.firstElementChild);
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

  scheduleRail();

  if (p.rewrite) showNotice(strings.rewritten);

  // In a large document a new block counts at its estimated height until
  // its chunk is laid out: laid out now, so the end is the real end.
  const forced = follow ? inserted.filter(el => el.isConnected) : [];
  for (const el of forced) forceLayout(el);

  // Every change to the page is made by now: what follows reads its layout,
  // which is laid out once (a read between two changes lays it out again,
  // in a large document the cost of the whole patch over again).
  const visibleChanged = maybeVisible.filter(el => el.isConnected && inViewport(el));

  rebaselinePatch(p, changed, rerendered, firstLarge);

  if (isFirst) { firstTimings.apply_at = Math.round(t0); firstTimings.blocks = Math.round(t1 - t0); firstTimings.layout = Math.round(performance.now() - t1); firstTimings.visible_at_apply = document.visibilityState; }

  const restored = restorePlace(p, { follow, forced, anchor, changed });
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
  // (A document shown anew: its first paint waits for the code on screen.)
  renderLazy(firstLarge ? estimatedOnScreen() : undefined, !!p.reset && slots.size > 0);

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
  post({ type: 'applied', version: p.version });
  // After the frame that shows it (afterShown: rAF runs before the paint,
  // the task it queues runs after; a first paint waiting for its code, once
  // it shows). The current section is found then too: the page is laid out
  // by that frame, so asking costs no layout of its own.
  afterShown(() => {
    const se = document.scrollingElement;
    entry.y = Math.round(se.scrollTop);
    entry.height = se.scrollHeight;
    reportActiveHeading();
    // Page time the first paint was reported (SmokeTest: cold_page_painted_at_ms).
    firstTimings.painted_at ??= Math.round(performance.now());
    post({ type: 'painted', version: p.version });
  });
}

/**
 * Whether a patch changes the document at (or below) the viewport, so a
 * reader following the end follows it. An insertion at the top must not
 * yank a bottom-dwelling reader. The anchor block itself counts: if it was
 * edited, restoring it keeps the reader at the end anyway. Appending at the
 * end is the live tail an agent writes: it counts as near whatever its
 * predecessor's position (the page's bottom padding keeps the last block
 * well above the bottom of the viewport). So does the agent writing on into
 * that last block (a replace of it).
 */
function nearViewport(p, anchor) {
  let last = lastItem();
  while (last && !last.classList.contains('blk')) last = prevItem(last);
  const lastSlot = last ? +last.dataset.slot : null;
  for (const op of p.ops) {
    if (op.op === 'remove') continue;
    if (op.op === 'insert' && op.after === lastSlot) return true;
    if (op.op === 'replace' && op.slot === lastSlot) return true;
    const el = slots.get(op.slot);
    // Inserted blocks have no element yet; locate via the predecessor.
    const ref = el || (op.after ? slots.get(op.after) : null);
    if (!ref) return true;  // unknown position: stay safe, follow
    if (roughRect(ref).top > window.innerHeight - 200) return true;
    if (anchor && op.slot === anchor.slot) return true;
  }
  return false;
}

/**
 * Makes the patch's changes to the page: blocks removed, filled anew and
 * inserted, in order. What changed is returned for the measurements made
 * once every change is made (one between two changes forces a layout each time).
 */
function applyOps(p, showsTop) {
  const changed = new Set();
  const rerendered = [];   // silent replaces: new HTML, no mark
  const inserted = [];
  const maybeVisible = [];
  // The outline's headings are looked for again only when one changed.
  let headingsTouched = !!p.reset;

  if (p.reset) {
    for (const el of slots.values()) { resizeObserver.unobserve(el); forgetBlock(el); forgetMarks(el); }
    slots.clear();
    clearChunks();
    document.getElementById('ro-empty')?.remove();
  }

  // A document shown anew from its top: the code its first screen may show
  // is asked for as its block is made (askOnScreen), by the heights estimated
  // above it (lines of at least 18 px).
  const reach = window.innerHeight + 120;
  let above = showsTop ? 0 : Infinity;
  for (const op of p.ops) {
    if (op.op === 'remove') {
      const el = slots.get(op.slot);
      if (el) { headingsTouched ||= el.classList.contains('k-heading'); noteNext(nextItem(el)); noteLead(prevBlock(el)); resizeObserver.unobserve(el); forgetBlock(el); forgetMarks(el); unplace(el); slots.delete(op.slot); }
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
      noteNext(nextItem(el));
      const wasMarked = el.className.match(/m-(inserted|modified|state)/)?.[0];
      const wasRead = el.classList.contains('m-read');
      fillBlock(el, op);
      noteLead(el); noteLead(prevBlock(el));
      if (op.change === 'content') forgetDiff(op.slot);
      // A silent re-render keeps the mark as it was, read or not.
      if (wasMarked && op.change === 'silent') { el.classList.add(wasMarked); if (wasRead) el.classList.add('m-read'); }
      if (op.change !== 'silent') { changed.add(op.slot); if (!p.reset) maybeVisible.push(el); }
      else rerendered.push(el);
    } else if (op.op === 'insert') {
      headingsTouched ||= op.kind === 'heading';
      const el = makeBlock(op);
      if (above < reach) {
        for (const cb of el.querySelectorAll('.code-block')) askOnScreen(cb, Math.ceil((reach - above) / 18));
        above += estimateOp(op);
      }
      const after = op.after ? slots.get(op.after) : null;
      if (!p.reset) noteNext(after ? nextItem(after) : op.after ? null : firstItem());
      if (after) placeItem(el, after, estimateOp(op));
      else if (op.after) placeLast(el, estimateOp(op));
      else placeItem(el, null, estimateOp(op));
      slots.set(op.slot, el);
      if (!p.reset) { noteLead(el); noteLead(prevBlock(el)); }
      else if (op.kind === 'paragraph' && op.html.startsWith('<p class="lead"')) noteLead(el);   // a lead-in: leadIns(true)
      resizeObserver.observe(el);
      if (!p.reset) { changed.add(op.slot); inserted.push(el); maybeVisible.push(el); }
    }
  }
  return { changed, rerendered, inserted, maybeVisible, headingsTouched };
}

/**
 * Re-baselines the heights the patch changed, so the resize compensator does
 * not count it twice.
 */
function rebaselinePatch(p, changed, rerendered, firstLarge) {
  // The first open of a large document reads no layout, but the resize
  // compensator still needs a baseline: a chunk the first frame skips is its
  // estimate, so chunks above a resumed position that are laid out at another
  // height still keep the place.
  // (A heading's margin from its neighbour in the chunk first, then its flush start: each change counted once.)
  const nextOnes = settleNext();
  flushStarts();
  leadIns(!!p.reset);
  for (const c of touched) if (c.isConnected) heights.set(c, firstLarge ? estimateOf(c) : c.getBoundingClientRect().height);
  touched.clear();
  // Not a block in a chunk skipped (WebKit would lay the chunk out to answer):
  // it reports its size once the chunk is laid out, the chunk's change made up for as a whole.
  const laid = el => !doc.classList.contains('cv') || el.checkVisibility({ contentVisibilityAuto: true });
  for (const slot of changed) { const el = slots.get(slot); if (el && laid(el)) heights.set(el, el.getBoundingClientRect().height); else if (el) heights.delete(el); }
  for (const el of rerendered) if (el.isConnected && laid(el)) heights.set(el, el.getBoundingClientRect().height); else heights.delete(el);
  // Headings whose flush start changed (flushStarts): in a chunk skipped, their height was taken with it.
  for (const el of [...flushed, ...nextOnes]) if (el.isConnected && laid(el)) heights.set(el, el.getBoundingClientRect().height);
  flushed.clear();
  if (p.reset && !firstLarge) for (const el of slots.values()) heights.set(el, el.getBoundingClientRect().height);
}

/**
 * Puts the reader where the patch leaves them, in the same task, before the
 * browser paints: at the end they follow, in their section of a rewrite, or
 * at their own block. Whether their own block's place was restored.
 */
function restorePlace(p, { follow, forced, anchor, changed }) {
  if (follow) {
    window.scrollTo(0, document.scrollingElement.scrollHeight);
    for (const el of forced) baseline(el);
  }
  // Rewritten: none of the old blocks is left to keep the place by. The
  // reader goes to the section they were in, if it is still there, else to
  // the top (not wherever the old offset lands in the new text).
  else if (p.rewrite && anchor) {
    const h = anchor.heading && doc.querySelector(`.k-heading[data-anchor="${CSS.escape(anchor.heading)}"]`);
    if (h) scrollToElement(h, { gap: 16 }); else window.scrollTo(0, 0);
  }
  else if (anchor) return restoreAnchor(anchor, changed);
  return false;
}



/**
 * Which code blocks a first open counts as on screen, from the chunks'
 * estimated heights instead of a layout: those of the chunks from the top
 * of the document through two screens.
 */
function estimatedOnScreen() {
  // The blocks the first two screens show by their estimates (not every
  // block of the chunks there: a chunk of long code runs screens past it).
  // Two: an estimate is from a block's HTML, and a paragraph of long links
  // is estimated much taller than it is (code under it was left plain).
  const near = new Set();
  let y = 0;
  for (let e = firstItem(); e && y < 2 * innerHeight; e = nextItem(e)) {
    near.add(e);
    y += itemEstimate(e);
  }
  return cb => near.has(cb.closest('#ro-doc > .chunk > *'));
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
  keepPlace(() => { notice.hidden = true; notice.style.opacity = ''; }, { bottom: false });
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
      keepPlace(() => { notice.hidden = true; notice.style.opacity = ''; }, { bottom: false });
    }, NOTICE_FADE_MS);
  }, NOTICE_MS);
}

// Large documents let WebKit skip laying out the chunks away from the screen
// (content-visibility, chunks.js); decided after a patch's changes.
function updateCv(reset) {
  const on = slots.size > 250;
  if (on === doc.classList.contains('cv')) return;
  if (on) cvOn(reset); else { doc.classList.remove('cv'); unstale(); }
}
