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
        try {
          const { svg } = await m.render(`mmd-${++mermaidSeq}`, src);
          out = { svg };
        } catch (err) {
          out = { error: diagramError(err) };
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
