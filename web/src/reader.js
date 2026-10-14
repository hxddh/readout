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
import { doc, root, slots, heights, post, mergeStrings, enableQuicklook, pageTheme, trace, traceEntries, onKeptScroll } from './reader/core.js';
import { captureAnchor, restoreAnchor, resolveFragment, scrollToElement, keepPlace, holdPlace, rebaselineHeights, topInset, atBottom } from './reader/anchor.js';
import { apply as applyPatch, findMode } from './reader/patch.js';
import { jump, markAllRead, setChangesOnly, initChangesOnly, toggleDiff, toggleDiffInView, setPrinting, closePopups } from './reader/marks.js';
import { scheduleRail } from './reader/rail.js';
import { relabelHeadingLinks, setCodeWrap, highlightAll, measureTables } from './reader/enhance.js';
import { rerenderMermaid, renderAllMermaid, setPrintDiagrams } from './reader/mermaid.js';
import { remoteReady, remoteFailed, staticRemoteImages } from './reader/remote.js';
import { reportActiveHeading, pinActiveHeading } from './reader/heading.js';

// ---------------------------------------------------------------- Links & keys

doc.addEventListener('click', ev => {
  const path = ev.target.closest('code.path-link');
  if (path) {
    ev.preventDefault();
    post({ type: 'openPath', path: path.dataset.path, line: +path.dataset.line || 0, column: +path.dataset.col || 0 });
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
    if (note) {
      const spot = target.closest('li, sup') || target;
      spot.classList.remove('landed'); void spot.offsetWidth; spot.classList.add('landed');
    }
    return;
  }
  post({ type: 'open', href });
});

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
  const aim = () => { window.scrollTo(0, end ? se.scrollHeight : 0); mine.y = se.scrollTop; };
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
    keepPlace(() => {
      if (width) root.dataset.width = o.width;
      if (size) root.style.setProperty('--size', `${o.fontSize}px`);
      measureTables();   // the column decides which tables scroll
    }, { ratio: true });
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
    if (Math.abs(d) > 1) { window.scrollBy(0, d); mine.y = se.scrollTop; pinActiveHeading(slot); }
    if (performance.now() < until) requestAnimationFrame(reaim);
  };
  requestAnimationFrame(reaim);
}

function scrollToAnchor(a) {
  if (!a) return;
  trace('scrollToAnchor', { slot: a.slot, offset: Math.round(a.offset) });
  restoreAnchor(a, new Set());
}

function scrollToFragment(o) {
  const target = resolveFragment(o && o.fragment);
  if (target) { scrollToElement(target, { gap: 16 }); reportActiveHeading(); }
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
  markAllRead,
  toggleDiff,
  remoteReady,
  remoteFailed,
  warm: () => hl.init(),
};

hl.init();
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
