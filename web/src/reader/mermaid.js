// Mermaid diagrams, loaded on first use and rendered one at a time.
import { doc, root, strings, inViewport, pageTheme } from './core.js';
import { lazyObserver } from './enhance.js';

const mermaidCache = new Map();   // source+theme -> {svg, id} or {error}
let mermaidPromise = null;
let mermaidTheme = null;
let mermaidSeq = 0;
let printTheme = null;   // while printing, diagrams are drawn for paper: light

/** The theme diagrams are drawn in: the page's, or light while printing. */
function diagramTheme() {
  return printTheme || pageTheme();
}

// Mermaid's ESM build, bundled with the app (build.mjs copies it and its
// chunks): the core loads on first use, and each kind of diagram loads its
// own chunk the first time one is drawn. Resolved against the page, outside
// the bundler.
const MERMAID_URL = new URL('vendor/mermaid/mermaid.esm.min.mjs', document.baseURI).href;

function loadMermaid() {
  if (!mermaidPromise) {
    mermaidPromise = import(MERMAID_URL).then(mod => mod.default);
  }
  return mermaidPromise.then(m => {
    const theme = diagramTheme();
    if (theme !== mermaidTheme) {
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
        fontFamily: v('--font') || '-apple-system, "SF Pro Text", "PingFang SC", sans-serif',
        themeVariables: {
          darkMode: theme === 'dark',
          fontSize: '13px',
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
        sequence: { actorFontSize: 13, messageFontSize: 13, noteFontSize: 13, useMaxWidth: true },
      });
      mermaidTheme = theme;
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

const mermaidQueue = [];
let mermaidBusy = false;
export function renderMermaid(block) {
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
      const theme = mermaidTheme;
      const key = theme + '\u0000' + src;
      let out = mermaidCache.get(key);
      if (!out) {
        const id = `mmd-${++mermaidSeq}`;
        try {
          const { svg } = await m.render(id, src);
          out = { svg, id };
        } catch (err) {
          out = { error: diagramError(err) };
          document.querySelectorAll(`#d${id}, #${id}`).forEach(e => e.remove());
        }
        mermaidCache.set(key, out);
      }
      if (!block.isConnected) continue;
      // The theme changed while it was being drawn: draw it again in the new one.
      if (theme !== diagramTheme()) { mermaidQueue.push(block); continue; }
      let fresh;
      if (out.svg) {
        fresh = document.createElement('div');
        fresh.className = 'mermaid-svg';
        // The SVG's styles and markers refer to its id: every later copy on
        // the page (the same diagram twice, or from the cache) gets an id of its own.
        fresh.innerHTML = out.svg;
        if (out.used) renameIds(fresh, out.id, `mmd-${++mermaidSeq}`);
        out.used = true;
        // Natural size, never narrower than three quarters of it (the block scrolls).
        const svg = fresh.querySelector('svg'), w = svg && svg.viewBox.baseVal && svg.viewBox.baseVal.width; if (w) svg.style.minWidth = `${Math.round(w * 0.75)}px`;
      } else {
        fresh = document.createElement('div');
        fresh.className = 'mermaid-error';
        fresh.textContent = `${strings.diagramError}: ${out.error}`;
      }
      // Swapped in place: the old drawing (a theme change) stays until the new one is ready.
      const old = block.querySelectorAll('.mermaid-svg, .mermaid-error');
      if (old.length) { old[0].replaceWith(fresh); for (let i = 1; i < old.length; i++) old[i].remove(); }
      else block.appendChild(fresh);
      block.classList.toggle('done', !!out.svg);
      delete block.dataset.stale;
      block.classList.remove('busy');
    }
  } finally {
    mermaidBusy = false;
    for (const resolve of idle.splice(0)) resolve();
  }
}
const idle = [];   // resolvers waiting for the queue to drain

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
 * Re-renders every diagram after a theme change (only once Mermaid was ever
 * used). The drawings stay where they are until their new ones replace
 * them, so the page keeps its height; off-screen ones are redrawn when they
 * come near.
 */
export function rerenderMermaid() {
  if (!mermaidPromise) return;
  for (const b of doc.querySelectorAll('.mermaid-block')) {
    if (!b.classList.contains('done') && !b.querySelector('.mermaid-error')) continue;   // not drawn yet: renders as usual
    b.dataset.stale = '1';
    if (b.classList.contains('busy')) continue;   // queued: it is drawn in the new theme
    if (inViewport(b, window.innerHeight)) renderMermaid(b); else lazyObserver.observe(b);
  }
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
