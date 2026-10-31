// Math with KaTeX, loaded on first use.
import { shown } from './holds.js';
import { firstTimings } from './core.js';

const mathCache = new Map();      // tex+display -> html, least recently used first
// Enough for every formula of a long document; an agent rewriting formulas
// all day does not grow it without end.
const MATH_CACHE_MAX = 2000;

/** Math waiting for KaTeX to load (a first paint showing it waits too: holds.js). */
export const typesetting = new Set();

let katexPromise = null;
// Its script and its style sheet (typeset without it, math is laid out at another height).
function loadKatex() {
  // When the first formula asked for KaTeX, page time (SmokeTest: cold_page_katex_at_ms).
  firstTimings.katex_at ??= Math.round(performance.now());
  if (!katexPromise) {
    const load = el => new Promise((resolve, reject) => { el.onload = resolve; el.onerror = reject; document.head.appendChild(el); });
    const css = document.createElement('link');
    css.rel = 'stylesheet';
    css.href = 'vendor/katex/katex.min.css';
    const s = document.createElement('script');
    s.src = 'vendor/katex/katex.min.js';
    katexPromise = Promise.all([load(css), load(s)]).then(() => { katexPromise.done = true; return window.katex; });
  }
  return katexPromise;
}

export function renderMath(el) {
  const nodes = el.querySelectorAll('.math:not(.done), .math-block:not(.done)');
  if (!nodes.length) return;
  // Loaded: typeset now, before the frame that shows it.
  if (katexPromise?.done) return typeset(window.katex, nodes);
  for (const n of nodes) typesetting.add(n);
  loadKatex().then(katex => typeset(katex, nodes)).catch(() => {
    for (const n of nodes) { typesetting.delete(n); shown(n); }
  });
}

function typeset(katex, nodes) {
  const t0 = performance.now();
  firstTimings.katex_loaded_at ??= Math.round(t0);
  for (const n of nodes) {
    typesetting.delete(n);
    if (!n.isConnected || n.classList.contains('done')) continue;
    const tex = n.dataset.tex;
    const display = n.classList.contains('math-block') || n.classList.contains('math-display');
    const key = (display ? 'D' : 'I') + tex;
    let html = mathCache.get(key);
    if (html === undefined) {
      try { html = katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'htmlAndMathml', strict: 'ignore' }); }
      catch { html = null; }
      if (mathCache.size >= MATH_CACHE_MAX) mathCache.delete(mathCache.keys().next().value);
    }
    else mathCache.delete(key);
    mathCache.set(key, html);
    if (html) { n.innerHTML = html; n.classList.add('done'); }
    shown(n);
  }
  // The first typesetting's own time (SmokeTest: cold_page_katex_ms).
  firstTimings.katex ??= Math.round(performance.now() - t0);
}
