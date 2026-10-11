// Mermaid diagrams, loaded on first use and rendered one at a time.
import { doc, root, strings, inViewport } from './core.js';
import { lazyObserver } from './enhance.js';

const mermaidCache = new Map();   // source+theme -> svg
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

/** Re-renders every diagram after a theme change (only once Mermaid was ever used). */
export function rerenderMermaid() {
  if (!mermaidPromise) return;
  for (const b of doc.querySelectorAll('.mermaid-block')) {
    b.classList.remove('done', 'busy');
    b.querySelectorAll('.mermaid-svg, .mermaid-error').forEach(e => e.remove());
    if (inViewport(b, window.innerHeight)) renderMermaid(b); else lazyObserver.observe(b);
  }
}
