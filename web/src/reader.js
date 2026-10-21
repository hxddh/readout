// Readout renderer: applies block patches from the native side, keeps the reading position
// stable, shows unread changes, and renders code, math and diagrams lazily.
//
// Modules (web/src/reader/):
//   core     shared state, strings, native message channel
//   anchor   reading position, resize compensation, #fragment resolution
//   patch    applying RenderPatches
//   marks    unread marks, read detection, jumps
//   find     find in page
//   rail     change rail
//   enhance  per-block code/table/heading/remote setup, lazy highlighting
//   math / mermaid / remote / heading
import * as hl from './highlight.js';
import { doc, root, slots, post, mergeStrings, enableQuicklook, pageTheme, trace, traceEntries, onKeptScroll, setWindowKey } from './reader/core.js';
import { captureAnchor, restoreAnchor, resolveFragment, scrollToElement, keepPlace, holdPlace, rebaselineHeights, topInset, atBottom, blocksOnScreen, pinLanding, aimAt, AIM_MS } from './reader/anchor.js';
import { apply as applyPatch, showNotice, hideNotice, noticeMaybeSeen, restedAtEnd } from './reader/patch.js';
import { jump, markAllRead, toggleDiff, toggleDiffInView, closePopups, noteLanding, restartDwell } from './reader/marks.js';
import { scheduleRail } from './reader/rail.js';
import { relabelButtons, setCodeWrap, highlightAll, measureTables, highlightIn } from './reader/enhance.js';
import { rerenderMermaid, renderAllMermaid, setPrintDiagrams } from './reader/mermaid.js';
import { remoteReady, remoteFailed, remoteKnown, staticRemoteImages } from './reader/remote.js';
import { reportActiveHeading, pinActiveHeading } from './reader/heading.js';
import { markdownOf, htmlOf, inDocument } from './reader/copy.js';
import { find, findEnd } from './reader/find.js';

// ---------------------------------------------------------------- Links & keys

function openPath(path) {
  post({ type: 'openPath', path: path.dataset.path, line: +path.dataset.line || 0, column: +path.dataset.col || 0 });
}

doc.addEventListener('click', ev => {
  const path = ev.target.closest('code.path-link');
  if (path) {
    ev.preventDefault();
    openPath(path);
    return;
  }
  const a = ev.target.closest('a[href]');
  if (!a) return;
  const href = a.getAttribute('href');
  ev.preventDefault();
  if (href.startsWith('#')) {
    const target = resolveFragment(href);
    if (!target) return;
    // Footnotes and their back-references land mid-screen and show where.
    const note = a.matches('[data-footnote-ref], [data-footnote-backref]');
    scrollToElement(target, { center: note });
    noteLanding(target);
    if (note) {
      const spot = target.closest('li, sup') || target;
      spot.classList.remove('landed'); void spot.offsetWidth; spot.classList.add('landed');
    }
    return;
  }
  post({ type: 'open', href });
});

// ---------------------------------------------------------------- Copy

// ⌘C, Edit ▸ Copy and the context menu's Copy: the selection as Markdown in
// plain text (an agent's prompt, a terminal, an editor) and as clean HTML in
// rich text (copy.js). A selection inside an open comparison or removed-text
// panel copies as the browser copies it.
const RICH_LIMIT = 500_000;
function fillClipboard(data) {
  const sel = getSelection();
  if (!data || !sel || sel.isCollapsed || !sel.rangeCount) return false;
  // Edit ▸ Select All selects the whole page: only the document is copied.
  const range = inDocument(sel.getRangeAt(0));
  const text = range && markdownOf(range);
  if (text == null) return false;
  data.setData('text/plain', text);
  // Rich text costs WebKit about 1.5 s a megabyte to take (it sanitizes it; Linux CI box):
  // past RICH_LIMIT the selection goes as Markdown only, which rich apps paste as text.
  if (text.length <= RICH_LIMIT) data.setData('text/html', htmlOf(range));
  return true;
}
document.addEventListener('copy', ev => { if (fillClipboard(ev.clipboardData)) ev.preventDefault(); });
// Dragging the selection into a terminal or an editor drops the same Markdown.
document.addEventListener('dragstart', ev => {
  const sel = getSelection();
  if (!sel || sel.isCollapsed || ev.target.nodeType !== Node.TEXT_NODE && !sel.containsNode(ev.target, true)) return;
  fillClipboard(ev.dataTransfer);
});

// ---------------------------------------------------------------- Copy as Quote

// Edit ▸ Copy as Quote quotes the blocks the selection touches, whole (the
// app has their Markdown source): the page says which, and whether there is
// anything to quote (the menu item is enabled while there is). With no text
// selected, the block the keyboard is on (where N, a rail tick or Tab went),
// so "N, then Copy as Quote" needs no mouse.
let hadSelection = 'false/false';
const textSelected = () => {
  const sel = getSelection();
  return !!sel && !sel.isCollapsed && sel.rangeCount > 0 && doc.contains(sel.anchorNode) && sel.toString().trim() !== '';
};
const focusedBlock = () => {
  const a = document.activeElement;
  return a && doc.contains(a) ? a.closest('#ro-doc > .blk[data-slot]') : null;
};
// `has`: text is selected (the context menu's Copy as Quote); `focused`: a
// block has the keyboard's focus (Edit ▸ Copy as Quote quotes it when no text
// is selected; a right click elsewhere does not move the focus).
function reportSelection() {
  const has = textSelected(), focused = !!focusedBlock();
  const state = `${has}/${focused}`;
  if (state !== hadSelection) { hadSelection = state; post({ type: 'selection', has, focused }); }
}
document.addEventListener('selectionchange', reportSelection);
doc.addEventListener('focusin', reportSelection);
// Focus leaving goes through the body first: decide once it has landed.
doc.addEventListener('focusout', () => setTimeout(reportSelection, 0));

/**
 * The slots of the blocks the selection touches, in document order (no
 * text selected: the block with the keyboard's focus, if any). A
 * selection that ends right at the start of the next block (a triple
 * click) or begins at the very end of one does not take that block in;
 * blocks without text (a rule, an image) between selected ones do count.
 */
function selectedSlots() {
  const sel = getSelection();
  if (!textSelected()) { const b = focusedBlock(); return b ? [+b.dataset.slot] : []; }
  const out = [];
  for (let i = 0; i < sel.rangeCount; i++) {
    const r = sel.getRangeAt(i);
    const touched = [];
    let seen = false;
    for (let e = doc.firstElementChild; e; e = e.nextElementSibling) {
      if (!e.classList.contains('blk')) continue;
      if (!r.intersectsNode(e)) { if (seen) break; continue; }
      seen = true;
      touched.push(e);
    }
    const hasText = e => {
      const part = document.createRange();
      part.selectNodeContents(e);
      if (r.compareBoundaryPoints(Range.START_TO_START, part) > 0) part.setStart(r.startContainer, r.startOffset);
      if (r.compareBoundaryPoints(Range.END_TO_END, part) < 0) part.setEnd(r.endContainer, r.endOffset);
      return part.toString().trim() !== '';
    };
    while (touched.length && !hasText(touched[0])) touched.shift();
    while (touched.length && !hasText(touched[touched.length - 1])) touched.pop();
    for (const e of touched) out.push(+e.dataset.slot);
  }
  return [...new Set(out)];
}

// j and k scroll as far as the arrow keys do; smoothly, as change jumps do,
// unless the document is large (an instant scroll compensating for a block
// laid out on the way would cut the animation short) or the reader asked for
// less motion.
const LINE_STEP = 40;   // WebKit's arrow-key step (macOS)
function smooth() { return !doc.classList.contains('cv') && !matchMedia('(prefers-reduced-motion: reduce)').matches; }

/**
 * To the very top or end. In a large document the blocks around the place it
 * lands are laid out over the next frames and move the end: it aims again as
 * they get their real heights, unless the reader scrolled away meanwhile.
 */
let edge = null;   // {end, y}: where the last aim left the page
onKeptScroll(dy => { if (edge) edge.y += dy; });
function scrollToEdge(end) {
  const se = document.scrollingElement;
  const mine = edge = { end, y: 0 };
  const aim = () => { window.scrollTo(0, end ? se.scrollHeight : 0); mine.y = se.scrollTop; noteLanding(); };
  aim();
  const until = performance.now() + AIM_MS;
  const reaim = () => {
    // Moved from where it was left, other than by the end coming closer (a
    // page growing shorter holds the reader at its end): the reader scrolled.
    const atEnd = se.scrollTop >= se.scrollHeight - innerHeight - 1;
    if (edge !== mine || (Math.abs(se.scrollTop - mine.y) > 2 && !(end && atEnd))) return;
    aim();
    if (performance.now() < until) requestAnimationFrame(reaim);
  };
  requestAnimationFrame(reaim);
}

document.addEventListener('keydown', ev => {
  if (ev.target.closest && ev.target.closest('input, textarea')) return;
  // A path in a code span is a link: Return or Space opens it.
  const path = ev.target.closest && ev.target.closest('code.path-link');
  if (path && (ev.key === 'Enter' || ev.key === ' ') && !ev.metaKey && !ev.ctrlKey && !ev.altKey) { ev.preventDefault(); openPath(path); return; }
  if (ev.key === 'Escape') { if (closePopups()) ev.preventDefault(); return; }
  if (ev.ctrlKey || ev.altKey) return;
  // End / Home, and Command-Down / Command-Up.
  const toEnd = ev.metaKey ? { ArrowDown: true, ArrowUp: false }[ev.key] : { End: true, Home: false }[ev.key];
  if (toEnd !== undefined && !ev.shiftKey) { scrollToEdge(toEnd); ev.preventDefault(); return; }
  if (ev.metaKey) return;
  // Letters by their key whatever the case (Caps Lock), Shift by the modifier.
  const key = ev.key.length === 1 ? ev.key.toLowerCase() : ev.key;
  if (key === 'n') { jump(ev.shiftKey ? -1 : 1); ev.preventDefault(); }
  else if (key === 'j' || key === 'k') { window.scrollBy({ top: key === 'j' ? LINE_STEP : -LINE_STEP, behavior: smooth() ? 'smooth' : 'auto' }); ev.preventDefault(); }
  else if (key === 'g') { scrollToEdge(ev.shiftKey); ev.preventDefault(); }
  else if (key === 'd' && !ev.shiftKey) { toggleDiffInView(); }
});

// ---------------------------------------------------------------- Scroll reporting (TOC sync, saved position)

let followAnchor = null;
let scrollQueued = false;
window.addEventListener('scroll', () => {
  if (scrollQueued) return;
  scrollQueued = true;
  requestAnimationFrame(() => {
    scrollQueued = false;
    reportActiveHeading();
    clearTimeout(followAnchor);
    followAnchor = setTimeout(() => post({ type: 'anchor', anchor: captureAnchor() }), 400);
    if (!resizeAnchor) settle();
  });
}, { passive: true });

// ---------------------------------------------------------------- Window resize

// By the time a resize event arrives the page already has its new width, so
// the place to keep is the one captured while the reader last sat still
// (and whether they sat at the end, following the live tail: they stay there).
// It is only that place while the page is still where it was: a scroll the
// scroll handler has not seen yet (resize events run before scroll events in
// a frame, so a scroll made just before the window resized, by the app or a
// script) makes it stale, and the place is taken now instead.
let settledAnchor = null;
let settledBottom = false;
let settledY = 0;
let settleTimer = null;
function settle() {
  settledAnchor = null;
  clearTimeout(settleTimer);
  settleTimer = setTimeout(() => {
    settledAnchor = captureAnchor(); settledBottom = atBottom(); settledY = document.scrollingElement.scrollTop;
    if (settledBottom) restedAtEnd();   // following the end from here on
  }, 100);
}

let resizeAnchor = null;
let resizeBottom = false;
let resizeEnd = null;
window.addEventListener('resize', () => {
  if (!resizeAnchor) {
    // Moved since it settled, other than by a shorter page being clamped to its new end.
    const se = document.scrollingElement;
    const clamped = se.scrollTop < settledY && se.scrollTop >= se.scrollHeight - innerHeight - 1;
    const settled = settledAnchor && (Math.abs(se.scrollTop - settledY) <= 1 || clamped) ? settledAnchor : null;
    resizeBottom = settled ? settledBottom : atBottom();
    resizeAnchor = settled || captureAnchor();
  }
  if (!resizeAnchor) return;
  const hold = () => {
    trace('resize', { slot: resizeAnchor.slot, bottom: resizeBottom, w: innerWidth, h: innerHeight });
    holdPlace(resizeAnchor, resizeBottom, true);
    rebaselineHeights();
  };
  hold();
  clearTimeout(resizeEnd);
  resizeEnd = setTimeout(() => { hold(); resizeAnchor = null; settle(); }, 200);
});

function apply(p) {
  applyPatch(p);
  if (!resizeAnchor) settle();
  // A patch can remove the focused block (a reset removes them all) without
  // a focusout: what there is to quote is said again (posted only if it changed).
  reportSelection();
}

// ---------------------------------------------------------------- Native API

function setAppearance(o) {
  // The highlighter starts with the first appearance (or the app's warm-up),
  // which tells Quick Look apart: a preview loads only the grammars it shows.
  if (o.mode === 'quicklook') hl.noPreload();
  hl.init();
  if (o.dark !== undefined) {
    const t = o.dark ? 'dark' : 'light';
    if (root.dataset.theme !== t) {
      keepPlace(() => {
        root.dataset.theme = t;
        rerenderMermaid();
      });
    }
  }
  if (o.accent) {
    root.style.setProperty('--accent', o.accent);
    root.style.setProperty('--accent-soft', `color-mix(in srgb, ${o.accent} ${pageTheme() === 'dark' ? 18 : 12}%, transparent)`);
  }
  // Width and type size reflow every block, the one being read included.
  const width = o.width && o.width !== root.dataset.width;
  const size = o.fontSize && root.style.getPropertyValue('--size') !== `${o.fontSize}px`;
  if (width || size) {
    const anchor = captureAnchor(), bottom = atBottom();
    keepPlace(() => {
      if (width) root.dataset.width = o.width;
      if (size) root.style.setProperty('--size', `${o.fontSize}px`);
      measureTables();   // the column decides which tables scroll
    }, { ratio: true, anchor, bottom });
    // Diagram text follows the reading size. A diagram in view is drawn
    // again a moment later at its new size: the reader keeps the same place
    // through that too, unless they have scrolled since.
    if (size) {
      const y = document.scrollingElement.scrollTop;
      rerenderMermaid().then(() => {
        if (document.scrollingElement.scrollTop !== y) return;
        holdPlace(anchor, bottom, true);
        rebaselineHeights();
      });
    }
  }
  if (o.strings) {
    mergeStrings(o.strings);
    relabelButtons();
  }
  if (o.codeWrap !== undefined) setCodeWrap(!!o.codeWrap);
  if (o.topInset !== undefined) {
    // The inset pads the top of the document: a reader inside it keeps their
    // place (at the top, the document moves down from under the toolbar).
    const inset = `${Math.max(0, +o.topInset || 0)}px`;
    if (root.style.getPropertyValue('--top-inset') !== inset) {
      const set = () => root.style.setProperty('--top-inset', inset);
      if (document.scrollingElement.scrollTop > 0) keepPlace(set); else { set(); rebaselineHeights(); }
    }
  }
  if (o.mode === 'quicklook') { enableQuicklook(); staticRemoteImages(); }
  scheduleRail();
  if (!resizeAnchor) settle();
}

/**
 * The TOC's jump to a section: its heading 16 px under the toolbar. The TOC
 * shows that section as the current one until the reader scrolls (the line
 * the current heading is read at lies lower, and a document ending soon
 * after cannot bring the heading up there).
 */
function scrollToSlot(slot) {
  const el = slots.get(slot);
  if (!el) return;
  aimAt(el, () => el.getBoundingClientRect().top - 16 - topInset(), () => { pinActiveHeading(slot); noteLanding(el); pinLanding(el); });
  highlightOnScreen();
}

/**
 * Code on screen where the app put the reader (a resumed place, a section)
 * is highlighted before that is painted: the first open highlighted what
 * was on screen at the top, and the rest waits for the lazy observer, which
 * hears of it only after a frame has shown it plain.
 */
function highlightOnScreen() { highlightIn(blocksOnScreen()); }

function scrollToAnchor(a) {
  if (!a) return;
  trace('scrollToAnchor', { slot: a.slot, offset: Math.round(a.offset) });
  restoreAnchor(a, new Set());
  highlightOnScreen();
}

function scrollToFragment(o) {
  const target = resolveFragment(o && o.fragment);
  if (target) { scrollToElement(target, { gap: 16 }); noteLanding(target); reportActiveHeading(); highlightOnScreen(); }
}

window.readout = {
  apply,
  setAppearance,
  scrollToSlot,
  scrollToAnchor,
  scrollToFragment,
  captureAnchor,
  trace: traceEntries,
  // The find field (⌘F, ⌘G, Return): the next or previous match, and the find bar closed.
  find,
  findEnd,
  preparePrint,
  nextChange: () => jump(1),
  previousChange: () => jump(-1),
  // N went on from another document with nothing unread left: to this one's first change.
  firstChange: () => jump(1, true),
  selectedSlots,
  // A passing note above the document ("Marked against the last commit").
  notice: text => { if (text) showNotice(String(text)); },
  // The app's notice no longer holds (Compare with Last Commit undone): gone now, if it is the one showing.
  hideNotice: text => hideNotice(String(text ?? '')),
  // The window is key (or no longer): focus in its outline or find field is still the reader reading.
  setWindowKey: on => { setWindowKey(on); if (on) { restartDwell(); noticeMaybeSeen(); } },
  markAllRead,
  toggleDiff,
  // View ▸ Show What Changed: what D does.
  toggleDiffInView,
  remoteReady,
  remoteFailed,
  remoteKnown,
  warm: () => hl.warm(),
};

post({ type: 'ready' });

// ---------------------------------------------------------------- Printing

/**
 * Called by the app before it prints: draws every diagram and highlights
 * every code block, wherever they are (they are otherwise done lazily, near
 * the viewport), diagrams in the light theme paper prints in. Resolves when
 * done, or after a few seconds regardless. afterprint draws them back.
 */
async function preparePrint() {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const deadline = performance.now() + 8000;
  setPrintDiagrams(true);
  highlightAll();
  await Promise.race([renderAllMermaid(), wait(8000)]);
  // Code whose grammar is still loading is highlighted when it arrives.
  while (doc.querySelector('.code-block[data-hl="pending"], .code-block[data-hl="loading"], .code-block[data-hl="recheck"]')
         && performance.now() < deadline) {
    await wait(50);
    highlightAll();
  }
  // The app prints right away; should printing not begin, the diagrams go
  // back to the page's theme.
  clearTimeout(printFallback);
  printFallback = setTimeout(() => setPrintDiagrams(false), 5000);
  return true;
}
let printFallback = null;

// Printing shows the whole document: folded <details> open, all code
// highlighted; afterwards the screen is as it was.
let printOpened = [];
let printAnchor = null;
// Unfolding and refolding are not content changes: heights are re-baselined
// before the place is restored, so the resize compensator does not move the
// reader a second time.
window.addEventListener('beforeprint', () => {
  printAnchor = captureAnchor();
  printOpened = [...document.querySelectorAll('#ro-doc details:not([open])')];
  printOpened.forEach(d => { d.open = true; });
  clearTimeout(printFallback);
  setPrintDiagrams(true);
  highlightAll();
  rebaselineHeights();
  if (printAnchor) restoreAnchor(printAnchor, new Set());
});
window.addEventListener('afterprint', () => {
  printOpened.forEach(d => { d.open = false; });
  printOpened = [];
  setPrintDiagrams(false);   // redrawn in the page's theme, in place (from the cache)
  rebaselineHeights();
  if (printAnchor) restoreAnchor(printAnchor, new Set());
  printAnchor = null;
});
