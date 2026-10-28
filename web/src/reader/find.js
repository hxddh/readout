// Find in page: the window's find field (⌘F; ⌘G, ⇧⌘G and Return for the next
// and previous match). WebKit's own find skips blocks content-visibility has
// not laid out, so it needed the whole document laid out while the find bar
// was open (1 MB: seconds as it opened, and again as it closed). Here each
// block's text is read without layout, the match is selected (⌘C, Copy
// as Quote, Speak), and the matches are marked with the CSS Custom
// Highlight API: only those in the blocks around the current one (marking
// every match of a large document makes WebKit's paint take tens of seconds).
// Every match is counted, but only a window of them around the current one
// is kept (a one-letter search of 5 MB matches 300,000 times).
import { doc, slots, post, firstItem, nextItem, isChunk } from './core.js';
import { aimAt, pinLanding, topInset, blocksOnScreen } from './anchor.js';
import { noteLanding } from './marks.js';
import { whenColoured } from './enhance.js';
import { cv } from './chunks.js';

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
const KEPT = 10_000;  // matches kept, around the current one
const HL = typeof CSS !== 'undefined' && 'highlights' in CSS;

let query = null;       // the folded text searched for; null: not finding
let re = null;
let matches = [];       // {el, x, bi, ord, start, end}, in document order: x is the block's text, ord the match's place in it, start and end in it
let base = 0;           // the number of matches before matches[0]
let total = 0;          // the number of matches in the document
let cur = -1;           // the current match (in matches)
let shown = '';         // the count last told to the app
// Where the current match is: its block's slot (a reset keeps the slots of
// the blocks it keeps) and its place among that block's matches.
let pos = null;         // {slot, ord, start, fromEnd, next}: next, the slot of the block after it, once it is removed
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

/**
 * Counts the matches and keeps those around `at`: {el, ord} (a block and
 * a match's place in it) or {n} (a match's number in the document).
 */
function search(at) {
  const blocks = [];
  total = 0;
  let center = at && at.n != null ? at.n : 0;
  let bi = 0;
  for (let e = firstItem(); e; e = nextItem(e)) {
    if (!e.classList.contains('blk')) continue;
    bi++;
    if (e.hidden) continue;
    let x = texts.get(e);
    if (!x) texts.set(e, x = textOf(e));
    const c = x.s.match(re)?.length ?? 0;
    if (at && e === at.el) center = total + Math.min(at.ord, Math.max(0, c - 1));
    if (!c) continue;
    blocks.push([e, x, bi, total, c]);
    total += c;
  }
  base = Math.max(0, Math.min(center - KEPT / 2, total - KEPT));
  const end = Math.min(total, base + KEPT);
  matches = [];
  for (const [el, x, bi, first, c] of blocks) {
    if (first >= end) break;
    if (first + c <= base) continue;
    re.lastIndex = 0;
    for (let n = first, m; n < end && (m = re.exec(x.s)); n++) {
      if (n >= base) matches.push({ el, x, bi, ord: n - first, start: m.index, end: m.index + m[0].length });
    }
  }
}
/** Where the kept matches are centred: the current match's block, else where a new search looks from (origin). */
function around() {
  if (pos) {
    const el = slots.get(pos.slot);
    if (el && el.isConnected) return { el, ord: pos.ord };
    const after = pos.next && slots.get(pos.next);
    if (after && after.isConnected) return { el: after, ord: 0 };
  }
  const sel = getSelection();
  const r = sel.rangeCount ? sel.getRangeAt(0) : null;
  const el = r && blockOf(r.startContainer);
  if (!el) return { el: blocksOnScreen()[0], ord: 0 };
  // In its block: the place of the first match at or after the selection's start (a block can hold more than KEPT).
  let x = texts.get(el);
  if (!x) texts.set(el, x = textOf(el));
  const { startContainer: n, startOffset: o } = r;
  let at = x.s.length;
  for (const [start, node, map] of x.segs) {
    if (node === n) { at = start + (map ? Math.max(0, map.findIndex(v => v >= o)) : o); break; }
    if (n.nodeType !== Node.TEXT_NODE && r.comparePoint(node, 0) >= 0) { at = start; break; }
  }
  let ord = 0;
  re.lastIndex = 0;
  for (let m; (m = re.exec(x.s)) && m.index < at;) ord++;
  return { el, ord };
}
/** Makes match number `n` of the document (wrapping) the current one, keeping those around it if they are not kept. */
function goTo(n) {
  n = (n % total + total) % total;
  if (n < base || n >= base + matches.length) search({ n });
  cur = n - base;
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

const blockOf = n => n && doc.contains(n) ? (n.nodeType === Node.ELEMENT_NODE ? n : n.parentElement).closest('#ro-doc > .chunk > .blk') : null;

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
  return [topNow(), false];
}
function fromTop(m) {
  const top = fromTop.top;
  return !top || m.el === top ? 0 : before(m.el, top) ? -1 : 1;
}
const topNow = () => { fromTop.top = blocksOnScreen()[0]; return fromTop; };

/**
 * The current match after a search of the page: [index, exact]. exact: in
 * its block still, the one nearest where it was in it. Else the
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
  if (matches[i]?.el !== el) return [i, false];
  delete pos.next;
  // In its block: the match nearest where it was, counted from the block's
  // start or from its end (text written before it moves it from the start,
  // text after it from the end); its place among the block's matches decides a tie.
  let best = i, far = Infinity;
  for (let k = i; k < matches.length && matches[k].el === el; k++) {
    const m = matches[k];
    const d = Math.min(Math.abs(m.start - pos.start), Math.abs(m.x.s.length - m.start - pos.fromEnd));
    if (d < far || (d === far && Math.abs(m.ord - pos.ord) < Math.abs(matches[best].ord - pos.ord))) { best = k; far = d; }
  }
  return [best, true];
}

/**
 * The first kept match `cmp` puts after its origin (`strict`: at it does
 * not count), `backwards` the last before it: matches.length and -1 past the kept ones (goTo wraps).
 */
function next(cmp, strict, backwards) {
  let lo = 0, hi = matches.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const c = cmp(matches[mid]);
    if (c > 0 || (!strict && c === 0)) hi = mid; else lo = mid + 1;
  }
  if (!backwards) return lo;
  // Backwards: the last match before the origin.
  lo = 0; hi = matches.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (cmp(matches[mid]) < 0) lo = mid + 1; else hi = mid; }
  return lo - 1;
}

// What is marked: the near matches (the current one among them) and the
// current one. WebKit repaints every mark of every highlight when one is set
// (300 near marks, 1 MB: about 100 ms), so each is set only when it changes:
// the near marks stay while the current match moves among them and they are
// the same text in the same text nodes (Return, an edit elsewhere). They are
// static ranges: with live ones, WebKit repaints them on every change of the
// page (an agent's edit anywhere, a block drawn as it comes near).
let near = null;      // {q, n, at: [[x, segs, start, end], ...]}: the query, the number of the first, and each match
let curMark = null;
const unmark = () => { near = curMark = null; if (HL) { CSS.highlights.delete('ro-find'); CSS.highlights.delete('ro-find-cur'); } };
const same = (m, [x, segs, start, end]) => !!m && m.x === x && x.segs === segs && m.start === start && m.end === end;
/** Where the near marks are in matches (a search may have renumbered them), -1 if they are not all as they were. */
function nearAt() {
  if (!near || near.q !== query) return -1;
  let k = near.n - base;
  if (!same(matches[k], near.at[0])) k = matches.findIndex(m => same(m, near.at[0]));
  return k >= 0 && near.at.every((a, i) => same(matches[k + i], a)) ? k : -1;
}
/** Marks the current match and those around it; returns the current one's range. */
function mark() {
  const m = matches[cur];
  if (!m) { unmark(); return null; }
  const range = rangeOf(m);
  if (!HL) return range;
  // Kept while they still reach NEAR / 2 blocks (or MARKED / 4 marks) past the current match either way.
  const lo = nearAt(), hi = lo + (near?.at.length ?? 0) - 1;
  const reach = (end, d) => Math.abs(end - cur) >= MARKED / 4 || Math.abs((matches[end + d]?.bi ?? Infinity) - m.bi) > NEAR / 2;
  if (lo < 0 || cur < lo || cur > hi || !reach(lo, -1) || !reach(hi, 1)) {
    let a = cur, b = cur;
    while (a > 0 && m.bi - matches[a - 1].bi <= NEAR && cur - a < MARKED / 2) a--;
    while (b + 1 < matches.length && matches[b + 1].bi - m.bi <= NEAR && b - a + 1 < MARKED) b++;
    const h = new Highlight();
    for (let i = a; i <= b; i++) h.add(new StaticRange(i === cur ? range : rangeOf(matches[i])));
    near = { q: query, n: base + a, at: matches.slice(a, b + 1).map(x => [x.x, x.x.segs, x.start, x.end]) };
    CSS.highlights.set('ro-find', h);
  }
  if (!sameRange(curMark, range)) CSS.highlights.set('ro-find-cur', new Highlight(curMark = new StaticRange(range)));
  return range;
}

function select(range) {
  const sel = getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  own = range;
}
const sameRange = (a, b) => !!a && !!b && a.startContainer === b.startContainer && a.startOffset === b.startOffset
  && a.endContainer === b.endContainer && a.endOffset === b.endOffset;
const isOwn = () => {
  const sel = getSelection();
  const r = sel.rangeCount ? sel.getRangeAt(0) : null;
  return sameRange(own, r);
};
// The reader selecting something else: the selection is theirs.
document.addEventListener('selectionchange', () => { if (own && !isOwn()) own = null; });

/**
 * The match landed on is selected once the frame showing it is painted (its
 * mark shows it until then): a change of the selection costs WebKit a check
 * of every element content-visibility can skip (a few hundred chunks).
 */
let selecting = null;   // the landing whose match is still to be selected
function selectLater() {
  const mine = selecting = {};
  requestAnimationFrame(() => setTimeout(() => { if (selecting === mine) selectNow(); }, 0));
}
function selectNow() {
  selecting = null;
  if (current()) select(rangeOf(matches[cur]));
}

/**
 * The page may have changed since the search (a long block's later lines
 * coloured in place of its plain text, an edit): the current match where it
 * is now, not at offsets into text that may have shrunk. False: it is gone.
 */
function current() {
  changed(observer.takeRecords());
  if (reread()) {
    search(around());
    const [i] = resolve();
    if (i < 0) { cur = -1; return false; }
    goTo(base + i);
    place();
    mark();
  }
  return !!matches[cur];
}

/** Tells the app the count (current 0: none yet): after every search, after an edit only when it changed. */
function report(always = false) {
  const current = cur < 0 ? 0 : base + cur + 1;
  const now = `${current}/${total}`;
  if (now === shown && !always) return;
  shown = now;
  post({ type: 'found', current, total });
}

/** Remembers where the current match is (pos). */
function place() {
  const m = matches[cur];
  pos = { slot: +m.el.dataset.slot, ord: m.ord, start: m.start, fromEnd: m.x.s.length - m.start };
}

/** To the current match (a search): selected, and on screen (it stays where it is if it is already). */
let colouring = null;   // cancels a landing waiting for its code to be coloured
let landing = null;     // that landing (a later one, or the search ended, drops it)
function land(waited = false) {
  const m = matches[cur];
  const el = m.el;
  // Its code highlighted before the match is selected in it (highlighting
  // replaces the text nodes): it waits for that (enhance.js), a moment. And
  // a folded <details> it is in opened.
  colouring?.();
  colouring = landing = null;
  if (!waited && el.querySelector('.code-block[data-hl="pending"]')) {
    // Where it is, kept meanwhile (pos): a refresh (an edit, other code
    // coloured) searches again, and the landing goes to the match found
    // there then, not the one it waited with. It waits for the lines up to
    // the match's and a screen below (a long block's first, the rest later:
    // what comes later goes in after them, the match's text left as it is).
    place();
    const mine = {};
    landing = mine;
    // The line it is on in its code (the lines up to it, and a screen more, are coloured first).
    const r = rangeOf(m), pre = r.startContainer.parentElement?.closest('pre');
    let line = 0;
    if (pre) { const before = document.createRange(); before.setStart(pre, 0); before.setEnd(r.startContainer, r.startOffset); line = before.toString().split('\n').length - 1; }
    colouring = whenColoured([el], () => {
      if (landing !== mine) return;
      landing = colouring = null;
      if (!observing || query == null) return;
      changed(observer.takeRecords());
      if (reread()) search(around());
      const [i] = resolve();
      if (i < 0) return;
      goTo(base + i);
      land(true);
    }, line);
    return;
  }
  let range = rangeOf(m);
  for (let d = range.startContainer.parentElement.closest('details'); d && el.contains(d); d = d.parentElement.closest('details')) {
    if (!d.open && !d.querySelector(':scope > summary')?.contains(range.startContainer)) d.open = true;
  }
  range = mark();
  place();
  selectLater();
  // Off screen in a large document, the block is not laid out
  // (content-visibility): it is aimed at first, the match once the frames
  // after the jump have laid it out. Otherwise the match at once (in long
  // code, the block's top would leave it screens below, with no frames after).
  const off = () => {
    // (Its text nodes replaced meanwhile: the lines after its code's first part coloured.)
    if (!range.startContainer.isConnected && current()) range = rangeOf(matches[cur]);
    const b = el.getBoundingClientRect();
    const r = (!cv() || (b.bottom > 0 && b.top < innerHeight)) && range.getClientRects().length ? range.getBoundingClientRect() : b;
    const inset = topInset();
    if (r.top >= inset + 8 && r.bottom <= innerHeight - 8) return 0;
    return r.top - inset - (innerHeight - inset) / 3;
  };
  aimAt(el, off, () => { noteLanding(el); pinLanding(el); }, (innerHeight + 2 * topInset()) / 3);
}

// While finding, an edit (an agent writing) is found in too: the count
// follows it. A block redrawn with the same text (its code highlighted, a
// formula or diagram drawn as it comes near) is not searched again: only
// where its text nodes are is.
const observer = new MutationObserver(records => { changed(records); later(); });
const stale = new Set();   // blocks changed since their text was read
let moved = false;         // blocks added, removed, hidden or shown since
function changed(records) {
  let emptied = null;   // the chunk the current match's block was alone in (removed with it)
  for (const r of records) {
    const items = r.target === doc || isChunk(r.target);
    if (items || r.type === 'attributes') moved = true;
    // The current match's block (or the one after it) removed: what followed it is where it was.
    if (pos && items) {
      for (const n of r.removedNodes) {
        const slot = n.dataset ? +n.dataset.slot : NaN;
        const gone = n === emptied;
        if (!gone && slot !== (pos.next ?? pos.slot)) continue;
        const el = x => x?.nodeType === Node.ELEMENT_NODE ? x : null;
        // Alone in its chunk: the chunk goes too (a later record), and what followed the chunk is where it was.
        if (!gone && isChunk(r.target) && !el(r.nextSibling) && !el(r.previousSibling)) { emptied = r.target; continue; }
        const next = el(r.nextSibling), prev = el(r.previousSibling);
        let after = next ? (isChunk(next) ? next.firstElementChild : next) : prev ? nextItem(isChunk(prev) ? prev.lastElementChild : prev) : null;
        while (after && !after.classList.contains('blk')) after = nextItem(after);
        pos.next = after ? +after.dataset.slot : 0;
      }
    }
    const e = r.target.nodeType === Node.ELEMENT_NODE ? r.target : r.target.parentElement;
    const blk = e && e !== doc && e.closest('#ro-doc > .chunk > .blk');
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
  if (reread()) search(around());
  const [i, exact] = resolve();
  if (i < 0) cur = -1; else goTo(base + i);
  if (exact) place();   // where it is now, for the next edit
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
  // Next and Previous go on from the current match, unless the reader has
  // selected something else since, or clicked somewhere (the caret).
  const sel = getSelection();
  const r = sel.rangeCount ? sel.getRangeAt(0) : null;
  const theirs = !!r && !selecting && !isOwn() && !!blockOf(r.startContainer);
  if (theirs) pos = null;
  search(around());
  if (!total) { cur = -1; pos = null; mark(); report(true); return 0; }
  const [i, exact] = same && !theirs ? resolve() : [-1, false];
  if (i < 0) { const [cmp, strict] = origin(); goTo(base + next(cmp, strict, backwards)); }
  else goTo(base + i + (backwards ? -1 : exact ? 1 : 0));
  land();
  report(true);
  return total;
}

/**
 * The search over: the marks go, the selection stays. `keep`: the find bar
 * is still open (its text edited), the blocks' text is kept for the next search.
 */
export function findEnd(keep = false) {
  colouring?.();
  colouring = landing = null;
  if (selecting) selectNow();
  query = null;
  clearTimeout(refreshTimer);
  refreshTimer = null;
  matches = [];
  base = total = 0;
  cur = -1;
  pos = null;
  shown = '';
  unmark();
  if (keep) return;
  observing = false;
  observer.disconnect();
  texts = new WeakMap();
  stale.clear();
  moved = false;
  own = null;
}
