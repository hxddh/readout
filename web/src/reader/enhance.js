// Per-block enhancement after a block's HTML is set: code tools and
// highlighting, table overflow, remote-image placeholders, heading links,
// math. Expensive work (highlighting, diagrams) runs lazily near the viewport.
import * as hl from '../highlight.js';
import { doc, root, strings, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor } from './anchor.js';
import { setupRemoteImage } from './remote.js';
import { renderMath } from './math.js';
import { renderMermaid } from './mermaid.js';

export function enhance(el) {
  for (const cb of el.querySelectorAll('.code-block')) setupCode(cb);
  for (const t of el.querySelectorAll('.table-wrap')) requestAnimationFrame(() => measureTable(t));
  for (const r of el.querySelectorAll('.remote-img')) setupRemoteImage(r);
  for (const h of el.classList.contains('k-heading') ? [el] : []) setupHeadingLink(h);
  if (el.querySelector('.math, .math-block')) renderMath(el);
}

/** A table wider than the column scrolls sideways (and pins its first column). */
function measureTable(t) {
  t.classList.toggle('scrolls', t.scrollWidth > t.clientWidth + 1);
}

// The window width decides which tables scroll.
let tablesQueued = false;
window.addEventListener('resize', () => {
  if (tablesQueued) return;
  tablesQueued = true;
  requestAnimationFrame(() => { tablesQueued = false; doc.querySelectorAll('.table-wrap').forEach(measureTable); });
});

/** Hover link button on headings: copies a `#anchor` link for the section. */
function setupHeadingLink(h) {
  if (h.querySelector('.h-link')) return;
  const anchor = h.dataset.anchor;
  if (!anchor) return;
  const btn = document.createElement('button');
  btn.className = 'h-link';
  btn.type = 'button';
  btn.textContent = '§';
  btn.title = strings.copyLink || 'Copy Link to Section';
  btn.setAttribute('aria-label', btn.title);
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    post({ type: 'copyLink', anchor });
    btn.textContent = '✓';
    setTimeout(() => { btn.textContent = '§'; }, 1200);
  });
  h.appendChild(btn);
}

/**
 * Code wrapping is one choice for every code block, remembered by the app.
 * Wrapping reflows the page, so the reading position is kept.
 */
export function setCodeWrap(on) {
  if ((root.dataset.codeWrap === 'on') === on) return;
  const anchor = captureAnchor();
  root.dataset.codeWrap = on ? 'on' : 'off';
  restoreAnchor(anchor, new Set());
}

function toggleCodeWrap() {
  const on = root.dataset.codeWrap !== 'on';
  setCodeWrap(on);
  post({ type: 'setCodeWrap', on });
}

/** Re-labels heading link buttons after the strings change. */
export function relabelHeadingLinks() {
  for (const h of doc.querySelectorAll('.k-heading .h-link')) {
    h.title = strings.copyLink || h.title;
    h.setAttribute('aria-label', h.title);
  }
  for (const w of doc.querySelectorAll('.cb-wrap')) {
    w.textContent = strings.wrap || w.textContent;
    w.title = strings.wrapTitle || w.title;
  }
}

function setupCode(cb) {
  if (cb.querySelector('.cb-tools')) return;
  const tools = document.createElement('div');
  tools.className = 'cb-tools';
  if (cb.dataset.lang) {
    const lang = document.createElement('span');
    lang.className = 'cb-lang';
    lang.textContent = cb.dataset.lang;
    tools.appendChild(lang);
  }
  const wrap = document.createElement('button');
  wrap.className = 'cb-wrap';
  wrap.type = 'button';
  wrap.textContent = strings.wrap || 'Wrap';
  wrap.title = strings.wrapTitle || 'Wrap long lines in code blocks';
  wrap.addEventListener('click', ev => {
    ev.stopPropagation();
    toggleCodeWrap();
  });
  tools.appendChild(wrap);
  const btn = document.createElement('button');
  btn.className = 'cb-copy';
  btn.type = 'button';
  btn.textContent = strings.copy;
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    const code = cb.querySelector('pre').innerText.replace(/\n$/, '');
    post({ type: 'copy', text: code });
    btn.textContent = strings.copied;
    setTimeout(() => { btn.textContent = strings.copy; }, 1400);
  });
  tools.appendChild(btn);
  cb.appendChild(tools);
  cb.dataset.hl = 'pending';
  fresh.push(cb);
}

// Code blocks set up since the last renderLazy(): only these are looked at
// after a patch, so an update costs nothing for the rest of the document.
let fresh = [];

// Shiki gives up on a line after 500 ms and colors the rest of it, and the
// lines after, with whatever scope it was in. The first lines a grammar sees
// also pay for compiling its patterns, which on a busy machine can cross that
// limit: a block then comes out wrong (e.g. all comment-gray). So the first
// block highlighted with a grammar, if it took suspiciously long, is redone
// once shortly after, when the patterns are compiled. Blocks highlighted
// with a warm grammar are never redone, however long they take (many fast
// lines add up; that is not a cut-short line). The 500 ms guard stays.
const SLOW_HIGHLIGHT_MS = 200;
const sourceOf = new WeakMap();   // code block -> original code text
const warmGrammars = new Set();   // grammar ids that have highlighted a block
const prepared = new WeakSet();   // code blocks whose grammars have been loaded once

function highlightBlock(cb) {
  const recheck = cb.dataset.hl === 'recheck';
  if (cb.dataset.hl !== 'pending' && !recheck) return;
  const id = hl.resolveLang(cb.dataset.lang);
  if (!id) { cb.dataset.hl = 'none'; return; }
  const pre = cb.querySelector('pre');
  if (!sourceOf.has(cb)) sourceOf.set(cb, pre.textContent);
  const code = sourceOf.get(cb);
  const started = performance.now();
  const html = hl.highlightSync(code, id);
  const cold = !warmGrammars.has(id);
  const slow = !recheck && cold && performance.now() - started > SLOW_HIGHLIGHT_MS;
  if (html) warmGrammars.add(id);
  if (html) {
    const tpl = document.createElement('template');
    tpl.innerHTML = html;
    const newPre = tpl.content.firstElementChild;
    if (id === 'diff') {
      for (const line of newPre.querySelectorAll('.line')) {
        const t = line.textContent;
        if (t.startsWith('+') && !t.startsWith('+++')) line.classList.add('add');
        else if (t.startsWith('-') && !t.startsWith('---')) line.classList.add('del');
      }
    }
    pre.replaceWith(newPre);
    cb.dataset.hl = slow ? 'recheck' : 'done';
    if (slow) setTimeout(() => { if (cb.isConnected) highlightBlock(cb); else cb.dataset.hl = 'done'; }, 50);
  } else if (prepared.has(cb)) {
    cb.dataset.hl = 'none';   // everything it needs was loaded and it still failed
  } else {
    cb.dataset.hl = 'loading';
    prepared.add(cb);
    hl.prepare(id, code).then(() => { cb.dataset.hl = 'pending'; if (cb.isConnected) highlightBlock(cb); });
  }
}

// Lazy work is triggered for anything within one screen of the viewport.
// It runs in slices of a few milliseconds, so scrolling into a run of code
// blocks never stalls a frame for long; the margin leaves time to finish
// before they are on screen.
export const lazyObserver = new IntersectionObserver(entries => {
  for (const e of entries) if (e.isIntersecting) { lazyObserver.unobserve(e.target); queue.push(e.target); }
  pump();
}, { rootMargin: '100% 0px 100% 0px' });

const SLICE_MS = 6;
const queue = [];
let pumping = false;

function pump() {
  if (pumping || !queue.length) return;
  pumping = true;
  setTimeout(() => {
    pumping = false;
    const start = performance.now();
    while (queue.length && performance.now() - start < SLICE_MS) {
      const el = queue.shift();
      if (el.isConnected) lazyWork(el);
    }
    pump();
  }, 0);
}

function lazyWork(el) {
  if (el.classList.contains('code-block')) highlightBlock(el);
  else if (el.classList.contains('mermaid-block')) renderMermaid(el);
}

/** Highlights every code block not highlighted yet, wherever it is (printing). */
export function highlightAll() {
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) highlightBlock(cb);
}

export function renderLazy() {
  const blocks = fresh;
  fresh = [];
  // Blocks on screen now are highlighted before the next paint (no flash of
  // plain code); the rest wait until they come near.
  const onScreen = [];
  for (const cb of blocks) {
    if (!cb.isConnected || cb.dataset.hl !== 'pending') continue;
    if (inViewport(cb)) onScreen.push(cb); else lazyObserver.observe(cb);
  }
  for (const cb of onScreen) highlightBlock(cb);
  for (const m of doc.querySelectorAll('.mermaid-block:not(.done):not(.busy)')) lazyObserver.observe(m);
}
