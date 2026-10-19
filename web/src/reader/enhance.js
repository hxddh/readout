// Per-block enhancement after a block's HTML is set: code tools and
// highlighting, table overflow, remote-image placeholders, heading links,
// math. Expensive work (highlighting, diagrams) runs lazily near the viewport.
import * as hl from '../highlight.js';
import { doc, root, strings, post, inViewport } from './core.js';
import { captureAnchor, restoreAnchor } from './anchor.js';
import { setupRemoteImage } from './remote.js';
import { renderMath } from './math.js';
import { renderMermaid, setupMermaid } from './mermaid.js';

export function enhance(el) {
  hl.stopWarmUp();   // a document is shown: its own blocks load what they need
  for (const cb of el.querySelectorAll('.code-block')) setupCode(cb);
  for (const t of el.querySelectorAll('.table-wrap')) { setupTable(t); queueTable(t); }
  for (const r of el.querySelectorAll('.remote-img')) setupRemoteImage(r);
  for (const m of el.querySelectorAll('.mermaid-block')) { setupMermaid(m); diagrams.add(m); }
  for (const h of el.classList.contains('k-heading') ? [el] : []) setupHeadingLink(h);
  if (el.querySelector('.math, .math-block')) renderMath(el);
  setLang(el);
  markCjkEmphasis(el);
  markCodeBeforePunct(el);
}

// Inline code right before full-width punctuation (`results/` 。): the
// punctuation's glyph already brings its own space, which the code's padding
// doubled into a gap. Such code keeps only a sliver of padding on that side
// (reader.css: code.before-punct).
const FULLWIDTH_PUNCT = /^[、。，．：；！？）］｝」』】〕〗〙〛》〉]/;
const INLINE = 'a, strong, b, em, i, del, s, mark, u, span';
function markCodeBeforePunct(el) {
  for (const code of el.querySelectorAll('code')) {
    if (code.closest('pre')) continue;
    let node = code;
    while (!node.nextSibling && node.parentElement !== el && node.parentElement?.matches(INLINE)) node = node.parentElement;
    const next = node.nextSibling;
    code.classList.toggle('before-punct', !!next && next.nodeType === Node.TEXT_NODE && FULLWIDTH_PUNCT.test(next.data));
  }
}

// Han characters take Japanese forms in a block with kana, Chinese otherwise
// (the page itself is lang="en", which leaves the choice to the font).
const KANA = /[\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9f]/;
const HAN = /[\u3400-\u9fff\uf900-\ufaff]/;
function setLang(el) {
  const text = el.textContent;
  const lang = KANA.test(text) ? 'ja' : HAN.test(text) ? 'zh' : null;
  if (lang) el.lang = lang; else el.removeAttribute('lang');
}

// Emphasis that is mostly CJK (at least as many CJK characters as Latin
// letters) is upright and takes emphasis dots instead of a slant (reader.css:
// em.cjk-em). The dots are drawn by CSS, one per Han, kana or Hangul
// character, each in a span of its own (.em-dot): never on punctuation
// (clreq, jlreq), outside the line box (text-emphasis made the line taller),
// and never part of copied text. A long run (more than 20 such characters,
// or a whole paragraph) takes a slightly heavier weight instead: a line of
// dots under a whole sentence is noise, not emphasis (.cjk-em-long).
const CJK_CHARS = /[぀-ヿㇰ-ㇿｦ-ﾟ㐀-鿿豈-﫿가-힯]/g;
const LATIN_LETTERS = /[A-Za-zÀ-ɏ]/g;
const DOTTED = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]/u;
const DOTTED_ALL = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]/gu;
const LONG_EMPHASIS = 20;
function markCjkEmphasis(el) {
  for (const em of el.querySelectorAll('em')) {
    if (em.classList.contains('cjk-em') || em.classList.contains('cjk-em-long')) continue;
    const text = em.textContent;
    const cjk = (text.match(CJK_CHARS) || []).length;
    if (!cjk || cjk < (text.match(LATIN_LETTERS) || []).length) continue;
    const dotted = (text.match(DOTTED_ALL) || []).length;
    const para = em.parentElement.closest('p, li, td, th, h1, h2, h3, h4, h5, h6');
    const whole = para && para.textContent.trim() === text.trim();
    if (dotted > LONG_EMPHASIS || whole) { em.classList.add('cjk-em-long'); continue; }
    em.classList.add('cjk-em');
    const walker = document.createTreeWalker(em, NodeFilter.SHOW_TEXT);
    const nodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (DOTTED.test(n.data) && !n.parentElement.closest('code, kbd, samp, .katex, .math')) nodes.push(n);
    }
    for (const n of nodes) {
      const frag = document.createDocumentFragment();
      let plain = '';
      for (const ch of n.data) {
        if (!DOTTED.test(ch)) { plain += ch; continue; }
        if (plain) { frag.append(plain); plain = ''; }
        const dot = document.createElement('span');
        dot.className = 'em-dot';
        dot.textContent = ch;
        frag.append(dot);
      }
      if (plain) frag.append(plain);
      n.replaceWith(frag);
    }
  }
}

// Table cells. A short cell (16 columns or fewer, a CJK character counting
// two) and a short identifier in code (32 characters or fewer) stay on one
// line while the column has room: "S1 / GREEN" or `actions/configure-pages`
// broken in two read badly. A longer identifier may break after a slash.
// Only while the table fits that way: one they would push past the column
// wraps them again, and scrolls only if it is still too wide (measureTables).
const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦\u{1f000}-\u{1faff}\u{20000}-\u{3fffd}]/u;
function columns(s) {
  let n = 0;
  for (const ch of s) n += WIDE.test(ch) ? 2 : 1;
  return n;
}

function setupTable(t) {
  for (const c of t.querySelectorAll('td code, th code')) {
    const s = c.textContent;
    if (s.length <= 32) c.dataset.nw = '';
    else if (s.includes('/')) breakAfterSlashes(c);
  }
  for (const cell of t.querySelectorAll('td, th')) {
    const n = columns(cell.textContent.trim());
    if (n && n <= 16 && !cell.querySelector('br')) cell.dataset.nw = '';
  }
}

function breakAfterSlashes(el) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  const nodes = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.data.includes('/')) nodes.push(n);
  for (const n of nodes) {
    const frag = document.createDocumentFragment();
    n.data.split('/').forEach((part, i, all) => {
      if (part) frag.append(part);
      if (i < all.length - 1) frag.append('/', document.createElement('wbr'));
    });
    n.replaceWith(frag);
  }
}

/**
 * A table wider than the column scrolls sideways (and pins its first column);
 * one of its own block widens into the margin first when the window has room
 * (reader.css). A scrolling table takes its natural width, so it is measured
 * without the class: otherwise one that scrolled once would never fit again.
 * Short cells stay on one line only while the table fits that way, widened
 * or not: otherwise they wrap again (.nw-off), and the table scrolls only if
 * it is still too wide. Writes and reads alternate per step, never per table:
 * the page lays out twice, and twice more when a table had to wrap again.
 */
export function measureTables(tables = doc.querySelectorAll('.table-wrap')) {
  const list = [...tables].filter(t => t.isConnected);
  for (const t of list) t.classList.remove('scrolls', 'nw-off');
  const wide = list.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of wide) t.classList.add('scrolls');
  // How far a table of its own block widens: its width, read once it takes it.
  const own = wide.filter(t => t.parentElement.matches('#ro-doc > .blk.k-table'));
  const widths = own.map(t => t.firstElementChild.getBoundingClientRect().width);
  own.forEach((t, i) => t.parentElement.style.setProperty('--tb-w', `${Math.ceil(widths[i])}px`));
  const retry = wide.filter(t => t.scrollWidth > t.clientWidth + 1 && t.querySelector('[data-nw], th'));
  if (!retry.length) return;
  for (const t of retry) t.classList.replace('scrolls', 'nw-off');
  const still = retry.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of still) t.classList.replace('nw-off', 'scrolls');
}

// New tables are measured together, in the next frame.
const queuedTables = new Set();
function queueTable(t) {
  if (!queuedTables.size) requestAnimationFrame(() => { const list = [...queuedTables]; queuedTables.clear(); measureTables(list); });
  queuedTables.add(t);
}

// The window width decides which tables scroll.
let tablesQueued = false;
window.addEventListener('resize', () => {
  if (tablesQueued) return;
  tablesQueued = true;
  requestAnimationFrame(() => { tablesQueued = false; measureTables(); });
});

/** Hover link button on headings: copies a `#anchor` link for the section. */
function setupHeadingLink(h) {
  if (h.querySelector('.h-link')) return;
  const anchor = h.dataset.anchor;
  if (!anchor) return;
  const btn = document.createElement('button');
  btn.className = 'h-link';
  btn.type = 'button';
  btn.dataset.label = '§';
  btn.title = strings.copyLink || 'Copy Link to Section';
  btn.setAttribute('aria-label', btn.title);
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    post({ type: 'copyLink', anchor });
    btn.dataset.label = '✓';
    setTimeout(() => { btn.dataset.label = '§'; }, 1200);
  });
  // Beside the heading, not inside it: the heading is named by its own
  // content as the browser computes it (math by its MathML, the button's
  // label not part of it), and an out-of-flow child does not stop WebKit
  // balancing its lines. CSS puts it in the gutter on the first line. After
  // the heading, so the heading stays the block's first element.
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
    setLabel(w, strings.wrap || w.dataset.label);
    w.title = strings.wrapTitle || w.title;
  }
  for (const c of doc.querySelectorAll('.cb-copy')) setLabel(c, strings.copy || c.dataset.label);
}

/**
 * Control labels are CSS generated content (see reader.css), so a selection
 * across a code block or heading never copies "Copy", "Wrap", "§" or the language.
 */
function setLabel(el, text) {
  el.dataset.label = text;
  if (el.tagName === 'BUTTON') el.setAttribute('aria-label', text);
}

function setupCode(cb) {
  if (cb.querySelector('.cb-tools')) return;
  const tools = document.createElement('div');
  tools.className = 'cb-tools';
  if (cb.dataset.lang) {
    const lang = document.createElement('span');
    lang.className = 'cb-lang';
    lang.dataset.label = cb.dataset.lang;
    lang.setAttribute('aria-hidden', 'true');
    tools.appendChild(lang);
  }
  const wrap = document.createElement('button');
  wrap.className = 'cb-wrap';
  wrap.type = 'button';
  setLabel(wrap, strings.wrap || 'Wrap');
  wrap.title = strings.wrapTitle || 'Wrap long lines in code blocks';
  wrap.addEventListener('click', ev => {
    ev.stopPropagation();
    toggleCodeWrap();
  });
  tools.appendChild(wrap);
  const btn = document.createElement('button');
  btn.className = 'cb-copy';
  btn.type = 'button';
  setLabel(btn, strings.copy || 'Copy');
  btn.addEventListener('click', ev => {
    ev.stopPropagation();
    const code = cb.querySelector('pre').innerText.replace(/\n$/, '');
    post({ type: 'copy', text: code });
    setLabel(btn, strings.copied || 'Copied');
    setTimeout(() => setLabel(btn, strings.copy || 'Copy'), 1400);
  });
  tools.appendChild(btn);
  cb.appendChild(tools);
  const text = cb.querySelector('pre').textContent;
  // Box-drawing characters (a directory tree, a diagram): tighter lines, so
  // the vertical strokes join up.
  if (/[\u2500-\u257f]/.test(text)) cb.classList.add('cb-tree');
  // Prose in a fence (a prompt, a SKILL.md, notes) wraps at the column like
  // the text around it: a 400-column sentence read by scrolling sideways is
  // not code. Never a drawing, a listing, a log or a transcript.
  const prose = isProseFence(cb.dataset.lang, text) && !cb.classList.contains('cb-tree');
  cb.classList.toggle('cb-prose', prose);
  // Its longest line, in columns: reader.css widens a code block of its own
  // whose lines run past the column into the margins, when the window has room.
  if (cb.parentElement.classList.contains('k-code')) cb.parentElement.style.setProperty('--cb-cols', prose ? 0 : codeColumns(text));
  cb.dataset.hl = 'pending';
  fresh.push(cb);
}

const PROSE_LANGS = new Set(['', 'text', 'txt', 'plain', 'plaintext', 'markdown', 'md', 'prompt']);
const MARKDOWN_LANGS = new Set(['markdown', 'md']);
// A shell prompt at a line start: a transcript, not prose. In Markdown,
// `# ` is a heading and `> ` a quote.
const PROMPT = /^\s*(\$ |PS>|❯)/;
const PROMPT_PLAIN = /^\s*(\$ |PS>|❯|> |# )/;
const LIST_ITEM = /^\s*([-*+]|\d+[.)])\s/;
// A word: letters (any script, CJK included) with at most sentence
// punctuation around or inside them, e.g. "don't", "(see", "e.g.,",
// "条件写入，与". Not an identifier, a path, a string or an expression
// (web_search, a/b, "x", {, ==).
const WORD = /^[\p{L}\p{M}\p{N}'’\-–—.,;:!?，、。；：！？「」『』（）《》“”…·]+$/u;
function wordy(token) {
  const core = token.replace(/^[(\[“‘"'*_]+|[)\]”’"'*_.,;:!?]+$/gu, '');
  if (!core || !WORD.test(core)) return false;
  const letters = core.match(/\p{L}|\p{M}/gu)?.length || 0;
  return letters / [...core].length >= 0.7;
}
/**
 * A fence that holds prose (a prompt, a SKILL.md, notes): only on a positive
 * signal, so code, logs and transcripts keep their lines.
 * - no language, or text, txt, plain, plaintext, markdown, md or prompt;
 * - a line longer than the column (80 columns) made of ordinary words;
 * - and nothing that lines text up or marks it as code or output: no tab, no
 *   run of 3+ spaces inside a line, no line starting with a shell prompt, and
 *   no line indented by 2+ spaces unless it continues a Markdown list item
 *   (a stack frame, a nested block, a listing are indented).
 * Box drawing is ruled out by the caller (.cb-tree).
 */
function isProseFence(lang = '', text) {
  lang = lang.toLowerCase();
  if (!PROSE_LANGS.has(lang) || text.includes('\t')) return false;
  const prompt = MARKDOWN_LANGS.has(lang) ? PROMPT : PROMPT_PLAIN;
  let inList = false, long = false;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    if (prompt.test(line) || /\S {3,}\S/.test(line)) return false;
    const indented = /^ {2,}/.test(line);
    if (LIST_ITEM.test(line)) inList = true;
    else if (indented && !inList) return false;
    else if (!indented) inList = false;
    if (!long && codeColumns(line) > 80) {
      const tokens = line.trim().split(/\s+/);
      long = tokens.filter(wordy).length / tokens.length >= 0.75;
    }
  }
  return long;
}

// The width of the longest line in monospace columns: a tab to the next
// stop of 4, a CJK character about 5/3 (it is 1em wide, a column 0.6em).
function codeColumns(text) {
  let max = 0;
  for (const line of text.split('\n')) {
    let n = 0;
    if (/^[\x20-\x7e]*$/.test(line)) n = line.length;
    else for (const ch of line) n = ch === '\t' ? (Math.floor(n / 4) + 1) * 4 : n + (WIDE.test(ch) ? 5 / 3 : 1);
    if (n > max) max = n;
  }
  return Math.ceil(max);
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

/** Highlights now the code not highlighted yet in `blocks` (on screen after a jump, before it is painted). */
export function highlightIn(blocks) {
  for (const b of blocks) for (const cb of b.querySelectorAll('.code-block[data-hl="pending"]')) highlightBlock(cb);
}

/** Highlights every code block not highlighted yet, wherever it is (printing). */
export function highlightAll() {
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) highlightBlock(cb);
}

/** `near`: whether a code block counts as on screen (a first open estimates it without layout). */
export function renderLazy(near = inViewport) {
  const blocks = fresh;
  fresh = [];
  // Blocks on screen now are highlighted before the next paint (no flash of
  // plain code); the rest wait until they come near.
  const onScreen = [];
  for (const cb of blocks) {
    if (!cb.isConnected || cb.dataset.hl !== 'pending') continue;
    if (near(cb)) onScreen.push(cb); else lazyObserver.observe(cb);
  }
  for (const cb of onScreen) highlightBlock(cb);
  // The page's diagrams, without a search of the whole page in every patch.
  for (const m of diagrams) {
    if (!m.isConnected) { diagrams.delete(m); continue; }
    if (!m.classList.contains('done') && !m.classList.contains('busy') && !m.dataset.waiting) lazyObserver.observe(m);
  }
}
const diagrams = new Set();   // every diagram block set up (enhance), until it leaves the page
