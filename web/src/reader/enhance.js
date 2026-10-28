// Per-block enhancement after a block's HTML is set: code tools and
// highlighting, table overflow, remote-image placeholders, heading links,
// math. Expensive work (highlighting, in a worker; diagrams) runs lazily near
// the viewport.
import * as hl from '../highlight.js';
import { doc, root, strings, post, inViewport, prevItem, nextItem } from './core.js';
import { captureAnchor, restoreAnchor } from './anchor.js';
import { setupRemoteImage } from './remote.js';
import { renderMath } from './math.js';
import { renderMermaid, setupMermaid, sweepLater } from './mermaid.js';

export function enhance(el) {
  hl.stopWarmUp();   // a document is shown: its own blocks load what they need
  const old = leftIn.get(el);
  leftIn.delete(el);
  [...el.querySelectorAll('.code-block')].forEach((cb, i) => setupCode(cb, old?.[i]));
  for (const t of el.querySelectorAll('.table-wrap')) { setupTable(t); queueTable(t); }
  for (const r of el.querySelectorAll('.remote-img')) setupRemoteImage(r);
  for (const m of el.querySelectorAll('.mermaid-block')) { setupMermaid(m); diagrams.add(m); }
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
  // A table in a chunk content-visibility skips is measured when it comes
  // on screen (skippedTables): asked now, WebKit would lay the chunk out to
  // answer, every such chunk once.
  const list = [];
  for (const t of tables) {
    if (!t.isConnected) continue;
    if (t.checkVisibility({ contentVisibilityAuto: true })) list.push(t); else skippedTables.observe(t);
  }
  for (const t of list) t.classList.remove('scrolls', 'nw-off');
  const wide = list.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of wide) t.classList.add('scrolls');
  // How far a table of its own block widens: its width, read once it takes it.
  const own = wide.filter(t => t.parentElement.matches('#ro-doc > .chunk > .blk.k-table'));
  const widths = own.map(t => t.firstElementChild.getBoundingClientRect().width);
  // (Set only when it changed: a style change on a block makes WebKit lay out
  // a large document's skipped blocks again.)
  own.forEach((t, i) => {
    const w = `${Math.ceil(widths[i])}px`;
    if (t.parentElement.style.getPropertyValue('--tb-w') !== w) t.parentElement.style.setProperty('--tb-w', w);
  });
  const retry = wide.filter(t => t.scrollWidth > t.clientWidth + 1 && t.querySelector('[data-nw], th'));
  if (!retry.length) return;
  for (const t of retry) t.classList.replace('scrolls', 'nw-off');
  const still = retry.filter(t => t.scrollWidth > t.clientWidth + 1);
  for (const t of still) t.classList.replace('nw-off', 'scrolls');
}

/**
 * Tables in chunks not laid out, measured as they come within two screens
 * (as their chunk is laid out ahead), so one is not drawn unmeasured and
 * then reflowed on screen; their chunk laid out by then (not all at once, laid out for the moment: 1 MB,
 * 66 tables, ~1 s).
 */
const skippedTables = new IntersectionObserver(entries => {
  const shown = [];
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    skippedTables.unobserve(e.target);
    // Its chunk still skipped (WebKit places its content at its top until
    // a frame lays it out): asked again in the next frame.
    if (e.target.checkVisibility({ contentVisibilityAuto: true })) shown.push(e.target);
    else requestAnimationFrame(() => { if (e.target.isConnected) skippedTables.observe(e.target); });
  }
  if (shown.length) measureTables(shown);
}, { rootMargin: '200% 0px' });   // the lookahead's (chunks.js): measured before it is on screen

/** Tables of `el` (a block leaving the page or getting new content) no longer watched. */
/**
 * `el` (a block) is replaced, removed or reset away: nothing of its keeps
 * watching or waiting (its tables, its code and diagrams for lazy work),
 * so an agent rewriting a block keeps no old copy of it alive.
 */
export function forgetBlock(el) {
  keepColours(el);
  for (const t of el.querySelectorAll('.table-wrap')) skippedTables.unobserve(t);
  for (const x of el.querySelectorAll('.code-block, .mermaid-block')) {
    lazyObserver.unobserve(x);
    codeObserver.unobserve(x);
    waitingForChunk.delete(x);
    if (diagrams.delete(x)) sweepLater();   // a diagram gone: its drawing kept a while, then dropped
    const a = asked.get(x);
    if (a) { hl.cancel(a.id); unasked(x); }
    shown(x);
    const i = queue.indexOf(x);
    if (i >= 0) queue.splice(i, 1);
  }
}

/** What lazy work holds on to (a test checks it stays bounded). */
export function lazyHeld() {
  const held = [...waitingForChunk.keys(), ...queue, ...diagrams, ...asked.keys()];
  return { waiting: waitingForChunk.size, queued: queue.length + asked.size, diagrams: diagrams.size, detached: held.filter(x => !x.isConnected).length };
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

/** Re-labels the code blocks' buttons after the strings change. */
export function relabelButtons() {
  for (const w of doc.querySelectorAll('.cb-wrap')) {
    setLabel(w, strings.wrap || w.dataset.label);
    w.title = strings.wrapTitle || w.title;
  }
  for (const c of doc.querySelectorAll('.cb-copy')) setLabel(c, strings.copy || c.dataset.label);
}

/**
 * Control labels are CSS generated content (see reader.css), so a selection
 * across a code block never copies "Copy", "Wrap" or the language.
 */
function setLabel(el, text) {
  el.dataset.label = text;
  if (el.tagName === 'BUTTON') el.setAttribute('aria-label', text);
}

function setupCode(cb, old) {
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
  codeOf.set(cb, text);
  // The same code a block this patch took away showed coloured: its <pre> moved over.
  const key = `${cb.dataset.lang}\0${text}`, same = leaving.get(key);
  if (same) { leaving.delete(key); cb.querySelector('pre').replaceWith(same); cb.dataset.hl = 'done'; return; }
  cb.dataset.hl = 'pending';
  fresh.push(cb);
  if (old) keepLines(cb, text, old);
}

// Code a patch takes away coloured (a block replaced, or the document reset)
// is kept for the code that takes its place, until the patch is applied
// (renderLazy): the same code in a block of the new document is that code
// coloured; a block an agent edits keeps its first lines, those it did not
// change, coloured (what a line shows depends only on the lines before it),
// the rest plain until the block's HTML arrives.
const codeOf = new WeakMap();   // code block -> its code
const leaving = new Map();      // lang \0 code -> the <pre> of a block taken away, all of it coloured
const leftIn = new Map();       // block element filled again -> its code blocks before: {lang, code or lines, pre, done} or null
function keepColours(el) {
  const old = [...el.querySelectorAll('.code-block')].map(x => {
    const pre = x.querySelector('pre'), v = inPart.get(x), code = codeOf.get(x);
    if (x.dataset.hl === 'done' && code != null) {
      const key = `${x.dataset.lang}\0${code}`;
      leaving.set(key, pre);
      return { lang: x.dataset.lang, code, pre, done: Infinity, key };
    }
    return v && !v.kept ? { lang: x.dataset.lang, lines: v.lines, pre, done: v.done } : null;
  });
  if (old.some(Boolean)) leftIn.set(el, old);
}
function keepLines(cb, text, o) {
  // (Not a <pre> the same code elsewhere took: leaving no longer has it.)
  if (!o || o.lang !== cb.dataset.lang || (o.key && leaving.get(o.key) !== o.pre)) return;
  const lines = text.split('\n'), was = o.lines ?? o.code.split('\n');
  let k = 0;
  while (k < lines.length && k < was.length && k < o.done && lines[k] === was[k]) k++;
  const spans = o.pre.firstElementChild?.querySelectorAll(':scope > .line');
  if (!k || !spans || spans.length < k) return;
  if (o.key) leaving.delete(o.key);
  // The lines after the first k out, the new ones plain after them.
  for (let n = spans[k - 1].nextSibling; n;) { const next = n.nextSibling; n.remove(); n = next; }
  const rest = document.createTextNode(k < lines.length ? '\n' + lines.slice(k).join('\n') : '');
  o.pre.firstElementChild.append(rest);
  cb.querySelector('pre').replaceWith(o.pre);
  // All of its lines kept: it is that code coloured, nothing to ask for.
  if (k === lines.length) { rest.remove(); cb.dataset.hl = 'done'; fresh.pop(); return; }
  inPart.set(cb, { rest, lines, done: k, kept: true });
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

// Highlighting runs in a worker (highlight.js), never on this thread: a
// block asks for its HTML once it comes within the lookahead (two screens,
// as far as chunks are laid out ahead: chunks.js), the more urgent the
// nearer it is (on screen, within a screen, further), raised as the reader
// comes nearer; the HTML replaces its plain <pre> when it arrives. Asked
// that far ahead, a block scrolled to has arrived before it shows; the
// frames that would show code on screen before it has (a document's first
// paint, a jump) wait for it instead, for a moment at most (hold).
const SCREEN = 0, NEAR = 1, FAR = 2;
const asked = new Map();   // code block -> {id, prio, upto}: asked, not arrived
function prioOf(r) {
  if (r.bottom > 0 && r.top < innerHeight) return SCREEN;
  return r.bottom > -innerHeight && r.top < 2 * innerHeight ? NEAR : FAR;
}

/**
 * `dy`: a jump about to scroll by that much (holdJump): on screen where it
 * lands. `upto`: the lines it shows (on screen: as far as the screen shows).
 */
function ask(cb, prio, dy = 0, upto = prio === SCREEN ? linesShown(cb, dy) : 0) {
  if (cb.dataset.hl !== 'pending') return;
  const lang = hl.resolveLang(cb.dataset.lang);
  if (!lang) { cb.dataset.hl = 'none'; return; }
  const a = asked.get(cb);
  // (Asked as urgently already: unless now for more of its lines.)
  if (a && (prio > a.prio || (prio === a.prio && upto <= a.upto))) return;
  // On screen: the lines it shows (and 120 px more) are sent ahead of the rest.
  if (a) { a.prio = prio; a.upto = upto; hl.prioritise(a.id, prio, upto); } else {
    const code = codeOf.get(cb);
    // The parts after the first put in as they come (not a long block's, nor one showing lines kept from before).
    const stream = !inPart.has(cb) && code.split('\n', PARTS_MAX + 1).length <= PARTS_MAX;
    asked.set(cb, { prio, upto, id: hl.request(code, lang, prio, upto, stream, {
      done: html => arrived(cb, lang, html),
      part: (html, lines, first) => part(cb, lang, html, code, lines, first),
      // Its grammar not loaded yet: nothing waits for it (it shows plain, coloured once it is).
      loading: () => { slow.add(cb); shown(cb); },
    }) });
  }
  // Nearer as the reader comes nearer (asked for sooner).
  if (prio > SCREEN) screenObserver.observe(cb);
  if (prio > NEAR) nearObserver.observe(cb);
}
const nearer = prio => new IntersectionObserver(es => { for (const e of es) if (e.isIntersecting) ask(e.target, prio); }, { rootMargin: prio === SCREEN ? '0px' : '100% 0px 100% 0px' });
const screenObserver = nearer(SCREEN), nearObserver = nearer(NEAR);
function unasked(cb) {
  asked.delete(cb);
  slow.delete(cb);
  screenObserver.unobserve(cb);
  nearObserver.unobserve(cb);
}

function linesShown(cb, dy) {
  const pre = cb.querySelector('pre');
  const lh = parseFloat(getComputedStyle(pre.firstElementChild || pre).lineHeight) || 20;
  return Math.max(1, Math.ceil((innerHeight + 120 - pre.getBoundingClientRect().top + dy) / lh));
}

function toPre(html, lang) {
  const tpl = document.createElement('template');
  tpl.innerHTML = html;
  const pre = tpl.content.firstElementChild;
  markDiff(pre, lang);
  return pre;
}

function arrived(cb, lang, html) {
  unasked(cb);
  codeObserver.unobserve(cb);
  if (!cb.isConnected) return;
  if (html === '') {
    // All of it came in parts: in place already.
    const v = inPart.get(cb);
    if (v?.rest && !v.rest.length) v.rest.remove();
    cb.dataset.hl = 'done';
  } else if (html) {
    cb.querySelector('pre').replaceWith(toPre(html, lang));
    cb.dataset.hl = 'done';
  } else cb.dataset.hl = 'none';
  inPart.delete(cb);
  shown(cb);
}

// A long block's lines on screen, ahead of the rest (still plain, after
// them), then each part as it comes, in place of its lines' plain text; a
// block of more than PARTS_MAX lines takes only the first: each is the
// whole block laid out again (a block of 28,000 lines: a second).
const PARTS_MAX = 1000;
const inPart = new WeakMap();   // block -> {rest: its plain text node, lines: its lines, done: how many coloured, kept: from before (keepLines)}
function part(cb, lang, html, code, done, first) {
  if (!cb.isConnected || cb.dataset.hl !== 'pending') return;
  let v = inPart.get(cb);
  if (first) {
    if (v?.kept && done <= v.done) return;   // its kept lines show as much
    const pre = toPre(html, lang);
    const lines = code.split('\n');
    v = { rest: document.createTextNode('\n' + lines.slice(done).join('\n')), lines, done };
    pre.firstElementChild.append(v.rest);
    cb.querySelector('pre').replaceWith(pre);
    inPart.set(cb, v);
    shown(cb, false);
    return;
  }
  if (!v || v.kept || v.lines.length > PARTS_MAX) return;
  const tpl = document.createElement('template');
  tpl.innerHTML = `<pre><code>\n${html}</code></pre>`;
  const lines = tpl.content.firstElementChild.firstElementChild;
  markDiff(lines, lang);
  let len = 0;
  for (let i = v.done; i < done; i++) len += v.lines[i].length + 1;
  v.rest.deleteData(0, len);
  v.rest.before(...lines.childNodes);
  v.done = done;
}

/** `cb` shows coloured (`all` of it, or what the screen shows of it): what waited for it goes on. */
function shown(cb, all = true) {
  for (const h of [...holds]) if ((all || !h.whole) && h.cbs.delete(cb) && !h.cbs.size) release(h);
}

function markDiff(root, id) {
  if (id !== 'diff') return;
  for (const line of root.querySelectorAll('.line')) {
    const t = line.textContent;
    if (t.startsWith('+') && !t.startsWith('+++')) line.classList.add('add');
    else if (t.startsWith('-') && !t.startsWith('---')) line.classList.add('del');
  }
}

// Holds: what waits for code on screen to be coloured (`then`), for HOLD_MS
// at most: what highlighting it on this thread took the frame before (the
// lines on screen of a long block: they come first). A document's first
// paint waits with the document hidden (a reset: none of the old document is
// left; code it shows again is coloured at once, keepColours, and waits for
// nothing); a jump waits before it scrolls; find, before it selects a match
// in code (highlighting replaces the text). An edit shows the code it keeps
// coloured at once, the rest plain until it arrives.
const holds = new Set();
const HOLD_MS = 1000;
/** The hold, or null: nothing to wait for (`then` is not called then). `whole`: until all of each block is coloured. */
function hold(cbs, then, dy = 0, upto, whole = false) {
  const h = { cbs: new Set(), then, whole };
  for (const cb of cbs) { ask(cb, SCREEN, dy, upto); if (whole ? cb.dataset.hl === 'pending' && !slow.has(cb) : waits(cb)) h.cbs.add(cb); }
  if (!h.cbs.size) return null;
  h.timer = setTimeout(() => release(h), HOLD_MS);
  holds.add(h);
  return h;
}
function release(h) {
  if (!holds.delete(h)) return;
  clearTimeout(h.timer);
  h.then();
}
// Code not coloured on screen yet (neither all of it, nor its lines on screen).
const waits = cb => cb.dataset.hl === 'pending' && !slow.has(cb) && !(inPart.has(cb) && !inPart.get(cb).kept);
const slow = new WeakSet();   // blocks whose grammar was not loaded when asked for
const pending = blocks => blocks.flatMap(b => [...b.querySelectorAll('.code-block[data-hl="pending"]')].filter(waits));

/** `then` once the code in `blocks` is coloured, all of it (find: before it selects a match there). Returns a cancel. */
export function whenColoured(blocks, then) {
  const h = hold(blocks.flatMap(b => [...b.querySelectorAll('.code-block[data-hl="pending"]')]), then, 0, undefined, true);
  if (!h) then();
  return () => { if (h) { holds.delete(h); clearTimeout(h.timer); } };
}

let firstPaint = null;   // the hold of a document's first paint, the document hidden meanwhile
/** After the frame that shows the document: rAF runs before the paint, the task it queues runs after. */
export function afterShown(f) {
  const next = () => requestAnimationFrame(() => setTimeout(f, 0));
  if (firstPaint) { const then = firstPaint.then; firstPaint.then = () => { then(); next(); }; } else next();
}

/**
 * A jump about to scroll by `off()` (aimAt): whether it waits for the code
 * it would show, `again` called then. While a first paint waits, the
 * document is hidden: that code joins it, and the jump goes now.
 */
export function holdJump(el, off, again) {
  cancelJump();
  const blk = el.closest('#ro-doc > .chunk > .blk');
  if (!blk) return false;
  const d = off();
  const shows = e => { const r = e.getBoundingClientRect(); return r.bottom - d > 0 && r.top - d < innerHeight; };
  const blocks = [blk];
  for (let e = prevItem(blk); e; e = prevItem(e)) { if (!e.classList.contains('blk')) continue; if (!shows(e)) break; blocks.unshift(e); }
  for (let e = nextItem(blk); e; e = nextItem(e)) { if (!e.classList.contains('blk')) continue; if (!shows(e)) break; blocks.push(e); }
  const cbs = pending(blocks);
  if (!cbs.length) return false;
  if (firstPaint) {
    for (const cb of cbs) { ask(cb, SCREEN, d); if (waits(cb)) firstPaint.cbs.add(cb); }
    return false;
  }
  jumpHold = hold(cbs, () => { jumpHold = null; again(); }, d);
  return !!jumpHold;
}
let jumpHold = null;
function cancelJump() { if (jumpHold) { holds.delete(jumpHold); clearTimeout(jumpHold.timer); jumpHold = null; } }
// The reader taking over (as aimAt ends a jump) drops a jump still waiting.
for (const type of ['wheel', 'keydown', 'mousedown', 'touchstart']) window.addEventListener(type, cancelJump, { capture: true, passive: true });

// Lazy work is triggered for anything near the viewport: code within two
// screens is asked for (and no longer when it leaves them), a diagram
// within one is drawn a turn after the next frame.
// In a chunk content-visibility skips, a block is placed at the chunk's top
// until the chunk is laid out (chunks.js): one far down a chunk near the
// screen would count as near too, and be highlighted (its spans kept, and
// restyled with every theme switch) long before it is read. It waits for
// its chunk to be laid out (nearChunk), and is asked about again then.
const waitingForChunk = new Map();   // element -> its observer
const skippedChunk = el => {
  const c = el.closest('#ro-doc > .chunk');
  return !!c && doc.classList.contains('cv') && !c.classList.contains('near');
};
const codeObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const cb = e.target;
    if (!cb.isConnected || cb.dataset.hl !== 'pending') { waitingForChunk.delete(cb); codeObserver.unobserve(cb); continue; }
    if (!e.isIntersecting) { waitingForChunk.delete(cb); away(cb); continue; }
    if (skippedChunk(cb)) { waitingForChunk.set(cb, codeObserver); continue; }
    waitingForChunk.delete(cb);
    ask(cb, prioOf(e.boundingClientRect));
  }
}, { rootMargin: '200% 0px 200% 0px' });
// Out of reach again before it arrived (a fling, a jump away): not asked for
// any more (asked again if it comes back), unless it shows in part already,
// or a jump waits for it (it is out of reach of where the jump starts).
function away(cb) {
  const a = asked.get(cb);
  if (!a || [...holds].some(h => h.cbs.has(cb))) return;
  if (inPart.has(cb)) { a.prio = FAR; hl.prioritise(a.id, FAR, 0); return; }
  hl.cancel(a.id);
  unasked(cb);
}
export const lazyObserver = new IntersectionObserver(entries => {
  for (const el of waitingForChunk.keys()) if (!el.isConnected) waitingForChunk.delete(el);
  for (const e of entries) {
    if (!e.target.isConnected) { waitingForChunk.delete(e.target); lazyObserver.unobserve(e.target); continue; }
    if (!e.isIntersecting) { waitingForChunk.delete(e.target); continue; }
    if (skippedChunk(e.target)) { waitingForChunk.set(e.target, lazyObserver); continue; }
    waitingForChunk.delete(e.target);
    lazyObserver.unobserve(e.target);
    queue.push(e.target);
  }
  pump();
}, { rootMargin: '100% 0px 100% 0px' });
/** Chunk `c` is laid out from now on: what waited in it for that is asked about again, where it really is. */
export function nearChunk(c) {
  for (const [el, o] of waitingForChunk) {
    if (!el.isConnected) { waitingForChunk.delete(el); continue; }
    if (!c.contains(el)) continue;
    waitingForChunk.delete(el);
    o.unobserve(el);
    o.observe(el);
  }
}

const SLICE_MS = 6;
const queue = [];
let pumping = false;

// A turn after each frame (not one task after another: the frames between
// them would wait), or after 50 ms when no frame comes (a window not shown).
function pump() {
  if (pumping || !queue.length) return;
  pumping = true;
  let done = false;
  const turn = () => {
    if (done) return;
    done = true;
    pumping = false;
    const start = performance.now();
    let n = 0;
    // At least one a turn, however slow the clock says it is.
    while (queue.length && (n++ === 0 || performance.now() - start < SLICE_MS)) {
      const el = queue.shift();
      if (el.isConnected) renderMermaid(el);
    }
    pump();
  };
  requestAnimationFrame(() => setTimeout(turn, 0));
  setTimeout(turn, 50);
}

/** Highlights every code block not highlighted yet, wherever it is (printing). */
export function highlightAll() {
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) ask(cb, SCREEN);
}

/**
 * `near`: whether a code block counts as on screen (a first open estimates
 * it without layout); `first`: a document shown anew (a reset): its first
 * paint waits for that code.
 */
export function renderLazy(near = inViewport, first = false) {
  const blocks = fresh;
  fresh = [];
  leaving.clear();
  leftIn.clear();
  const onScreen = [];
  for (const cb of blocks) {
    if (!cb.isConnected || cb.dataset.hl !== 'pending') continue;
    if (near(cb)) onScreen.push(cb);
    codeObserver.observe(cb);
  }
  // (Not before the highlighter has started: the first window at launch
  // shows its code plain first, as before, rather than wait for that.)
  if (first && !firstPaint && hl.started) {
    // (A first open estimating what is on screen reads no layout: as much
    // of each block as a screen could show, lines of at least 18 px.)
    firstPaint = hold(onScreen, () => { firstPaint = null; doc.classList.remove('hold'); }, 0,
      near === inViewport ? undefined : Math.ceil((innerHeight + 120) / 18));
    if (firstPaint) doc.classList.add('hold');
  } else for (const cb of onScreen) ask(cb, SCREEN, 0, near === inViewport ? undefined : Math.ceil((innerHeight + 120) / 18));
  // The page's diagrams, without a search of the whole page in every patch.
  for (const m of diagrams) {
    if (!m.isConnected) { diagrams.delete(m); continue; }
    if (!m.classList.contains('done') && !m.classList.contains('busy') && !m.dataset.waiting) lazyObserver.observe(m);
  }
}
const diagrams = new Set();   // every diagram block set up (enhance), until it leaves the page
