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
import { doc, root, slots, post, mergeStrings, enableQuicklook } from './reader/core.js';
import { captureAnchor, restoreAnchor, resolveFragment, scrollToElement } from './reader/anchor.js';
import { apply } from './reader/patch.js';
import { jump, markAllRead, setChangesOnly, initChangesOnly, toggleDiff, toggleDiffInView } from './reader/marks.js';
import { scheduleRail } from './reader/rail.js';
import { relabelHeadingLinks, setCodeWrap } from './reader/enhance.js';
import { rerenderMermaid } from './reader/mermaid.js';
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
  });
}, { passive: true });

// ---------------------------------------------------------------- Native API

function setAppearance(o) {
  if (o.dark !== undefined) {
    const t = o.dark ? 'dark' : 'light';
    if (root.dataset.theme !== t) {
      root.dataset.theme = t;
      rerenderMermaid();
    }
  }
  if (o.accent) {
    root.style.setProperty('--accent', o.accent);
    root.style.setProperty('--accent-soft', `color-mix(in srgb, ${o.accent} ${root.dataset.theme === 'dark' ? 18 : 12}%, transparent)`);
  }
  if (o.width) root.dataset.width = o.width;
  if (o.fontSize) root.style.setProperty('--size', `${o.fontSize}px`);
  if (o.strings) {
    mergeStrings(o.strings);
    relabelHeadingLinks();
  }
  if (o.changesOnly !== undefined) initChangesOnly(o.changesOnly);
  if (o.codeWrap !== undefined) setCodeWrap(!!o.codeWrap);
  if (o.topInset !== undefined) root.style.setProperty('--top-inset', `${Math.max(0, +o.topInset || 0)}px`);
  if (o.mode === 'quicklook') enableQuicklook();
  scheduleRail();
}

function scrollToSlot(slot) {
  const el = slots.get(slot);
  if (el) { window.scrollBy(0, el.getBoundingClientRect().top - 16); reportActiveHeading(); }
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

// Printing shows folded <details> open (and folds them back afterwards).
let printOpened = [];
window.addEventListener('beforeprint', () => {
  printOpened = [...document.querySelectorAll('#ro-doc details:not([open])')];
  printOpened.forEach(d => { d.open = true; });
});
window.addEventListener('afterprint', () => {
  printOpened.forEach(d => { d.open = false; });
  printOpened = [];
});
