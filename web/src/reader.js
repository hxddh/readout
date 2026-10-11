// Readout renderer: applies block patches from the native side, keeps the reading position
// stable, shows unread changes, and renders code, math and diagrams lazily.
import * as hl from './highlight.js';

const doc = document.getElementById('ro-doc');
const rail = document.getElementById('ro-rail');
const notice = document.getElementById('ro-notice');
const caughtup = document.getElementById('ro-caughtup');
const root = document.documentElement;

const slots = new Map();          // slot -> element
const heights = new WeakMap();    // element -> last observed height
const mermaidCache = new Map();   // source+theme -> svg
const mathCache = new Map();      // tex+display -> html
let strings = { copy: 'Copy', copied: 'Copied', loadImage: 'Load image from %@', remoteError: 'Could not load image: %@', rewritten: 'Rewritten since you last looked', diagramError: 'Diagram could not be drawn', caughtUp: 'All caught up', copyLink: 'Copy Link to Section' };
let remoteSeq = 0;
let first = true;
let quicklook = false;
let followAnchor = null;
let changesOnly = false;

/**
 * "Show Only Changes": hides read blocks so the reader sees just what's new.
 * Headings stay visible as context; blocks with unread marks or deletion
 * markers (and headings) are kept. Hidden blocks leave the anchor and jump
 * math untouched — `unreadElements()` already skips them via offsetParent.
 */
function applyChangesOnly() {
  for (const el of slots.values()) {
    const keep = el.classList.contains('k-heading')
      || el.classList.contains('m-inserted') || el.classList.contains('m-modified')
      || el.classList.contains('m-state') || el.nextElementSibling?.classList.contains('del-mark');
    el.hidden = changesOnly && !keep;
  }
  for (const m of doc.querySelectorAll('.del-mark')) m.hidden = false;
  if (caughtup) {
    const anyVisible = changesOnly && unreadElements().length === 0 && slots.size > 0;
    caughtup.textContent = anyVisible ? (strings.caughtUp || 'All caught up') : '';
    caughtup.hidden = !anyVisible;
  }
  scheduleRail();
}

function setChangesOnly(on) {
  // Toggling the filter reflows the document: capture first, restore after,
  // so the reader keeps their place (with nearest-visible fallback).
  const anchor = captureAnchor();
  changesOnly = !!on;
  applyChangesOnly();
  restoreAnchor(anchor, new Set());
}

function post(msg) {
  try { window.webkit.messageHandlers.readout.postMessage(msg); } catch { /* not hosted */ }
}

window.addEventListener('error', e => post({ type: 'error', message: `${e.message} (${e.filename}:${e.lineno})` }));
window.addEventListener('unhandledrejection', e => post({ type: 'error', message: `unhandled: ${e.reason && (e.reason.stack || e.reason.message) || e.reason}` }));

// ---------------------------------------------------------------- Anchors

function isShown(e) { return !e.hidden && e.offsetParent !== null; }

function blockList() { return Array.from(doc.children).filter(e => e.classList.contains('blk') && isShown(e)); }

/** Document-order list including hidden blocks (for fallback searches). */
function allBlocks() { return Array.from(doc.children).filter(e => e.classList.contains('blk')); }

/** First block whose bottom edge is below the top of the viewport. */
function topBlock() {
  const list = blockList();
  let lo = 0, hi = list.length - 1, found = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const r = list[mid].getBoundingClientRect();
    if (r.bottom > 8) { found = list[mid]; hi = mid - 1; } else { lo = mid + 1; }
  }
  return found;
}

function captureAnchor() {
  const el = topBlock();
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const offset = -r.top;
  let heading = null;
  for (let e = el; e; e = e.previousElementSibling) {
    if (e.classList.contains('k-heading')) { heading = e.dataset.anchor || null; break; }
  }
  return { slot: +el.dataset.slot, offset, ratio: r.height > 0 ? offset / r.height : 0, heading };
}

function restoreAnchor(a, changedSlots) {
  if (!a) return;
  let el = slots.get(a.slot);
  // The anchor block may have been hidden by the changes-only filter (or
  // removed): fall back to the nearest visible block in document order,
  // preferring the previous one so the reader stays with what they read.
  if (el && !isShown(el)) el = nearestVisible(el);
  if (el) {
    const r = el.getBoundingClientRect();
    const want = changedSlots.has(a.slot) ? a.ratio * r.height : a.offset;
    window.scrollBy(0, r.top + want);
    return;
  }
  if (a.heading) {
    const h = doc.querySelector(`.k-heading[data-anchor="${CSS.escape(a.heading)}"]`);
    if (h) { window.scrollBy(0, h.getBoundingClientRect().top); return; }
  }
}

/** Nearest visible block to `el` in document order (previous first, then next). */
function nearestVisible(el) {
  let p = el.previousElementSibling;
  while (p) {
    if (p.classList.contains('blk') && isShown(p)) return p;
    p = p.previousElementSibling;
  }
  let n = el.nextElementSibling;
  while (n) {
    if (n.classList.contains('blk') && isShown(n)) return n;
    n = n.nextElementSibling;
  }
  return null;
}

function atBottom() {
  const se = document.scrollingElement;
  return se.scrollHeight - (se.scrollTop + window.innerHeight) < 48 && se.scrollTop > 0;
}

// Keep blocks above the viewport from pushing content down when their height changes later
// (diagrams, math, images, content-visibility estimates becoming real).
const resizeObserver = new ResizeObserver(entries => {
  let delta = 0;
  for (const entry of entries) {
    const el = entry.target;
    const h = el.getBoundingClientRect().height;
    const prev = heights.get(el);
    heights.set(el, h);
    if (prev === undefined || prev === h) continue;
    const r = el.getBoundingClientRect();
    if (r.bottom <= 1) delta += h - prev; // entirely above the viewport
  }
  if (delta !== 0 && document.scrollingElement.scrollTop > 0) window.scrollBy(0, delta);
  scheduleRail();
});

// ---------------------------------------------------------------- Patching

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

function inViewport(el, margin = 0) {
  const r = el.getBoundingClientRect();
  return r.bottom > -margin && r.top < window.innerHeight + margin;
}

/**
 * Applies a RenderPatch: {version, reset, rewrite, ops, marks, deletions, toc, tasks, title}.
 */
function apply(p) {
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

// ---------------------------------------------------------------- Marks

let marked = new Map();   // slot -> kind (unread)
const readTimers = new Map();

function renderMarks(marks, deletions) {
  for (const el of doc.querySelectorAll('.m-inserted, .m-modified, .m-state')) {
    el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
  }
  doc.querySelectorAll('.del-mark').forEach(e => e.remove());
  marked = new Map();
  if (quicklook) return;
  for (const m of marks) {
    const el = slots.get(m.slot);
    if (!el) continue;
    el.classList.add(`m-${m.kind}`);
    marked.set(m.slot, m.kind);
    readObserver.observe(el);
  }
  for (const d of deletions) {
    const mark = document.createElement('div');
    mark.className = 'del-mark';
    mark.dataset.del = d.id;
    const btn = document.createElement('button');
    btn.title = d.count === 1 ? (strings.deletedOne || '1 block removed') : (strings.deletedMany || '%d blocks removed').replace('%d', d.count);
    btn.setAttribute('aria-label', btn.title);
    btn.addEventListener('click', ev => {
      ev.stopPropagation();
      const open = mark.querySelector('.del-pop');
      document.querySelectorAll('.del-pop').forEach(p => p.remove());
      if (open) return;
      const pop = document.createElement('pre');
      pop.className = 'del-pop';
      pop.textContent = d.preview;
      mark.appendChild(pop);
    });
    mark.appendChild(btn);
    const after = d.after ? slots.get(d.after) : null;
    if (after) after.after(mark);
    else doc.insertBefore(mark, doc.querySelector('.blk'));
    readObserver.observe(mark);
  }
}

document.addEventListener('click', () => document.querySelectorAll('.del-pop').forEach(p => p.remove()));

// A change counts as read once at least half of it has been visible for 800 ms while the window is focused.
const readObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const el = e.target;
    if (e.isIntersecting && e.intersectionRatio >= 0.5) {
      if (!readTimers.has(el)) readTimers.set(el, setTimeout(() => tryRead(el), 800));
    } else {
      clearTimeout(readTimers.get(el));
      readTimers.delete(el);
    }
  }
}, { threshold: [0, 0.5, 1] });

let pendingRead = { slots: [], deletions: [] };
function tryRead(el) {
  readTimers.delete(el);
  if (!document.hasFocus() || document.hidden) {
    // Try again when focus returns.
    readTimers.set(el, setTimeout(() => inViewport(el) && tryRead(el), 1000));
    return;
  }
  readObserver.unobserve(el);
  el.classList.add('m-read');
  if (el.classList.contains('del-mark')) pendingRead.deletions.push(+el.dataset.del);
  else { pendingRead.slots.push(+el.dataset.slot); marked.delete(+el.dataset.slot); }
  clearTimeout(tryRead.flush);
  tryRead.flush = setTimeout(() => {
    post({ type: 'read', ...pendingRead });
    pendingRead = { slots: [], deletions: [] };
    scheduleRail();
  }, 150);
  setTimeout(() => {
    if (el.classList.contains('m-read')) {
      el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
      if (el.classList.contains('del-mark')) el.remove();
    }
  }, 10000);
}

function unreadElements() {
  // `offsetParent === null` covers `hidden` blocks in changes-only mode, so the
  // rail, jumps and the caught-up state all ignore filtered-out blocks.
  return Array.from(doc.querySelectorAll('.blk.m-inserted:not(.m-read), .blk.m-modified:not(.m-read), .blk.m-state:not(.m-read), .del-mark:not(.m-read)'))
    .filter(e => e.offsetParent !== null);
}

function jump(dir) {
  const list = unreadElements();
  if (!list.length) return;
  const line = window.innerHeight / 3;
  let target;
  if (dir > 0) target = list.find(e => e.getBoundingClientRect().top > line + 4) || list[0];
  else target = list.slice().reverse().find(e => e.getBoundingClientRect().top < line - 4) || list[list.length - 1];
  const top = target.getBoundingClientRect().top - line;
  window.scrollBy({ top, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
}

function markAllRead() {
  for (const el of unreadElements()) {
    el.classList.add('m-read');
    readObserver.unobserve(el);
  }
  marked.clear();
  setTimeout(() => {
    doc.querySelectorAll('.m-read').forEach(el => {
      el.classList.remove('m-inserted', 'm-modified', 'm-state', 'm-read');
      if (el.classList.contains('del-mark')) el.remove();
    });
    applyChangesOnly();
    scheduleRail();
  }, 700);
}

// ---------------------------------------------------------------- Rail

let railQueued = false;
function scheduleRail() {
  if (railQueued || quicklook) return;
  railQueued = true;
  requestAnimationFrame(() => { railQueued = false; drawRail(); });
}

function drawRail() {
  const list = unreadElements();
  rail.replaceChildren();
  const total = document.scrollingElement.scrollHeight;
  if (!list.length || total <= window.innerHeight) return;
  const scrollTop = document.scrollingElement.scrollTop;
  const h = window.innerHeight;
  for (let i = 0; i < list.length; i++) {
    const el = list[i];
    const top = el.getBoundingClientRect().top + scrollTop;
    const tick = document.createElement('button');
    tick.type = 'button';
    const kind = el.classList.contains('m-modified') ? 'edited'
      : el.classList.contains('del-mark') ? 'removed' : 'added';
    if (el.classList.contains('m-modified')) tick.className = 'mod';
    tick.style.top = `${Math.min(h - 4, (top / total) * h)}px`;
    tick.setAttribute('aria-label', `Unread change ${i + 1} of ${list.length}: ${kind}`);
    tick.addEventListener('click', () => el.scrollIntoView({ block: 'center' }));
    rail.appendChild(tick);
  }
}

window.addEventListener('resize', scheduleRail);

// ---------------------------------------------------------------- Enhancement

function enhance(el) {
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

function highlightBlock(cb) {
  if (cb.dataset.hl !== 'pending') return;
  const id = hl.resolveLang(cb.dataset.lang);
  if (!id) { cb.dataset.hl = 'none'; return; }
  const pre = cb.querySelector('pre');
  const code = pre.textContent;
  const html = hl.highlightSync(code, id);
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
    cb.dataset.hl = 'done';
  } else {
    cb.dataset.hl = 'loading';
    hl.ensureLang(id).then(() => { cb.dataset.hl = 'pending'; if (cb.isConnected) highlightBlock(cb); });
  }
}

// Lazy work is triggered for anything within one screen of the viewport.
const lazyObserver = new IntersectionObserver(entries => {
  for (const e of entries) if (e.isIntersecting) { lazyObserver.unobserve(e.target); lazyWork(e.target); }
}, { rootMargin: '100% 0px 100% 0px' });

function lazyWork(el) {
  if (el.classList.contains('code-block')) highlightBlock(el);
  else if (el.classList.contains('mermaid-block')) renderMermaid(el);
}

function renderLazy() {
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) {
    if (inViewport(cb, window.innerHeight)) highlightBlock(cb); else lazyObserver.observe(cb);
  }
  for (const m of doc.querySelectorAll('.mermaid-block:not(.done):not(.busy)')) lazyObserver.observe(m);
}

function setupRemoteImage(span) {
  if (span.firstChild) return;
  const src = span.dataset.src;
  let host = src;
  try { host = new URL(src, 'https://x/').host; } catch { /* keep */ }
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = strings.loadImage.replace('%@', host);
  btn.addEventListener('click', () => {
    const tag = (span.dataset.tag || 'img').toLowerCase();
    if (tag !== 'img' && tag !== 'source' && tag !== 'track') {
      // Video and audio are never proxied: open externally.
      const abs = src.startsWith('//') ? `https:${src}` : src;
      post({ type: 'open', href: abs });
      return;
    }
    // The page itself cannot fetch (CSP): the native side downloads with an
    // ephemeral, cookie-free session and serves the bytes back over readout:.
    const id = `r${++remoteSeq}`;
    span.dataset.remoteId = id;
    btn.disabled = true;
    post({ type: 'loadRemote', url: src, id });
  });
  span.appendChild(btn);
}

// Called by the native side with {id, url} once bytes are cached.
function remoteReady(o) {
  const span = document.querySelector(`.remote-img[data-remote-id="${o.id}"]`);
  if (!span) return;
  const img = document.createElement('img');
  img.src = o.url;
  img.alt = span.dataset.alt || '';
  span.replaceChildren(img);
}

// Called by the native side with {id, error} when the download fails.
function remoteFailed(o) {
  const span = document.querySelector(`.remote-img[data-remote-id="${o.id}"]`);
  if (!span) return;
  const btn = span.querySelector('button');
  const msg = (strings.remoteError || 'Could not load image: %@').replace('%@', o.error || 'failed');
  if (btn) { btn.disabled = false; btn.textContent = msg; }
  else span.textContent = msg;
}

// ---------------------------------------------------------------- Math (KaTeX, loaded on demand)

let katexPromise = null;
function loadKatex() {
  if (window.katex) return Promise.resolve(window.katex);
  if (!katexPromise) {
    katexPromise = new Promise((resolve, reject) => {
      const css = document.createElement('link');
      css.rel = 'stylesheet';
      css.href = 'vendor/katex/katex.min.css';
      document.head.appendChild(css);
      const s = document.createElement('script');
      s.src = 'vendor/katex/katex.min.js';
      s.onload = () => resolve(window.katex);
      s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  return katexPromise;
}

function renderMath(el) {
  const nodes = el.querySelectorAll('.math:not(.done), .math-block:not(.done)');
  if (!nodes.length) return;
  loadKatex().then(katex => {
    for (const n of nodes) {
      if (!n.isConnected || n.classList.contains('done')) continue;
      const tex = n.dataset.tex;
      const display = n.classList.contains('math-block') || n.classList.contains('math-display');
      const key = (display ? 'D' : 'I') + tex;
      let html = mathCache.get(key);
      if (html === undefined) {
        try { html = katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'htmlAndMathml', strict: 'ignore' }); }
        catch { html = null; }
        mathCache.set(key, html);
      }
      if (html) { n.innerHTML = html; n.classList.add('done'); }
    }
  }).catch(() => {});
}

// ---------------------------------------------------------------- Mermaid (loaded on demand)

let mermaidPromise = null;
let mermaidTheme = null;
let mermaidSeq = 0;
function loadMermaid() {
  if (!mermaidPromise) {
    mermaidPromise = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'vendor/mermaid/mermaid.min.js';
      s.onload = () => resolve(window.mermaid);
      s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  return mermaidPromise.then(m => {
    const theme = root.dataset.theme === 'dark' ? 'dark' : 'neutral';
    if (theme !== mermaidTheme) {
      m.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme,
        fontFamily: '-apple-system, "SF Pro Text", "PingFang SC", sans-serif',
        themeVariables: { fontSize: '13px' },
        flowchart: { htmlLabels: true, curve: 'basis' },
        sequence: { actorFontSize: 13, messageFontSize: 13, noteFontSize: 13, useMaxWidth: true },
      });
      mermaidTheme = theme;
    }
    return m;
  });
}

const mermaidQueue = [];
let mermaidBusy = false;
function renderMermaid(block) {
  block.classList.add('busy');
  mermaidQueue.push(block);
  pumpMermaid();
}

async function pumpMermaid() {
  if (mermaidBusy) return;
  mermaidBusy = true;
  try {
    while (mermaidQueue.length) {
      const block = mermaidQueue.shift();
      if (!block.isConnected) continue;
      const srcEl = block.querySelector('.mermaid-src');
      const src = srcEl.textContent;
      const m = await loadMermaid().catch(() => null);
      if (!m) break;
      const key = mermaidTheme + '\u0000' + src;
      let out = mermaidCache.get(key);
      if (!out) {
        try {
          const { svg } = await m.render(`mmd-${++mermaidSeq}`, src);
          out = { svg };
        } catch (err) {
          out = { error: String(err && err.message || err).split('\n').slice(0, 3).join(' ') };
          document.querySelectorAll(`#dmmd-${mermaidSeq}, #mmd-${mermaidSeq}`).forEach(e => e.remove());
        }
        mermaidCache.set(key, out);
      }
      if (!block.isConnected) continue;
      block.querySelectorAll('.mermaid-svg, .mermaid-error').forEach(e => e.remove());
      if (out.svg) {
        const wrap = document.createElement('div');
        wrap.className = 'mermaid-svg';
        wrap.innerHTML = out.svg;
        block.appendChild(wrap);
        block.classList.add('done');
      } else {
        const e = document.createElement('div');
        e.className = 'mermaid-error';
        e.textContent = `${strings.diagramError}: ${out.error}`;
        block.appendChild(e);
        block.classList.remove('done');
      }
      block.classList.remove('busy');
    }
  } finally {
    mermaidBusy = false;
  }
}

function rerenderMermaid() {
  for (const b of doc.querySelectorAll('.mermaid-block')) {
    b.classList.remove('done', 'busy');
    b.querySelectorAll('.mermaid-svg, .mermaid-error').forEach(e => e.remove());
    if (inViewport(b, window.innerHeight)) renderMermaid(b); else lazyObserver.observe(b);
  }
}

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
    const id = decodeURIComponent(href.slice(1));
    // Scoped to the document container: chrome ids live under ro-* and must
    // never be a link target. Matches the heading element itself, falling
    // back to the block wrapper's anchor.
    const target = doc.querySelector(`[id="${CSS.escape(id)}"], [id="${CSS.escape(id.toLowerCase())}"]`)
      || doc.querySelector(`.k-heading[data-anchor="${CSS.escape(id.toLowerCase())}"]`);
    if (target) target.scrollIntoView({ block: 'start' });
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
  else if (ev.key === 'G') { window.scrollTo(0, document.scrollingElement.scrollHeight); }
});

// ---------------------------------------------------------------- Active heading (TOC sync)

let lastActive = null;
let scrollQueued = false;
function reportActiveHeading() {
  const headings = doc.querySelectorAll('.k-heading');
  let active = null;
  const line = 80;
  for (const h of headings) {
    if (h.getBoundingClientRect().top <= line) active = h; else break;
  }
  const slot = active ? +active.dataset.slot : (headings[0] ? +headings[0].dataset.slot : 0);
  if (slot !== lastActive) { lastActive = slot; post({ type: 'activeHeading', slot }); }
}
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
      if (mermaidPromise) rerenderMermaid();
    }
  }
  if (o.accent) {
    root.style.setProperty('--accent', o.accent);
    root.style.setProperty('--accent-soft', `color-mix(in srgb, ${o.accent} ${root.dataset.theme === 'dark' ? 18 : 12}%, transparent)`);
  }
  if (o.width) root.dataset.width = o.width;
  if (o.fontSize) root.style.setProperty('--size', `${o.fontSize}px`);
  if (o.strings) {
    strings = { ...strings, ...o.strings };
    for (const h of doc.querySelectorAll('.k-heading .h-link')) {
      h.title = strings.copyLink || h.title;
      h.setAttribute('aria-label', h.title);
    }
  }
  if (o.changesOnly !== undefined) { changesOnly = !!o.changesOnly; applyChangesOnly(); }
  if (o.mode === 'quicklook') { quicklook = true; root.dataset.mode = 'quicklook'; }
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
  const frag = o && o.fragment;
  if (!frag) return;
  let id = frag;
  try { id = decodeURIComponent(frag); } catch { /* keep raw */ }
  // Scoped to the document container for the same reason: never resolve to chrome.
  const target = doc.querySelector(`[id="${CSS.escape(id)}"], [id="${CSS.escape(id.toLowerCase())}"]`)
    || doc.querySelector(`.k-heading[data-anchor="${CSS.escape(id.toLowerCase())}"]`);
  if (target) { window.scrollBy(0, target.getBoundingClientRect().top - 16); reportActiveHeading(); }
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
  remoteReady,
  remoteFailed,
  warm: () => hl.init(),
};

hl.init();
post({ type: 'ready' });
