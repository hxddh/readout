// Code blocks: how one is laid out (box drawing, prose in a fence, its
// longest line) and its highlighting, in a worker (highlight.js), never on
// this thread. enhance.js gives a block its tools and sets it up here; the
// frames that wait for code to be coloured are holds.js's (it asks for that
// code here, and hears from here when it shows: neither calls the other as
// it loads).
import * as hl from '../highlight.js';
import { doc, WIDE } from './core.js';
import { waitingForChunk, skippedChunk } from './chunks.js';
import { held, shown } from './holds.js';

// ------------------------------------------------------------ One block

// Everything about one block's highlighting, in one record (blockState):
//   code    its code
//   asked   {id, prio, upto}: asked for, not arrived; else null
//   ready   {lang, html}: arrived, put in once it is within a screen; else null
//   part    {rest: its plain text node, lines, done: how many coloured,
//           plain: its plain <pre>, kept: from before (keepLines)}: shown a
//           part at a time; else null
//   slow    its grammar was not loaded when asked for
//   urgent  a hold waits for it (asked URGENT)
//   within  within a screen of the viewport (applyObserver)
//   far     out of reach (codeObserver): its arrived HTML may be dropped (trim)
const state = new WeakMap();
function blockState(cb) {
  let s = state.get(cb);
  if (!s) state.set(cb, s = { code: null, asked: null, ready: null, part: null, slow: false, urgent: false, within: false, far: false });
  return s;
}
// Alongside, for what goes through them in order:
const asking = new Set();    // blocks asked for (asked), not arrived
const keeping = new Set();   // blocks with HTML arrived (ready), in the order it arrived

/** Code blocks asked for, not arrived (a test checks what lazy work holds stays bounded). */
export const askedBlocks = () => asking;

// ------------------------------------------------------------ Setting up

/**
 * A code block made (its tools added, enhance.js): laid out by its code, and
 * pending (asked for once it is near, renderLazy); `old`: the code block in
 * its place before (keepColours).
 */
export function setupCode(cb, old) {
  const text = cb.querySelector('pre').textContent;
  // Box-drawing characters (a directory tree, a diagram): tighter lines, so
  // the vertical strokes join up.
  if (/[─-╿]/.test(text)) cb.classList.add('cb-tree');
  // Prose in a fence (a prompt, a SKILL.md, notes) wraps at the column like
  // the text around it: a 400-column sentence read by scrolling sideways is
  // not code. Never a drawing, a listing, a log or a transcript.
  const prose = isProseFence(cb.dataset.lang, text) && !cb.classList.contains('cb-tree');
  cb.classList.toggle('cb-prose', prose);
  // Its longest line, in columns: reader.css widens a code block of its own
  // whose lines run past the column into the margins, when the window has room.
  if (cb.parentElement.classList.contains('k-code')) cb.parentElement.style.setProperty('--cb-cols', prose ? 0 : codeColumns(text));
  blockState(cb).code = text;
  // The same code a block this patch took away showed coloured: its <pre> moved over.
  // (Nothing taken away, as at a first open: no key made, its whole code a string the size of it.)
  const same = leaving.size ? leaving.get(`${cb.dataset.lang}\0${text}`) : null;
  if (same) { leaving.delete(`${cb.dataset.lang}\0${text}`); cb.querySelector('pre').replaceWith(same); cb.dataset.hl = 'done'; return; }
  cb.dataset.hl = 'pending';
  fresh.push(cb);
  if (old) keepLines(cb, text, old);
}

// Code a patch takes away coloured (a block replaced, or the document reset)
// is kept for the code that takes its place, until the patch is applied
// (takeFresh): the same code in a block of the new document is that code
// coloured; a block an agent edits keeps its first lines, those it did not
// change, coloured (what a line shows depends only on the lines before it),
// the rest plain until the block's HTML arrives.
const leaving = new Map();      // lang \0 code -> the <pre> of a block taken away, all of it coloured
const leftIn = new Map();       // block element filled again -> its code blocks before: {lang, code or lines, pre, done} or null
/** Block element `el` is replaced, removed or reset away: its coloured code kept for what takes its place. */
export function keepColours(el) {
  const old = [...el.querySelectorAll('.code-block')].map(x => {
    const s = state.get(x), pre = x.querySelector('pre'), v = s?.part, code = s?.code;
    if (x.dataset.hl === 'done' && code != null) {
      const key = `${x.dataset.lang}\0${code}`;
      leaving.set(key, pre);
      return { lang: x.dataset.lang, code, pre, done: Infinity, key };
    }
    return v && !v.kept ? { lang: x.dataset.lang, lines: v.lines, pre, done: v.done } : null;
  });
  if (old.some(Boolean)) leftIn.set(el, old);
}
/** What block element `el` showed coloured before it was filled again (keepColours), per code block, once. */
export function keptIn(el) {
  const old = leftIn.get(el);
  leftIn.delete(el);
  return old;
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
  const plain = cb.querySelector('pre');
  plain.replaceWith(o.pre);
  // All of its lines kept: it is that code coloured, nothing to ask for.
  if (k === lines.length) { rest.remove(); cb.dataset.hl = 'done'; fresh.pop(); return; }
  blockState(cb).part = { rest, lines, done: k, kept: true, plain };
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

// Code blocks set up since the last takeFresh(): only these are looked at
// after a patch, so an update costs nothing for the rest of the document.
let fresh = [];

/**
 * The patch is applied: the code blocks set up for it are watched from now
 * on (codeObserver). Returns those `near` counts as on screen.
 */
export function takeFresh(near) {
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
  return onScreen;
}

/** A block replaced, removed or reset away (forgetBlock): not watched, asked for or kept any more. */
export function forgetCode(cb) {
  codeObserver.unobserve(cb);
  applyObserver.unobserve(cb);
  unkeep(cb);
  const a = state.get(cb)?.asked;
  if (a) { hl.cancel(a.id); unasked(cb); }
}

// ------------------------------------------------------------ Asking

// Highlighting runs in a worker (highlight.js), never on this thread: a
// block asks for its HTML once it comes within the lookahead (four screens:
// at a fling's speed the worker has the time a block takes to cross them),
// the more urgent the nearer it is (on screen first, then by how far it is,
// raised as the reader comes nearer), and no longer when it falls out of
// reach before it arrives. Its HTML replaces its plain <pre> once the block
// is within a screen (kept until then: a block further off is not coloured
// in the page, its spans restyled with every theme switch), the reader's
// selection in it kept. The frames that would show code on screen before it
// has arrived (a document's first paint, a jump, find landing in code) wait
// for it instead, for a moment at most (holds.js).
const URGENT = -1, SCREEN = 0, NEAR = 1;   // URGENT: what a hold waits for (a jump, a first paint)
let everything = false;   // all of it wanted coloured (printing: highlightAll), until the next document
/** On screen: 0; else 1 and how many screens away. */
function prioOf(r) {
  if (r.bottom > 0 && r.top < innerHeight) return SCREEN;
  return NEAR + (r.top >= innerHeight ? r.top - innerHeight : -r.bottom) / innerHeight;
}

/**
 * `dy`: a jump about to scroll by that much (holdJump): on screen where it
 * lands. `upto`: the lines it shows (on screen: as far as the screen shows).
 */
function ask(cb, prio, dy = 0, upto = prio <= SCREEN ? linesShown(cb, dy) : 0) {
  if (cb.dataset.hl !== 'pending') return;
  const s = blockState(cb);
  if (s.ready) { if (prio <= NEAR) put(cb); return; }
  if (prio === URGENT) s.urgent = true;
  const lang = hl.resolveLang(cb.dataset.lang);
  if (!lang) { cb.dataset.hl = 'none'; return; }
  const a = s.asked;
  // (Asked as urgently already: unless now for more of its lines.)
  if (a && (prio > a.prio || (prio === a.prio && upto <= a.upto))) return;
  // On screen: the lines it shows (and 120 px more) are sent ahead of the rest.
  if (a) { a.prio = prio; a.upto = upto; hl.prioritise(a.id, prio, upto); } else {
    const code = s.code;
    // The parts after the first put in as they come (not a long block's, nor one showing lines kept from before).
    const stream = !s.part && code.split('\n', PARTS_MAX + 1).length <= PARTS_MAX;
    s.asked = { prio, upto, id: hl.request(code, lang, prio, upto, stream, {
      done: html => deliver(cb, () => arrived(cb, lang, html)),
      part: (html, lines, first) => deliver(cb, () => part(cb, lang, html, code, lines, first)),
      // Its grammar not loaded yet: nothing waits for it (it shows plain, coloured once it is).
      loading: () => { blockState(cb).slow = true; shown(cb); },
    }) };
    asking.add(cb);
    applyObserver.observe(cb);
  }
  // Nearer as the reader comes nearer (asked for sooner).
  screenObserver.observe(cb);
  if (prio > NEAR) nearObserver.observe(cb);
}
function unasked(cb) {
  const s = blockState(cb);
  s.asked = null;
  asking.delete(cb);
  s.slow = false;
  s.urgent = false;
  screenObserver.unobserve(cb);
  nearObserver.unobserve(cb);
}

/**
 * The code block a document shown anew may show on its first screen (by the
 * estimated heights of the blocks above it), asked for as it is made, so
 * that the worker highlights it while the page lays the document out; or
 * one on screen once a patch is applied (renderLazy). `upto`: its lines
 * that screen could show.
 */
export function askOnScreen(cb, upto) { ask(cb, SCREEN, 0, upto); }

/** A hold waits for `cb`: asked for first, the lines it shows where a jump by `dy` lands (or `upto`). */
export function urge(cb, dy, upto) { ask(cb, URGENT, dy, upto); }
/** The hold over: `cb` no more urgent than the rest on screen. */
export function calm(cb) {
  const s = state.get(cb);
  if (!s) return;
  s.urgent = false;
  const a = s.asked;
  if (a && a.prio < SCREEN) { a.prio = SCREEN; hl.prioritise(a.id, SCREEN, a.upto); }
}
/** Not coloured on screen yet: neither all of it, nor its lines on screen (and its grammar was loaded). */
export function uncoloured(cb) {
  const s = blockState(cb);
  return cb.dataset.hl === 'pending' && !s.slow && !(s.part && !s.part.kept);
}

/** A document shown anew: printing's wish for all of it coloured (highlightAll) is over. */
export function newDocument() { everything = false; }

/** Highlights every code block not highlighted yet, wherever it is (printing). */
export function highlightAll() {
  everything = true;
  for (const cb of [...keeping]) put(cb);
  for (const cb of doc.querySelectorAll('.code-block[data-hl="pending"]')) ask(cb, NEAR, 0, 0);
}

// (Off screen again, a block not waited for goes back behind those on it.)
const nearer = prio => new IntersectionObserver(es => {
  for (const e of es) {
    if (e.isIntersecting) { ask(e.target, prio); continue; }
    const s = blockState(e.target), a = s.asked;
    if (prio === SCREEN && a && a.prio <= SCREEN && !s.urgent) { a.prio = prioOf(e.boundingClientRect); hl.prioritise(a.id, a.prio, a.upto); }
  }
}, { rootMargin: prio === SCREEN ? '0px' : '100% 0px 100% 0px' });
const screenObserver = nearer(SCREEN), nearObserver = nearer(NEAR);
// Within a screen: arrived HTML is put in.
const applyObserver = new IntersectionObserver(es => {
  for (const e of es) {
    const s = blockState(e.target);
    if (!e.isIntersecting) { s.within = false; continue; }
    s.within = true;
    if (s.ready) put(e.target);
  }
}, { rootMargin: '100% 0px 100% 0px' });

// Within four screens: asked for (and no longer when it leaves them). One
// in a chunk not laid out yet waits for it (chunks.js: waitingForChunk).
const codeObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const cb = e.target;
    if (!cb.isConnected || cb.dataset.hl !== 'pending') { waitingForChunk.delete(cb); codeObserver.unobserve(cb); continue; }
    if (!e.isIntersecting) { waitingForChunk.delete(cb); away(cb); continue; }
    blockState(cb).far = false;
    if (skippedChunk(cb)) { waitingForChunk.set(cb, codeObserver); continue; }
    waitingForChunk.delete(cb);
    ask(cb, prioOf(e.boundingClientRect));
  }
}, { rootMargin: '400% 0px 400% 0px' });
// Out of reach again before it arrived (a fling, a jump away): not asked for
// any more (asked again if it comes back), unless it shows in part already,
// all of it is wanted (printing: highlightAll), or a jump waits for it (it is out of reach of where the jump starts).
// HTML that did arrive is kept for when it comes back (trim).
function away(cb) {
  const s = blockState(cb);
  s.far = true;
  if (s.ready) trim();
  const a = s.asked;
  if (!a || everything || held(cb)) return;
  if (s.part) { a.prio = NEAR + 4; hl.prioritise(a.id, a.prio, 0); return; }
  hl.cancel(a.id);
  unasked(cb);
}

// ------------------------------------------------------------ Arriving

// What arrives is put in at the next frame, all of it at once, before
// that frame's layout (one layout, not one per answer, nor one forced by
// the next patch's measurements); what a hold waits for at once.
let batched = [], batchFrame = 0;
function deliver(cb, f) {
  if (!held(cb)) {
    batched.push(f);
    batchFrame ||= requestAnimationFrame(flushArrived);
    return;
  }
  flushArrived();   // (in order: what came before for it first)
  f();
}
function flushArrived() {
  if (batchFrame) cancelAnimationFrame(batchFrame);
  batchFrame = 0;
  for (const f of batched.splice(0)) f();
}

// HTML that arrived for a block not within a screen yet is kept until it
// is, also once it is out of reach again (a block read, scrolled past and
// come back to is not highlighted again): at most KEEP_BYTES of it, what
// arrived first for a block out of reach dropped first.
const KEEP_BYTES = 4 << 20;   // its strings' size, 2 bytes a character
let keptBytes = 0;
function keep(cb, lang, html) {
  blockState(cb).ready = { lang, html };
  keeping.add(cb);
  keptBytes += html.length * 2;
  trim();
}
function unkeep(cb) {
  const s = state.get(cb);
  if (!s?.ready) return;
  keptBytes -= s.ready.html.length * 2;
  s.ready = null;
  keeping.delete(cb);
}
// (What a block in reach waits for is never dropped: it is put in soon.)
function trim() {
  for (const cb of keeping) {
    if (keptBytes <= KEEP_BYTES) return;
    if (blockState(cb).far || !cb.isConnected) unkeep(cb);
  }
}

function arrived(cb, lang, html) {
  unasked(cb);
  if (!cb.isConnected) return;
  const s = blockState(cb), v = s.part;
  // Not near the screen yet (nothing waits for it): kept until it is.
  if (html && !v && !everything && !s.within && !held(cb)) { keep(cb, lang, html); return; }
  applyObserver.unobserve(cb);
  if (html === '') {
    // All of it came in parts: in place already.
    if (v?.rest && !v.rest.length) v.rest.remove();
    cb.dataset.hl = 'done';
  } else if (html) {
    swap(cb, toPre(html, lang));
    cb.dataset.hl = 'done';
  } else {
    // Not highlighted: shown plain again, all of it.
    if (v?.plain) swap(cb, v.plain);
    cb.dataset.hl = 'none';
  }
  s.part = null;
  shown(cb);
}
/** Arrived HTML put in (the block within a screen now, or waited for). */
function put(cb) {
  const r = blockState(cb).ready;
  unkeep(cb);
  applyObserver.unobserve(cb);
  if (!cb.isConnected || cb.dataset.hl !== 'pending') return;
  swap(cb, toPre(r.html, r.lang));
  cb.dataset.hl = 'done';
  shown(cb);
}

// A long block's lines on screen, ahead of the rest (still plain, after
// them), then each part as it comes, in place of its lines' plain text; a
// block of more than PARTS_MAX lines takes only the first: each is the
// whole block laid out again (a block of 28,000 lines: a second).
const PARTS_MAX = 1000;
function part(cb, lang, html, code, done, first) {
  if (!cb.isConnected || cb.dataset.hl !== 'pending') return;
  const s = blockState(cb);
  let v = s.part;
  if (first) {
    if (v?.kept && done <= v.done) return;   // its kept lines show as much
    const pre = toPre(html, lang);
    const lines = code.split('\n');
    v = { rest: document.createTextNode('\n' + lines.slice(done).join('\n')), lines, done, plain: v?.plain ?? cb.querySelector('pre') };
    pre.firstElementChild.append(v.rest);
    swap(cb, pre);
    s.part = v;
    shown(cb);
    return;
  }
  if (!v || v.kept || v.lines.length > PARTS_MAX) return;
  const tpl = document.createElement('template');
  tpl.innerHTML = `<pre><code>\n${html}</code></pre>`;
  const lines = tpl.content.firstElementChild.firstElementChild;
  markDiff(lines, lang);
  let len = 0;
  for (let i = v.done; i < done; i++) len += v.lines[i].length + 1;
  keepSelection(cb.querySelector('pre'), () => { v.rest.deleteData(0, len); v.rest.before(...lines.childNodes); });
  v.done = done;
}

// ------------------------------------------------------------ Putting in

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

/** `pre` in place of the block's <pre>, the same text (keeping the reader's selection in it). */
function swap(cb, pre) {
  const old = cb.querySelector('pre');
  keepSelection(old, () => old.replaceWith(pre), () => pre);
}
/**
 * `change()` rewrites a <pre>'s nodes, its text the same: the reader's
 * selection in it (an end of it) kept, by its offsets in that text (`after()`: the <pre> then).
 */
function keepSelection(old, change, after = () => old) {
  const sel = getSelection();
  if (!sel.rangeCount || !(old.contains(sel.anchorNode) || old.contains(sel.focusNode))) return change();
  const offset = (n, o) => { if (!old.contains(n)) return null; const r = document.createRange(); r.setStart(old, 0); r.setEnd(n, o); return r.toString().length; };
  const [an, ao, fn, fo] = [sel.anchorNode, sel.anchorOffset, sel.focusNode, sel.focusOffset];
  const aat = offset(an, ao), fat = offset(fn, fo);
  change();
  const pre = after();
  const at = n => {
    const w = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
    for (let t = w.nextNode(); t; t = w.nextNode()) { if (n <= t.length) return [t, n]; n -= t.length; }
    return [pre, pre.childNodes.length];
  };
  sel.setBaseAndExtent(...(aat == null ? [an, ao] : at(aat)), ...(fat == null ? [fn, fo] : at(fat)));
}

function markDiff(root, id) {
  if (id !== 'diff') return;
  for (const line of root.querySelectorAll('.line')) {
    const t = line.textContent;
    if (t.startsWith('+') && !t.startsWith('+++')) line.classList.add('add');
    else if (t.startsWith('-') && !t.startsWith('---')) line.classList.add('del');
  }
}
