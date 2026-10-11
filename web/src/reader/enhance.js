// Per-block enhancement after a block's HTML is set: code tools and
// highlighting, table overflow, remote-image placeholders, heading links,
// math. Expensive work (highlighting, diagrams) runs lazily near the viewport.
import * as hl from '../highlight.js';
import { doc, strings, post, inViewport } from './core.js';
import { setupRemoteImage } from './remote.js';
import { renderMath } from './math.js';
import { renderMermaid } from './mermaid.js';

export function enhance(el) {
  for (const cb of el.querySelectorAll('.code-block')) setupCode(cb);
  for (const t of el.querySelectorAll('.table-wrap')) {
    requestAnimationFrame(() => t.classList.toggle('scrolls', t.scrollWidth > t.clientWidth + 1));
  }
  for (const r of el.querySelectorAll('.remote-img')) setupRemoteImage(r);
  for (const h of el.classList.contains('k-heading') ? [el] : []) setupHeadingLink(h);
  if (el.querySelector('.math, .math-block')) renderMath(el);
}

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

/** Re-labels heading link buttons after the strings change. */
export function relabelHeadingLinks() {
  for (const h of doc.querySelectorAll('.k-heading .h-link')) {
    h.title = strings.copyLink || h.title;
    h.setAttribute('aria-label', h.title);
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
}

// Shiki gives up on a line after 500 ms and colors the rest of it, and the
// lines after, with whatever scope it was in. The first lines a grammar sees
// also pay for compiling its patterns, which on a busy machine can cross that
// limit: a block then comes out wrong (e.g. all comment-gray). A highlight
// that took suspiciously long is redone once, shortly after, when the
// patterns are compiled; the 500 ms guard against runaway lines stays.
const SLOW_HIGHLIGHT_MS = 200;
const sourceOf = new WeakMap();   // code block -> original code text

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
  const slow = !recheck && performance.now() - started > SLOW_HIGHLIGHT_MS;
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
  } else {
    cb.dataset.hl = 'loading';
    hl.ensureLang(id).then(() => { cb.dataset.hl = 'pending'; if (cb.isConnected) highlightBlock(cb); });
  }
}

// Lazy work is triggered for anything within one screen of the viewport.
export const lazyObserver = new IntersectionObserver(entries => {
  for (const e of entries) if (e.isIntersecting) { lazyObserver.unobserve(e.target); lazyWork(e.target); }
}, { rootMargin: '100% 0px 100% 0px' });

function lazyWork(el) {
  if (el.classList.contains('code-block')) highlightBlock(el);
  else if (el.classList.contains('mermaid-block')) renderMermaid(el);
}

export function renderLazy() {
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) {
    if (inViewport(cb, window.innerHeight)) highlightBlock(cb); else lazyObserver.observe(cb);
  }
  for (const m of doc.querySelectorAll('.mermaid-block:not(.done):not(.busy)')) lazyObserver.observe(m);
}
