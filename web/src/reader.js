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
import { doc, root, slots, post, mergeStrings, enableQuicklook, pageTheme } from './reader/core.js';
import { captureAnchor, restoreAnchor, resolveFragment, scrollToElement, keepPlace, holdPlace, rebaselineHeights, topInset, atBottom } from './reader/anchor.js';
import { apply as applyPatch, findMode } from './reader/patch.js';
import { jump, markAllRead, setChangesOnly, initChangesOnly, toggleDiff, toggleDiffInView, setPrinting } from './reader/marks.js';
import { scheduleRail } from './reader/rail.js';
import { relabelHeadingLinks, setCodeWrap, highlightAll } from './reader/enhance.js';
import { rerenderMermaid, renderAllMermaid, setPrintDiagrams } from './reader/mermaid.js';
import { remoteReady, remoteFailed } from './reader/remote.js';
import { reportActiveHeading } from './reader/heading.js';

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

document.addEventListener('keydown', ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.target.closest && ev.target.closest('input, textarea')) return;
  if (ev.key === 'n') { jump(1); ev.preventDefault(); }
  else if (ev.key === 'N') { jump(-1); ev.preventDefault(); }
  else if (ev.key === 'j') { window.scrollBy(0, 60); }
  else if (ev.key === 'k') { window.scrollBy(0, -60); }
  else if (ev.key === 'g') { window.scrollTo(0, 0); }
  else if (ev.key === 'd') { toggleDiffInView(); }
  else if (ev.key === 'G') { window.scrollTo(0, document.scrollingElement.scrollHeight); }
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
let settledAnchor = null;
let settledBottom = false;
let settleTimer = null;
function settle() {
  settledAnchor = null;
  clearTimeout(settleTimer);
  settleTimer = setTimeout(() => { settledAnchor = captureAnchor(); settledBottom = atBottom(); }, 100);
}

let resizeAnchor = null;
let resizeBottom = false;
let resizeEnd = null;
window.addEventListener('resize', () => {
  if (!resizeAnchor) {
    resizeBottom = settledAnchor ? settledBottom : atBottom();
    resizeAnchor = settledAnchor || captureAnchor();
  }
  if (!resizeAnchor) return;
  const hold = () => {
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
  if (o.mode === 'quicklook') enableQuicklook();
  scheduleRail();
  if (!resizeAnchor) settle();
}

function scrollToSlot(slot) {
  const el = slots.get(slot);
  if (el) { window.scrollBy(0, el.getBoundingClientRect().top - 16 - topInset()); reportActiveHeading(); }
}

function scrollToAnchor(a) {
  if (!a) return;
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
