// Readout renderer: applies block patches from the native side, keeps the reading position
// stable, shows unread changes, and renders code, math and diagrams lazily.
//
// Modules (web/src/reader/):
//   core     shared state, strings, native message channel
//   anchor   reading position, resize compensation, #fragment resolution
//   patch    applying RenderPatches
//   marks    unread marks, read detection, jumps, Show Only Changes
//   rail     change rail
//   enhance  per-block code/table/heading/remote setup, lazy highlighting
//   math / mermaid / remote / heading
import * as hl from './highlight.js';
import { doc, root, slots, heights, post, mergeStrings, enableQuicklook, pageTheme, trace, traceEntries, onKeptScroll, setWindowKey } from './reader/core.js';
import { captureAnchor, restoreAnchor, resolveFragment, scrollToElement, keepPlace, holdPlace, rebaselineHeights, topInset, atBottom, blocksOnScreen } from './reader/anchor.js';
import { apply as applyPatch, findMode, showNotice, noticeMaybeSeen } from './reader/patch.js';
import { jump, markAllRead, setChangesOnly, initChangesOnly, toggleDiff, toggleDiffInView, setPrinting, closePopups, noteLanding, restartDwell } from './reader/marks.js';
import { scheduleRail } from './reader/rail.js';
import { relabelHeadingLinks, setCodeWrap, highlightAll, measureTables, highlightIn } from './reader/enhance.js';
import { rerenderMermaid, renderAllMermaid, setPrintDiagrams } from './reader/mermaid.js';
import { remoteReady, remoteFailed, remoteKnown, staticRemoteImages } from './reader/remote.js';
import { reportActiveHeading, pinActiveHeading } from './reader/heading.js';

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

// Copied text says what the document says, the way its Markdown wrote it:
// not the comparison or removed-text panels open in it (unless the
// selection lies inside one), math as its TeX source rather than KaTeX's
// two renderings of it, task boxes as [ ] and [x], footnote references as
// [^n] without the ↩ links back. A selection without any of those copies as
// the browser copies it. Rich text carries the same cleaned-up content, so
// pasting it somewhere styled shows no panel, button or doubled formula.
const COPY_SPECIAL = '.wd-panel, .del-pop, .del-mark, button, .cb-tools, .math, .math-block, .math-display, .katex, .task-box, [data-footnote-ref], [data-footnote-backref], section.footnotes li';
document.addEventListener('copy', ev => {
  const sel = getSelection();
  if (!ev.clipboardData || !sel || sel.isCollapsed || !sel.rangeCount) return;
  const range = sel.getRangeAt(0);
  let within = range.commonAncestorContainer;
  if (within.nodeType !== Node.ELEMENT_NODE) within = within.parentElement;
  if (!within || !doc.contains(within) || within.closest('.wd-panel, .del-pop')) return;
  const box = document.createElement('div');
  for (let i = 0; i < sel.rangeCount; i++) box.appendChild(sel.getRangeAt(i).cloneContents());
  if (!box.querySelector(COPY_SPECIAL) && !within.closest('.math, .math-block, .math-display')) return;
  // A selection inside one formula copies that formula.
  const math = within.closest('.math, .math-block, .math-display');
  if (math) box.replaceChildren(math.cloneNode(true));
  box.querySelectorAll('.wd-panel, .del-pop, .del-mark, button, .cb-tools').forEach(e => e.remove());
  for (const m of box.querySelectorAll('.math, .math-block, .math-display')) {
    if (!box.contains(m)) continue;   // inside another formula, replaced with it
    const tex = m.dataset.tex ?? m.querySelector('annotation[encoding="application/x-tex"]')?.textContent ?? m.textContent;
    const display = m.matches('.math-block, .math-display');
    m.replaceWith(display ? `$$${tex}$$` : `$${tex}$`);
  }
  // KaTeX output without its wrapper (a selection that began inside it).
  for (const k of box.querySelectorAll('.katex')) {
    const tex = k.querySelector('annotation[encoding="application/x-tex"]')?.textContent;
    k.replaceWith(tex != null ? `$${tex}$` : '');
  }
  for (const t of box.querySelectorAll('.task-box')) t.replaceWith(t.classList.contains('checked') ? '[x] ' : '[ ] ');
  box.querySelectorAll('[data-footnote-backref]').forEach(e => e.remove());
  for (const a of box.querySelectorAll('[data-footnote-ref]')) (a.closest('sup') || a).replaceWith(`[^${a.textContent.trim()}]`);
  for (const li of box.querySelectorAll('section.footnotes li[id]')) {
    const orig = doc.querySelector(`[id="${CSS.escape(li.id)}"]`);
    const n = orig ? [...orig.parentElement.children].indexOf(orig) + 1 : 0;
    if (n) (li.querySelector(':scope > p') || li).prepend(`[^${n}]: `);
  }
  // innerText needs the content laid out: off screen, in the column's width
  // and in the white-space of where it came from (code keeps its lines).
  box.setAttribute('aria-hidden', 'true');
  box.style.cssText = `position: fixed; left: -100000px; top: 0; width: ${doc.clientWidth}px; white-space: ${getComputedStyle(within).whiteSpace}; pointer-events: none;`;
  document.body.appendChild(box);
  const text = box.innerText;
  box.remove();
  // The page's own wrappers and state (blocks, marks, slots) are not content.
  for (const b of box.querySelectorAll('.blk')) b.replaceWith(...b.childNodes);
  box.querySelectorAll('[tabindex]').forEach(e => e.removeAttribute('tabindex'));
  ev.clipboardData.setData('text/plain', text);
  ev.clipboardData.setData('text/html', box.innerHTML);
  ev.preventDefault();
});

// ---------------------------------------------------------------- Copy as Quote

// Edit ▸ Copy as Quote quotes the blocks the selection touches, whole (the
// app has their Markdown source): the page says which, and whether there is
// anything to quote (the menu item is enabled while there is). With no text
// selected, the block the keyboard is on (where N, a rail tick or Tab went),
// so "N, then Copy as Quote" needs no mouse.
let hadSelection = false;
const textSelected = () => {
  const sel = getSelection();
  return !!sel && !sel.isCollapsed && sel.rangeCount > 0 && doc.contains(sel.anchorNode) && sel.toString().trim() !== '';
};
const focusedBlock = () => {
  const a = document.activeElement;
  return a && doc.contains(a) ? a.closest('#ro-doc > .blk[data-slot]') : null;
};
function reportSelection() {
  const has = textSelected() || !!focusedBlock();
  if (has !== hadSelection) { hadSelection = has; post({ type: 'selection', has }); }
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

// A long jump aims again every frame for this long (see scrollToEdge, scrollToSlot).
const AIM_MS = 1000;

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
  settleTimer = setTimeout(() => { settledAnchor = captureAnchor(); settledBottom = atBottom(); settledY = document.scrollingElement.scrollTop; }, 100);
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
    relabelHeadingLinks();
  }
  if (o.changesOnly !== undefined) initChangesOnly(o.changesOnly);
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
 * after cannot bring the heading up there). In a large document the blocks
 * around the place it lands are laid out over the next frames and move it:
 * it aims again as they get their real heights, unless the reader scrolled.
 */
const LANDING_BLOCKS = 40;
let aiming = null;   // the TOC jump being aimed: {y}, where its last aim left the page
onKeptScroll(dy => { if (aiming) aiming.y += dy; });
function scrollToSlot(slot) {
  const el = slots.get(slot);
  if (!el) return;
  const off = () => el.getBoundingClientRect().top - 16 - topInset();
  // The blocks it lands on are laid out at once, at their real size (a
  // screenful and more), and handed back once a frame has rendered them.
  const cv = doc.classList.contains('cv');
  const forced = [];
  if (cv) {
    for (let e = el; e && forced.length < LANDING_BLOCKS; e = e.nextElementSibling) {
      if (e.classList.contains('blk') && !e.style.contentVisibility) { e.style.contentVisibility = 'visible'; forced.push(e); }
    }
  }
  window.scrollBy(0, off());
  for (const e of forced) heights.set(e, e.getBoundingClientRect().height);
  pinActiveHeading(slot);
  noteLanding(el);
  highlightOnScreen();
  if (!cv) return;
  requestAnimationFrame(() => requestAnimationFrame(() => { for (const e of forced) e.style.contentVisibility = ''; }));
  const se = document.scrollingElement;
  const mine = aiming = { y: se.scrollTop };
  const until = performance.now() + AIM_MS;
  const reaim = () => {
    // Another jump since, or the reader scrolled (the scroll event telling
    // the TOC may not have run yet): leave the page where it is.
    if (aiming !== mine || !el.isConnected || Math.abs(se.scrollTop - mine.y) > 2) return;
    const d = off();
    if (Math.abs(d) > 1) { window.scrollBy(0, d); mine.y = se.scrollTop; pinActiveHeading(slot); noteLanding(el); }
    if (performance.now() < until) requestAnimationFrame(reaim);
  };
  requestAnimationFrame(reaim);
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
  setChangesOnly,
  scrollToSlot,
  scrollToAnchor,
  scrollToFragment,
  captureAnchor,
  trace: traceEntries,
  findMode,
  preparePrint,
  nextChange: () => jump(1),
  previousChange: () => jump(-1),
  // N went on from another document with nothing unread left: to this one's first change.
  firstChange: () => jump(1, true),
  selectedSlots,
  // A passing note above the document ("Marked against the last commit").
  notice: text => { if (text) showNotice(String(text)); },
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

// Printing shows the whole document: folded <details> open, the changes-only
// filter lifted, all code highlighted; afterwards the screen is as it was.
let printOpened = [];
let printAnchor = null;
// Unfolding and refolding are not content changes: heights are re-baselined
// before the place is restored, so the resize compensator does not move the
// reader a second time.
window.addEventListener('beforeprint', () => {
  printAnchor = captureAnchor();
  printOpened = [...document.querySelectorAll('#ro-doc details:not([open])')];
  printOpened.forEach(d => { d.open = true; });
  setPrinting(true);
  clearTimeout(printFallback);
  setPrintDiagrams(true);
  highlightAll();
  rebaselineHeights();
  if (printAnchor) restoreAnchor(printAnchor, new Set());
});
window.addEventListener('afterprint', () => {
  printOpened.forEach(d => { d.open = false; });
  printOpened = [];
  setPrinting(false);
  setPrintDiagrams(false);   // redrawn in the page's theme, in place (from the cache)
  rebaselineHeights();
  if (printAnchor) restoreAnchor(printAnchor, new Set());
  printAnchor = null;
});
