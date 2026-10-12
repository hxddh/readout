// Mermaid diagrams, loaded on first use and rendered one at a time.
import { doc, root, strings, inViewport } from './core.js';
import { lazyObserver } from './enhance.js';

const mermaidCache = new Map();   // source+theme -> {svg, id} or {error}
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
    const theme = root.dataset.theme === 'dark' ? 'dark' : 'light';
    if (theme !== mermaidTheme) {
      // Diagrams take the page's own colors and type, in both themes.
      const css = getComputedStyle(root);
      const v = name => css.getPropertyValue(name).trim();
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
      const key = mermaidTheme + '\u0000' + src;
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
      let fresh;
      if (out.svg) {
        fresh = document.createElement('div');
        fresh.className = 'mermaid-svg';
        // The SVG's styles and markers refer to its id: every later copy on
        // the page (the same diagram twice, or from the cache) gets an id of its own.
        fresh.innerHTML = out.used ? out.svg.replace(new RegExp(`${out.id}(?![0-9])`, 'g'), `mmd-${++mermaidSeq}`) : out.svg;
        out.used = true;
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
