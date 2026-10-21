// Find in page: the window's find field (⌘F; ⌘G, ⇧⌘G and Return for the next
// and previous match). WebKit's own find skips blocks content-visibility has
// not laid out, so it needed the whole document laid out while the find bar
// was open (1 MB: seconds as it opened, and again as it closed). Here each
// block's text is read without layout, the match is selected (⌘C, Copy
// as Quote), and the matches are marked with the CSS Custom
// Highlight API: only those in the blocks around the current one (marking
// every match of a large document makes WebKit's paint take tens of seconds).
import { doc, slots, post } from './core.js';
import { aimAt, pinLanding, topInset, blocksOnScreen } from './anchor.js';
import { noteLanding } from './marks.js';
import { highlightIn } from './enhance.js';

// Not the document's text: controls, the MathML copy of a formula (its
// rendering is searched), a drawn diagram's source, a comparison panel.
const SKIP_TAGS = new Set(['BUTTON', 'STYLE', 'SCRIPT', 'TEMPLATE', 'style', 'script']);
const SKIP_CLASS = /(^| )(katex-mathml|cb-tools|wd-panel|remote-img|mermaid-src)( |$)/;
function skipped(el) {
  if (SKIP_TAGS.has(el.tagName) || el.hidden) return true;
  const c = el.className;
  return !!c && typeof c === 'string' && SKIP_CLASS.test(c) && !(el.classList.contains('mermaid-src') && !el.parentElement.classList.contains('done'));
}
// Text in two of these is not one run of text: a match does not span them.
const BREAK = new Set(['P', 'DIV', 'LI', 'UL', 'OL', 'DL', 'DT', 'DD', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'PRE', 'BLOCKQUOTE', 'TABLE', 'TR', 'TD', 'TH', 'DETAILS', 'SUMMARY', 'FIGURE', 'FIGCAPTION', 'BR', 'HR']);
const SEP = '\0';
// Case and accents do not count, as in the system's find ("cafe" finds
// "Café"); the kana voicing marks do (か does not find が), as in WebKit's.
const MARKS = /(?![\u3099\u309a])\p{M}/gu;
// Lowercase letters that have another lowercase form of the same case (all
// of them one character, so offsets stay as they are): final sigma is sigma,
// long s is s, Greek symbol forms are their letters. Foldings that change
// the length (ß, which WebKit's find matches with "ss") are not made.
const VARIANT = { 'µ': 'μ', 'ı': 'i', 'ſ': 's', 'ς': 'σ', 'ϐ': 'β', 'ϑ': 'θ', 'ϕ': 'φ', 'ϖ': 'π', 'ϰ': 'κ', 'ϱ': 'ρ', 'ϵ': 'ε',
  'ᲀ': 'в', 'ᲁ': 'д', 'ᲂ': 'о', 'ᲃ': 'с', 'ᲄ': 'т', 'ᲅ': 'т', 'ᲆ': 'ъ', 'ᲇ': 'ѣ', 'ᲈ': 'ꙋ', 'ι': 'ι' };
const VARIANTS = new RegExp(`[${Object.keys(VARIANT).join('')}]`, 'g');
// Only text with letters that can carry an accent is decomposed (most text
// has none: plain ASCII, punctuation, CJK).
const ACCENTED = /[\u00b5\u00c0-\u1fff\u20d0-\u20ff\ufb00-\ufb4f]/;
const fold = s => (ACCENTED.test(s)
  ? s.toLowerCase().normalize('NFD').replace(MARKS, '').normalize('NFC').replace(VARIANTS, c => VARIANT[c])
  : s.toLowerCase()).replace(/\s/g, ' ');
const NEAR = 10;      // blocks either side of the current match whose matches are marked
const MARKED = 300;   // and at most this many marks
const HL = typeof CSS !== 'undefined' && 'highlights' in CSS;

let query = null;       // the folded text searched for; null: not finding
let re = null;
let matches = [];       // {el, x, bi, start, end}, in document order: x is the block's text, start and end in it
let cur = -1;           // the current match
let shown = '';         // the count last told to the app
// Where the current match is: its block's slot (a reset keeps the slots of
// the blocks it keeps) and its place among that block's matches.
let pos = null;         // {slot, ord, next}: next, the slot of the block after it, once it is removed
let own = null;         // the range find selected, while the selection is it
let observing = false;
let texts = new WeakMap();   // block -> its text (textOf), while finding

/**
 * A block's text as find sees it (folded), and where in it each text node
 * starts: [start, node, offsets]. Offsets is null when folding kept the
 * text's length (the usual case: the block is folded at once), else the
 * node's offset of each folded character (and of its end).
 */
function textOf(blk, each = false) {
  let s = '';
  let sep = true;   // s ends with SEP (or is empty)
  const segs = [];
  const walk = el => {
    for (let n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === Node.TEXT_NODE) {
        const raw = n.data;
        if (!raw) continue;
        if (!each) { segs.push([s.length, n, null]); s += raw; sep = false; continue; }
        let f = fold(raw), map = null;
        if (f.length !== raw.length) {
          f = '';
          map = [];
          for (let i = 0; i < raw.length;) {
            const len = raw.codePointAt(i) > 0xffff ? 2 : 1;
            const c = fold(raw.slice(i, i + len));
            for (let k = 0; k < c.length; k++) map.push(i);
            f += c;
            i += len;
          }
          map.push(raw.length);
        }
        if (f) { segs.push([s.length, n, map]); s += f; sep = false; }
      } else if (n.nodeType === Node.ELEMENT_NODE && !skipped(n)) {
        const b = BREAK.has(n.tagName);
        if (b && !sep) { s += SEP; sep = true; }
        walk(n);
        if (b && !sep) { s += SEP; sep = true; }
      }
    }
  };
  walk(blk);
  if (each) return { s, segs };
  const f = fold(s);
  // Folding changed the length of some text (an accent written as a
  // character of its own): folded node by node instead.
  return f.length === s.length ? { s: f, segs } : textOf(blk, true);
}

function search() {
  matches = [];
  let bi = 0;
  for (let e = doc.firstElementChild; e; e = e.nextElementSibling) {
    if (!e.classList.contains('blk')) continue;
    bi++;
    if (e.hidden) continue;
    let x = texts.get(e);
    if (!x) texts.set(e, x = textOf(e));
    re.lastIndex = 0;
    for (let m; (m = re.exec(x.s));) matches.push({ el: e, x, bi, start: m.index, end: m.index + m[0].length });
  }
}

function point(m, i, end) {
  const segs = m.x.segs;
  let lo = 0, hi = segs.length - 1;
  const at = end ? i - 1 : i;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (segs[mid][0] <= at) lo = mid; else hi = mid - 1; }
  const [start, node, map] = segs[lo];
  return [node, map ? map[i - start] : i - start];
}

function rangeOf(m) {
  const r = document.createRange();
  r.setStart(...point(m, m.start, false));
  r.setEnd(...point(m, m.end, true));
  return r;
}

const before = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);

const blockOf = n => n && doc.contains(n) ? (n.nodeType === Node.ELEMENT_NODE ? n : n.parentElement).closest('#ro-doc > .blk') : null;

/**
 * Where a new search looks from: the selection (the last match, or text
 * the reader selected), else the block at the top of the screen. [cmp,
 * strict]: cmp compares a match with it (< 0 before it, 0 at it, > 0 after
 * it); strict: a match at it is not the next one (it is the last one).
 */
function origin() {
  const sel = getSelection();
  const r = sel.rangeCount ? sel.getRangeAt(0) : null;
  const blk = r && blockOf(r.startContainer);
  if (blk) {
    const { startContainer: n, startOffset: o } = r;
    return [m => {
      if (m.el !== blk) return before(m.el, blk) ? -1 : 1;
      const at = document.createRange();
      at.setStart(...point(m, m.start, false));
      return -at.comparePoint(n, o);
    }, true];
  }
  return [fromTop, false];
}
function fromTop(m) {
  const top = fromTop.top;
  return !top || m.el === top ? 0 : before(m.el, top) ? -1 : 1;
}
const topNow = () => { fromTop.top = blocksOnScreen()[0]; return fromTop; };

/**
 * The current match after a search of the page: [index, exact]. exact: in
 * its block still, the same one among the block's matches (clamped: an
 * edit earlier in the block does not make a later one current). Else the
 * first match after that block, or, the block gone, at or after the block
 * that followed it, else the top of the screen. [-1, false]: none.
 */
function resolve() {
  if (!pos || !matches.length) return [-1, false];
  const el = slots.get(pos.slot);
  if (!el || !el.isConnected) {
    const after = pos.next && slots.get(pos.next);
    if (after && after.isConnected) return [next(m => m.el === after ? 0 : before(m.el, after) ? -1 : 1, false, false), false];
    return [next(topNow(), false, false), false];
  }
  const i = next(m => m.el === el ? 0 : before(m.el, el) ? -1 : 1, false, false);
  if (matches[i].el !== el) return [i, false];
  delete pos.next;
  let k = i;
  while (k - i < pos.ord && k + 1 < matches.length && matches[k + 1].el === el) k++;
  return [k, true];
}

/** The first match `cmp` puts after its origin (`strict`: at it does not count), wrapping. */
function next(cmp, strict, backwards) {
  let lo = 0, hi = matches.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const c = cmp(matches[mid]);
    if (c > 0 || (!strict && c === 0)) hi = mid; else lo = mid + 1;
  }
  if (!backwards) return lo < matches.length ? lo : 0;
  // Backwards: the last match before the origin.
  lo = 0; hi = matches.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (cmp(matches[mid]) < 0) lo = mid + 1; else hi = mid; }
  return lo > 0 ? lo - 1 : matches.length - 1;
}

/** Marks the current match and those around it; returns the current one's range. */
function mark() {
  const m = matches[cur];
  if (!m) { if (HL) { CSS.highlights.delete('ro-find'); CSS.highlights.delete('ro-find-cur'); } return null; }
  const range = rangeOf(m);
  if (!HL) return range;
  const near = new Highlight();
  for (let i = cur - 1; i >= 0 && m.bi - matches[i].bi <= NEAR && near.size < MARKED / 2; i--) near.add(rangeOf(matches[i]));
  for (let i = cur + 1; i < matches.length && matches[i].bi - m.bi <= NEAR && near.size < MARKED; i++) near.add(rangeOf(matches[i]));
  CSS.highlights.set('ro-find', near);
  CSS.highlights.set('ro-find-cur', new Highlight(range));
  return range;
}

function select(range) {
  const sel = getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  own = range;
}
const isOwn = () => {
  const sel = getSelection();
  const r = own && sel.rangeCount ? sel.getRangeAt(0) : null;
  return !!r && r.startContainer === own.startContainer && r.startOffset === own.startOffset
    && r.endContainer === own.endContainer && r.endOffset === own.endOffset;
};
// The reader selecting something else: the selection is theirs.
document.addEventListener('selectionchange', () => { if (own && !isOwn()) own = null; });

/**
 * The match landed on is selected once the frame showing it is painted (its
 * mark shows it until then): in a large document WebKit answers any change
 * of the selection by laying out the blocks content-visibility skips again
 * (1 MB: about as long as the search itself).
 */
let selecting = null;   // the landing whose match is still to be selected
function selectLater() {
  const mine = selecting = {};
  requestAnimationFrame(() => setTimeout(() => { if (selecting === mine) selectNow(); }, 0));
}
function selectNow() {
  selecting = null;
  const m = matches[cur];
  if (m) select(rangeOf(m));
}

/** Tells the app the count (current 0: none yet): after every search, after an edit only when it changed. */
function report(always = false) {
  const now = `${cur + 1}/${matches.length}`;
  if (now === shown && !always) return;
  shown = now;
  post({ type: 'found', current: cur + 1, total: matches.length });
}

/** To the current match (a search): selected, and on screen (it stays where it is if it is already). */
function land() {
  const m = matches[cur];
  const el = m.el;
  // Its code highlighted before the match is selected in it (highlighting
  // replaces the text nodes), and a folded <details> it is in opened.
  if (el.querySelector('.code-block[data-hl="pending"]')) {
    highlightIn([el]);
    changed(observer.takeRecords());
    reread();
  }
  let range = rangeOf(m);
  for (let d = range.startContainer.parentElement.closest('details'); d && el.contains(d); d = d.parentElement.closest('details')) {
    if (!d.open && !d.querySelector(':scope > summary')?.contains(range.startContainer)) d.open = true;
  }
  range = mark();
  let first = cur;
  while (first > 0 && matches[first - 1].el === el) first--;
  pos = { slot: +el.dataset.slot, ord: cur - first };
  selectLater();
  // Off screen, the block is not laid out (content-visibility): it is aimed
  // at first, the match once the frames after the jump have laid it out.
  const off = () => {
    const b = el.getBoundingClientRect();
    const r = b.bottom > 0 && b.top < innerHeight && range.getClientRects().length ? range.getBoundingClientRect() : b;
    const inset = topInset();
    if (r.top >= inset + 8 && r.bottom <= innerHeight - 8) return 0;
    return r.top - inset - (innerHeight - inset) / 3;
  };
  aimAt(el, off, () => { noteLanding(el); pinLanding(el); });
}

// While finding, an edit (an agent writing) is found in too: the count
// follows it. A block redrawn with the same text (its code highlighted, a
// formula or diagram drawn as it comes near) is not searched again: only
// where its text nodes are is.
const observer = new MutationObserver(records => { changed(records); later(); });
const stale = new Set();   // blocks changed since their text was read
let moved = false;         // blocks added, removed, hidden or shown since
function changed(records) {
  for (const r of records) {
    if (r.target === doc || r.type === 'attributes') moved = true;
    // The current match's block (or the one after it) removed: what followed it is where it was.
    if (pos && r.target === doc) {
      for (const n of r.removedNodes) {
        const slot = n.dataset ? +n.dataset.slot : NaN;
        if (slot === (pos.next ?? pos.slot)) { const after = r.nextSibling && r.nextSibling.closest?.('.blk') ? r.nextSibling : null; pos.next = after ? +after.dataset.slot : 0; }
      }
    }
    const e = r.target.nodeType === Node.ELEMENT_NODE ? r.target : r.target.parentElement;
    const blk = e && e !== doc && e.closest('#ro-doc > .blk');
    if (blk) stale.add(blk);
  }
}
/** Reads the changed blocks' text again; returns whether any of it changed (a search is due). */
function reread() {
  let any = moved;
  moved = false;
  for (const blk of stale) {
    const old = texts.get(blk);
    if (!old) continue;
    const x = textOf(blk);
    if (x.s === old.s) old.segs = x.segs;
    else { texts.set(blk, x); any = true; }
  }
  stale.clear();
  return any;
}
let refreshTimer = null;
function later() { if (!refreshTimer) refreshTimer = setTimeout(refresh, 100); }
/**
 * After an edit (an agent writing, a reset, a block drawn): the count and
 * the marks follow, and that is all. An edit never moves the reader or
 * takes their selection: the current match is found again where it was
 * (resolve), and selected again only if find's selection was on it and the
 * edit took it (its text nodes replaced). A search that found nothing
 * shows the count of what an edit brings ("– of 3") until the next Return.
 */
function refresh() {
  refreshTimer = null;
  if (query == null) return;
  const t0 = performance.now();
  if (reread()) search();
  const [i, exact] = resolve();
  cur = i;
  const range = mark();
  if (range && exact && own && own.collapsed && !selecting) select(range);
  report();
  performance.clearMarks('readout-find-refresh');
  performance.mark('readout-find-refresh', { detail: performance.now() - t0 });
}

/**
 * The next match of `text` (`backwards`: the previous one), wrapping around:
 * selected, marked and on screen. Returns how many matches there are.
 */
export function find(text, backwards = false) {
  const q = fold(String(text ?? '').trim());
  if (!q) { findEnd(); return 0; }
  if (!observing) {
    observing = true;
    texts = new WeakMap();
    observer.observe(doc, { childList: true, characterData: true, subtree: true, attributes: true, attributeFilter: ['hidden'] });
  } else changed(observer.takeRecords());
  reread();
  const same = q === query;
  if (!same) {
    query = q;
    pos = null;
    re = new RegExp(q.split(/ +/).map(w => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join(' +'), 'g');
  }
  search();
  if (!matches.length) { cur = -1; pos = null; mark(); report(true); return 0; }
  // Next and Previous go on from the current match, unless the reader has
  // selected something else since.
  const sel = getSelection();
  const r = sel.rangeCount ? sel.getRangeAt(0) : null;
  const theirs = !!r && !r.collapsed && !selecting && !isOwn() && !!blockOf(r.startContainer);
  const [i, exact] = same && !theirs ? resolve() : [-1, false];
  const n = matches.length;
  if (i < 0) { const [cmp, strict] = origin(); cur = next(cmp, strict, backwards); }
  else if (exact) cur = (i + (backwards ? n - 1 : 1)) % n;
  else cur = backwards ? (i + n - 1) % n : i;
  land();
  report(true);
  return matches.length;
}

/**
 * The search over: the marks go, the selection stays. `keep`: the find bar
 * is still open (its text edited), the blocks' text is kept for the next search.
 */
export function findEnd(keep = false) {
  if (selecting) selectNow();
  query = null;
  clearTimeout(refreshTimer);
  refreshTimer = null;
  matches = [];
  cur = -1;
  pos = null;
  shown = '';
  if (HL) { CSS.highlights.delete('ro-find'); CSS.highlights.delete('ro-find-cur'); }
  if (keep) return;
  observing = false;
  observer.disconnect();
  texts = new WeakMap();
  stale.clear();
  moved = false;
  own = null;
}
