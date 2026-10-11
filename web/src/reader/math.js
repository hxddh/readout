// Math with KaTeX, loaded on first use.
const mathCache = new Map();      // tex+display -> html

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

export function renderMath(el) {
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
