// Mermaid diagrams, loaded on first use and rendered one at a time.
import { doc, root, strings, inViewport, pageTheme, quicklook, firstTimings } from './core.js';
import { lazyObserver, grows } from './enhance.js';
import { shown } from './holds.js';

// Drawings by look and source, most recently used last. An agent writing a
// diagram makes a source of every few characters it adds: at most CACHE_MAX
// are kept, and one whose source no diagram in the page has any more goes
// after GRACE_MS (an undo, or a rewrite back to it, still finds it).
const mermaidCache = new Map();   // look+source -> {svg, id} or {error}
const CACHE_MAX = 64;
const GRACE_MS = globalThis.READOUT_DIAGRAM_GRACE_MS ?? 5000;   // (a test shortens it)
const unusedSince = new Map();    // key -> when no diagram in the page had its source
let sweepTimer = 0;
function cacheGet(key) {
  const out = mermaidCache.get(key);
  if (out) { mermaidCache.delete(key); mermaidCache.set(key, out); }
  return out;
}
function cacheSet(key, out) {
  mermaidCache.delete(key);
  mermaidCache.set(key, out);
  while (mermaidCache.size > CACHE_MAX) { const k = mermaidCache.keys().next().value; mermaidCache.delete(k); unusedSince.delete(k); }
  sweepLater();
}
// The sweep runs while some drawing kept has no diagram in the page, and
// stops once each has one (or none is kept): a page's diagrams changing
// (drawn, set up, gone) starts it again.
export function sweepLater() {
  if (!sweepTimer && mermaidCache.size) sweepTimer = setTimeout(sweep, GRACE_MS);
}
function sweep() {
  sweepTimer = 0;
  const inPage = new Set([...doc.querySelectorAll('.mermaid-block > .mermaid-src')].map(e => e.textContent));
  const now = performance.now();
  let unused = false;
  for (const key of [...mermaidCache.keys()]) {
    if (inPage.has(key.slice(key.indexOf('\u0000') + 1))) { unusedSince.delete(key); continue; }
    const since = unusedSince.get(key);
    if (since === undefined) { unusedSince.set(key, now); unused = true; }
    else if (now - since >= GRACE_MS) { mermaidCache.delete(key); unusedSince.delete(key); }
    else unused = true;
  }
  if (unused) sweepLater();
}
let mermaidPromise = null;
let mermaidLook = null;   // the look Mermaid is set up for: theme and type size
let mermaidSeq = 0;
let printTheme = null;   // while printing, diagrams are drawn for paper: light

/** The theme diagrams are drawn in: the page's, or light while printing. */
function diagramTheme() {
  return printTheme || pageTheme();
}

/** Diagram text: 13 px at the default 16 px reading size, following ⌘+ and
 * ⌘− (not the window: a diagram is not drawn again as the window resizes). */
function diagramFontSize() {
  return Math.round((parseFloat(root.style.getPropertyValue('--fs')) || 16) * 13 / 16 * 10) / 10 || 13;
}

/** What a drawing depends on besides its source: the theme and the type size. */
function diagramLook() {
  return `${diagramTheme()}/${diagramFontSize()}`;
}

// Mermaid's ESM build, bundled with the app (build.mjs copies it and its
// chunks): the core loads on first use, and each kind of diagram loads its
// own chunk the first time one is drawn. Resolved against the page, outside
// the bundler.
const MERMAID_URL = new URL('vendor/mermaid/mermaid.esm.min.mjs', document.baseURI).href;

// Drawing a diagram holds the page for a few hundred milliseconds in one go
// (Mermaid's layout): while the reader scrolls it would be a frame that
// stalls. A diagram is drawn once the page has not scrolled for a moment;
// coming within a screen of the viewport, it is usually drawn before it is
// seen, the reader having paused on the way.
const QUIET_SCROLL_MS = 250;
let scrolledAt = -Infinity;
window.addEventListener('scroll', () => { scrolledAt = performance.now(); }, { passive: true });
function scrollQuiet() {
  return new Promise(resolve => {
    const wait = () => { const left = scrolledAt + QUIET_SCROLL_MS - performance.now(); if (left <= 0) resolve(); else setTimeout(wait, left + 1); };
    wait();
  });
}

// Mermaid gives each drawing a style sheet of its own (rules scoped to the
// drawing's id), in the box it measures it in and in the drawing it returns.
// A style sheet taken out of the page, or one added with @keyframes, makes
// WebKit restyle the whole document: three times a diagram, seconds each in
// a 5 MB document. Its rules go instead into a sheet of the page's own,
// scoped to an attribute every drawing with the same rules shares (with the
// id's weight: :is(#…, [data-mmd=…])), added once and never taken out; the
// drawing has no sheet of its own. Mermaid's keyframes are in reader.css.
// What its rules refer to in the drawing (url(#<id>-gradient): the stroke
// of the boxes) is copied once into the page's own definitions for them.
// The ids drawings are made with. Mermaid removes any element with the id it
// draws with (and with it prefixed d or i): a capital letter keeps them out of
// the slugs headings get (always lower case), and ro- out of what the
// document's own HTML may name (HTML.sanitize renames those).
const MMD = 'ro-Mmd-';
const sheets = new Map();   // rules, scoped to "§", their references "¶" -> {name, refs}
const names = new Set();
const KEYFRAMES = /@keyframes\s+[\w-]+\s*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g;
function shareRules(css, id) {
  const own = id.replace(/[^\w-]/g, '\\$&');
  const rules = css.replace(KEYFRAMES, '')
    .replace(new RegExp(`#${own}(?![\\w-])`, 'g'), '\u00a7')
    .replace(new RegExp(`#${own}([-_][\\w-]*)`, 'g'), '\u00b6$1');
  let sheet = sheets.get(rules);
  if (!sheet) {
    // Named after its rules, not the order drawings happened to finish in: a
    // page draws the same whatever the timing.
    let h = 0x811c9dc5;
    for (let i = 0; i < rules.length; i++) h = Math.imul(h ^ rules.charCodeAt(i), 16777619);
    let name = `s${(h >>> 0).toString(36)}`;
    while (names.has(name)) name += 'x';
    names.add(name);
    sheet = { name, refs: new Set(rules.match(/\u00b6[\w-]*/g)?.map(r => r.slice(1))) };
    sheets.set(rules, sheet);
    const st = document.createElement('style');
    st.textContent = rules.split('\u00a7').join(`:is(#${MMD}${sheet.name}, [data-mmd="${sheet.name}"])`).split('\u00b6').join(`#${MMD}${sheet.name}`);
    document.head.appendChild(st);
  }
  return sheet;
}
/** The elements the sheet's rules refer to, from the first drawing that has them, into the page's definitions. */
function shareDefs(sheet, svg, id) {
  if (!sheet.refs.size) return;
  const parsed = new DOMParser().parseFromString(svg, 'text/html');
  let defs = document.getElementById('ro-mmd-defs');
  if (!defs) {
    defs = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    defs.id = 'ro-mmd-defs';
    defs.setAttribute('aria-hidden', 'true');
    defs.setAttribute('style', 'position:absolute;width:0;height:0;overflow:hidden');
    document.body.appendChild(defs);
  }
  for (const suffix of sheet.refs) {
    const el = parsed.getElementById(id + suffix);
    if (!el) continue;
    const copy = document.importNode(el, true);
    copy.id = `${MMD}${sheet.name}${suffix}`;
    defs.appendChild(copy);
    sheet.refs.delete(suffix);
  }
}
/** Mermaid's render, its style sheet shared (shareRules) rather than added to the page with the drawing. */
async function draw(m, id, src) {
  const insertBefore = Node.prototype.insertBefore, appendChild = Node.prototype.appendChild;
  let sheet = null;
  const take = (parent, node) => {
    if (node?.nodeName?.toLowerCase() !== 'style') return node;
    if (parent.id !== id && !parent.closest?.(`#${CSS.escape(id)}, #d${CSS.escape(id)}`)) return node;
    const svg = parent.closest('svg') || parent;
    sheet = shareRules(node.textContent, id);
    svg.dataset.mmd = sheet.name;
    return document.createComment('');
  };
  Node.prototype.insertBefore = function (node, ref) { return insertBefore.call(this, take(this, node), ref); };
  Node.prototype.appendChild = function (node) { return appendChild.call(this, take(this, node)); };
  try {
    // A sheet it wrote into the markup rather than adding it: shared the same way.
    const svg = (await m.render(id, src)).svg.replace(/^(<svg\b[^>]*?)(\/?>)([\s\S]*?)<style[^>]*>([\s\S]*?)<\/style>/, (all, open, end, before, css) => {
      sheet = shareRules(css, id);
      return `${open} data-mmd="${sheet.name}"${end}${before}`;
    });
    if (sheet) shareDefs(sheet, svg, id);
    return svg;
  } finally {
    Node.prototype.insertBefore = insertBefore;
    Node.prototype.appendChild = appendChild;
  }
}

function loadMermaid() {
  // When the first diagram asked for Mermaid, page time (SmokeTest: cold_page_mermaid_at_ms).
  firstTimings.mermaid_at ??= Math.round(performance.now());
  if (!mermaidPromise) {
    mermaidPromise = import(MERMAID_URL).then(mod => mod.default);
  }
  return mermaidPromise.then(m => {
    const theme = diagramTheme(), look = diagramLook(), fontSize = diagramFontSize();
    if (look !== mermaidLook) {
      // Diagrams take the page's own colors and type, in both themes. The
      // colors of a theme the page is not shown in (printing) are read with
      // the page switched to it for the moment, before anything is painted.
      // With no data-theme the page follows the system: put it back that way.
      const shown = root.getAttribute('data-theme');
      const swap = theme !== pageTheme();
      if (swap) root.setAttribute('data-theme', theme);
      const css = getComputedStyle(root);
      const vars = {};
      const v = name => vars[name] ??= css.getPropertyValue(name).trim();
      for (const name of ['--font', '--bg', '--fill', '--fill-2', '--text', '--text-2', '--text-3', '--rule']) v(name);
      if (swap) { if (shown === null) root.removeAttribute('data-theme'); else root.setAttribute('data-theme', shown); }
      m.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: 'base',
        fontFamily: v('--font') || '-apple-system, "PingFang SC", sans-serif',
        themeVariables: {
          darkMode: theme === 'dark',
          fontSize: `${fontSize}px`,
          background: v('--bg'),
          primaryColor: v('--fill'),
          primaryTextColor: v('--text'),
          primaryBorderColor: v('--text-3'),
          secondaryColor: v('--fill-2'),
          tertiaryColor: v('--bg'),
          lineColor: v('--text-2'),
          textColor: v('--text'),
          noteBkgColor: v('--fill-2'),
          noteTextColor: v('--text'),
          noteBorderColor: v('--rule'),
          clusterBkg: v('--fill'),
          clusterBorder: v('--rule'),
          edgeLabelBackground: v('--bg'),
          actorBkg: v('--fill'),
          actorBorder: v('--text-3'),
          actorTextColor: v('--text'),
          signalColor: v('--text-2'),
          signalTextColor: v('--text'),
        },
        flowchart: { htmlLabels: true, curve: 'basis' },
        sequence: { actorFontSize: fontSize, messageFontSize: fontSize, noteFontSize: fontSize, useMaxWidth: true },
      });
      mermaidLook = look;
    }
    return m;
  });
}

/** A short, readable reason: Mermaid's parser errors run to several lines of grammar tokens. */
function diagramError(err) {
  const text = String(err && err.message || err);
  const line = text.match(/line (\d+)/i);
  const first = text.split('\n').find(l => l.trim() && !/^-+\^?$/.test(l.trim())) || '';
  const reason = /Expecting|got '/.test(first) || first.length > 120 ? '' : first.replace(/^Parse error on line \d+:?\s*/i, '');
  return [line ? `line ${line[1]}` : '', reason].filter(Boolean).join(': ') || 'syntax error';
}

// A flowchart, the most common diagram, needs Mermaid, its flowchart chunk
// and the ELK layout engine (1.6 MB): once a page with one has painted, a
// tiny flowchart is drawn and thrown away in idle time, so the page's own
// draw at once when they come near (they render lazily).
const FLOWCHART = /^(?:\s*%%[^\n]*\n|\s*\n)*\s*(?:flowchart|graph)\b/;
let warmed = false;
function isFlowchart(src) {
  return FLOWCHART.test(src.replace(/^\s*---\n[\s\S]*?\n---\s*\n/, ''));
}
function prefetchFlowcharts() {
  if (warmed || quicklook) return;
  warmed = true;
  const idle = window.requestIdleCallback || (fn => setTimeout(fn, 300));
  requestAnimationFrame(() => setTimeout(() => idle(warmUp, { timeout: 3000 }), 0));
}
async function warmUp() {
  if (mermaidBusy || mermaidQueue.length) return;   // a diagram is being drawn: that loads what it needs
  mermaidBusy = true;
  try {
    const m = await loadMermaid();
    await scrollQuiet();
    await draw(m, `${MMD}warm`, 'flowchart LR\n  a --> b');
  } catch {
    // Only a head start: the page's diagrams load what they need anyway.
  } finally {
    document.querySelectorAll(`#d${MMD}warm, #${MMD}warm`).forEach(e => e.remove());
    mermaidBusy = false;
    pumpMermaid();
  }
}

// An agent writing a diagram replaces its block with every few characters
// it adds. Drawn each time, the diagram flickers between drawings and parse
// errors: a diagram whose source changes is drawn again only once it has
// been still for a moment, and its last good drawing stays until then.
const QUIET_MS = globalThis.READOUT_DIAGRAM_QUIET_MS ?? 400;   // (a test shortens it)
const drawnIn = new WeakMap();   // .blk -> [{src, node, timer}], one per diagram in it

function diagramSlot(block) {
  const blk = block.closest('.blk');
  if (!blk) return null;
  const list = drawnIn.get(blk) || [];
  drawnIn.set(blk, list);
  const i = [...blk.querySelectorAll('.mermaid-block')].indexOf(block);
  return list[i] ||= { src: null, node: null, timer: 0 };
}

/** Called for every diagram block set up (enhance.js). */
export function setupMermaid(block) {
  sweepLater();
  const src = block.querySelector('.mermaid-src')?.textContent || '';
  if (isFlowchart(src)) prefetchFlowcharts();
  const slot = diagramSlot(block);
  if (!slot || slot.src === null || slot.src === src) return;   // new, or as it was (the cache has it)
  if (mermaidLook && mermaidCache.has(mermaidLook + '\u0000' + src)) return;   // drawn before: at once
  if (slot.node) {
    block.appendChild(slot.node);
    block.classList.add('done');
    block.dataset.stale = '1';   // drawn from another source: printing draws it again
  }
  block.dataset.waiting = '1';   // not drawn until the source is still (renderLazy skips it)
  clearTimeout(slot.timer);
  slot.timer = setTimeout(() => {
    if (!block.isConnected) return;
    delete block.dataset.waiting;
    if (inViewport(block, window.innerHeight)) renderMermaid(block); else lazyObserver.observe(block);
  }, QUIET_MS);
}

const mermaidQueue = [];
let mermaidBusy = false, mermaidDraws = 0;
export function renderMermaid(block) {
  block.classList.add('busy');
  pruneQueue();
  if (!mermaidQueue.includes(block)) mermaidQueue.push(block);
  pumpMermaid();
}
// The queue waits while the reader scrolls (scrollQuiet), and an agent may
// replace a diagram meanwhile: what left the page is dropped then.
function pruneQueue() {
  for (let i = mermaidQueue.length - 1; i >= 0; i--) if (!mermaidQueue[i].isConnected) mermaidQueue.splice(i, 1);
}
/** Tests: diagrams drawn so far, and what the queue holds. */
export function diagramWork() {
  return { draws: mermaidDraws, cached: mermaidCache.size, sweeping: !!sweepTimer, queued: mermaidQueue.length, detached: mermaidQueue.filter(b => !b.isConnected).length };
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
      // After each wait: a block that left the page is not drawn, and one
      // whose source changed in place goes to the back of the queue.
      const gone = () => {
        pruneQueue();
        if (block.isConnected && block.contains(srcEl) && srcEl.textContent === src) return false;
        if (block.isConnected) mermaidQueue.push(block);
        return true;
      };
      await scrollQuiet();
      if (gone()) continue;
      const m = await loadMermaid().catch(() => null);
      if (!m) break;
      if (gone()) continue;
      const theme = mermaidLook;
      const key = theme + '\u0000' + src;
      let out = cacheGet(key);
      if (!out) {
        const id = `${MMD}${++mermaidSeq}`;
        try {
          await scrollQuiet();
          if (gone()) continue;
          mermaidDraws++;
          out = { svg: await draw(m, id, src), id };
        } catch (err) {
          out = { error: diagramError(err) };
          document.querySelectorAll(`#d${CSS.escape(id)}, #${CSS.escape(id)}`).forEach(e => e.remove());
        }
        cacheSet(key, out);
      }
      if (!block.isConnected) continue;
      // The theme or type size changed while it was being drawn: draw it again.
      if (theme !== diagramLook()) { mermaidQueue.push(block); continue; }
      place(block, out, src);
    }
  } finally {
    mermaidBusy = false;
    for (const resolve of idle.splice(0)) resolve();
  }
}
const idle = [];   // resolvers waiting for the queue to drain

/** Puts `out` (a drawing, or why there is none) in `block`, drawn from `src`. */
function place(block, out, src) {
  let fresh;
  if (out.svg) {
    fresh = document.createElement('div');
    fresh.className = 'mermaid-svg';
    // The SVG's styles and markers refer to its id: every later copy on
    // the page (the same diagram twice, or from the cache) gets an id of its own.
    fresh.innerHTML = out.svg;
    if (out.used) renameIds(fresh, out.id, `${MMD}${++mermaidSeq}`);
    out.used = true;
    // Natural size, never narrower than three quarters of it (the block scrolls).
    const svg = fresh.querySelector('svg'), w = svg && svg.viewBox.baseVal && svg.viewBox.baseVal.width; if (w) svg.style.minWidth = `${Math.round(w * 0.75)}px`;
  } else {
    fresh = document.createElement('div');
    fresh.className = 'mermaid-error';
    fresh.textContent = `${strings.diagramError}: ${out.error}`;
  }
  // Swapped in place: the old drawing (a theme change) stays until the new
  // one is ready. (One a landing showed undrawn: the reader's place kept.)
  grows(block, () => {
    const old = block.querySelectorAll('.mermaid-svg, .mermaid-error');
    if (old.length) { old[0].replaceWith(fresh); for (let i = 1; i < old.length; i++) old[i].remove(); }
    else block.appendChild(fresh);
    block.classList.toggle('done', !!out.svg);
  });
  delete block.dataset.stale;
  delete block.dataset.waiting;
  block.classList.remove('busy');
  shown(block);
  const slot = diagramSlot(block);
  if (slot) { slot.src = src; if (out.svg) slot.node = fresh; }
}

/**
 * A diagram drawn before (the cache has it, in the page's look): put in now,
 * before the frame that shows it (enhance.js: reserve). false: not drawn.
 */
export function placeCached(block) {
  const src = block.querySelector('.mermaid-src')?.textContent;
  // (The look asked only for a drawing kept: it reads the page's style.)
  if (!mermaidLook || src == null || !mermaidCache.has(mermaidLook + '\u0000' + src) || mermaidLook !== diagramLook()) return false;
  const out = cacheGet(mermaidLook + '\u0000' + src);
  const i = mermaidQueue.indexOf(block);
  if (i >= 0) mermaidQueue.splice(i, 1);
  place(block, out, src);
  return true;
}

/**
 * Gives a drawing the id `to` in place of `from`: in ids, in the attributes
 * that refer to them (href, url(#…), aria references) and in its style
 * sheet's selectors. Text the diagram shows is left as written.
 */
function renameIds(wrap, from, to) {
  const re = new RegExp(`${from}(?![0-9])`, 'g');
  for (const el of wrap.querySelectorAll('*')) {
    for (const a of el.attributes) {
      if (/^(id|href|xlink:href|aria-labelledby|aria-describedby)$/.test(a.name) || a.value.includes('url(')) {
        const v = a.value.replace(re, to);
        if (v !== a.value) a.value = v;
      }
    }
    if (el.localName === 'style') el.textContent = el.textContent.replace(re, to);
  }
}

/**
 * Re-renders every diagram after a theme or type size change (only once
 * Mermaid was ever used). The drawings stay where they are until their new ones replace
 * them, so the page keeps its height; off-screen ones are redrawn when they
 * come near. Resolves when the ones in view are drawn.
 */
export function rerenderMermaid() {
  if (!mermaidPromise) return Promise.resolve();
  let drawing = false;
  for (const b of doc.querySelectorAll('.mermaid-block')) {
    if (!b.classList.contains('done') && !b.querySelector('.mermaid-error')) continue;   // not drawn yet: renders as usual
    b.dataset.stale = '1';
    if (b.classList.contains('busy')) { drawing = true; continue; }   // queued: it is drawn in the new theme
    if (inViewport(b, window.innerHeight)) { renderMermaid(b); drawing = true; } else lazyObserver.observe(b);
  }
  // Resolves once the diagrams in view are drawn again.
  return drawing && (mermaidBusy || mermaidQueue.length) ? new Promise(resolve => idle.push(resolve)) : Promise.resolve();
}

/**
 * Printing: diagrams are drawn in the light theme for paper (the page's text
 * prints light too), and back in the page's theme afterwards. Drawings are
 * swapped in place, so the page keeps its height.
 */
export function setPrintDiagrams(on) {
  const before = diagramTheme();
  printTheme = on ? 'light' : null;
  if (diagramTheme() !== before) rerenderMermaid();
}

/** Draws every diagram not drawn (or drawn in another theme); resolves when all are done. */
export function renderAllMermaid() {
  const todo = [...doc.querySelectorAll('.mermaid-block')]
    .filter(b => !b.classList.contains('busy') && (!b.classList.contains('done') || b.dataset.stale));
  if (!todo.length && !mermaidBusy) return Promise.resolve();
  const done = new Promise(resolve => idle.push(resolve));
  for (const b of todo) renderMermaid(b);
  pumpMermaid();
  return done;
}
