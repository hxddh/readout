// What ⌘C (and a drag) puts on the clipboard: Markdown as plain text, clean
// HTML as rich text.
//
// Plain text is what an agent's prompt, a terminal or an editor pastes, so it
// is the document's Markdown: every block the selection covers whole is its
// source as written (the app sends it with the block, `op.src`: the copy event
// is synchronous); a block it covers in part is that part, written back as
// Markdown from the page's own HTML (a known subset: HTMLRenderer). A
// selection inside one code block, code span or formula copies just that code
// or TeX, as it always did. Rich text (Notes, Pages, Mail, Slack, Notion) is
// the selected HTML without the page's controls, panels and state.
import { doc, isChunk, itemOf, firstItem, lastItem, nextItem, prevItem, blockAfter } from './core.js';

/** block element -> its Markdown source (patch.js sets it from `op.src`). */
export const sources = new WeakMap();
/** Blocks that start on the line after the previous block (`op.tight`): no blank line between them. */
export const tight = new WeakSet();

// The document's link reference definitions (patch `links`): label (as
// references match it: case-folded, white space collapsed) -> the definition
// as written. Definitions are not blocks, so a copy appends those it uses.
let links = new Map();
export function setLinks(list) {
  links = new Map();
  for (const d of list || []) if (!links.has(d.label)) links.set(d.label, d.md);
}
const labelOf = s => s.trim().split(/[ \t\n]+/).join(' ').toLowerCase();

/**
 * The definitions `md`'s reference links (`[text][label]`, `[label]`) use,
 * in the order of their first use, but those it holds itself. ⌘C appends
 * them, and so does Copy as Quote (the app asks: `quoteSelection`).
 */
export function definitionsUsed(md) {
  const used = [];
  if (!links.size || !md.includes('[')) return used;
  const seen = new Set();
  for (const m of md.matchAll(/\[((?:\\.|[^[\]\\])+)\]/g)) {
    const label = labelOf(m[1]);
    if (label.startsWith('^') || seen.has(label)) continue;
    seen.add(label);
    const d = links.get(label);
    if (d && !md.includes(d)) used.push(d);
  }
  return used;
}

/** `md` and, after a blank line, the definitions it uses. */
function withDefinitions(md) {
  const used = definitionsUsed(md);
  return used.length ? md + '\n\n' + used.join('\n') : md;
}

// Page furniture: never content, never copied.
const CHROME = 'button, .cb-tools, .wd-panel, .del-pop, .del-mark, .katex-mathml';
// Content text the reader can select (formulas by their visible rendering).
function contentText(n) {
  if (!n.data.trim()) return false;
  const p = n.parentElement;
  return !!p && !p.closest(CHROME + ', .mermaid-src');
}

// ------------------------------------------------------------ Which blocks

/**
 * The document's blocks range `r` (inside the document: inDocument) reaches
 * into, in order. Found from the range's two ends: a range comparison costs
 * the node's index among its siblings, and a 5 MB document has 40 000 blocks.
 */
export function blocksIn(r) {
  const first = endBlock(r.startContainer, r.startOffset, false);
  const last = endBlock(r.endContainer, r.endOffset, true);
  const out = [];
  if (!first || !last) return out;
  for (let e = first; e; e = nextItem(e)) {
    if (e.classList.contains('blk')) out.push(e);
    if (e === last) break;
  }
  if (out.length && out[out.length - 1] !== last) return [];   // the ends out of order
  return out;
}

/**
 * The document's blocks the range touches with text, in order: those it
 * reaches into less any at its ends it holds no text of, the page's
 * controls left out (selectedSlots counts their text, and no block without
 * text at an end).
 */
function touchedBlocks(r) {
  const out = blocksIn(r);
  let i = 0, j = out.length;
  while (i < j && !coversText(r, out[i])) i++;
  while (j > i && !coversText(r, out[j - 1])) j--;
  return i === 0 && j === out.length ? out : out.slice(i, j);
}

/** The block a range end lies in, or the nearest one inside the range from that end. */
function endBlock(node, offset, atEnd) {
  const step = e => atEnd ? prevItem(e) : nextItem(e);
  let e;
  if (node === doc || isChunk(node)) {
    // Between two chunks, or two items of a chunk: the item on the range's side.
    let n = atEnd ? node.childNodes[offset - 1] : node.childNodes[offset];
    while (n && n.nodeType !== Node.ELEMENT_NODE) n = atEnd ? n.previousSibling : n.nextSibling;
    if (n && isChunk(n)) n = atEnd ? n.lastElementChild : n.firstElementChild;
    else if (!n && node === doc) return atEnd ? lastItem() : null;
    else if (!n) n = atEnd ? (node.firstElementChild ? prevItem(node.firstElementChild) : null) : (node.lastElementChild ? nextItem(node.lastElementChild) : null);
    e = n && itemOf(n);
  }
  else if (doc.contains(node)) e = itemOf(node);
  else if (node.contains(doc)) e = atEnd ? lastItem() : firstItem();
  else return null;
  // A removed-text marker or another child that is not a block: the next block inward.
  while (e && !e.classList.contains('blk')) e = step(e);
  return e;
}


/** The first or last content text position of `el`: [node, offset], or null. */
function textEdge(el, last) {
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, { acceptNode: n => contentText(n) ? 1 : 3 });
  let n = w.nextNode();
  if (last) for (let t; (t = w.nextNode());) n = t;
  if (!n) return null;
  const d = n.data;
  if (last) { let i = d.length; while (i > 0 && /\s/.test(d[i - 1])) i--; return [n, i]; }
  let i = 0; while (i < d.length && /\s/.test(d[i])) i++;
  return [n, i];
}

/** The part of `el` inside range `r`, as a range. */
export function partIn(r, el) {
  const part = document.createRange();
  part.selectNodeContents(el);
  if (r.compareBoundaryPoints(Range.START_TO_START, part) > 0) part.setStart(r.startContainer, r.startOffset);
  if (r.compareBoundaryPoints(Range.END_TO_END, part) < 0) part.setEnd(r.endContainer, r.endOffset);
  return part;
}

/** Whether the range holds some of the block's text (a block without text counts when inside). */
function coversText(r, el) {
  const box = partIn(r, el).cloneContents();
  box.querySelectorAll(CHROME).forEach(e => e.remove());
  if (box.textContent.trim() !== '') return true;
  // A block without text (a rule, an image, empty front matter) counts when the range holds all of it.
  if (textEdge(el, false)) return false;
  const whole = document.createRange();
  whole.selectNodeContents(el);
  return r.compareBoundaryPoints(Range.START_TO_START, whole) <= 0 && r.compareBoundaryPoints(Range.END_TO_END, whole) >= 0;
}

/** Whether the range holds all of the block's text. */
function coversAll(r, el) {
  const a = textEdge(el, false);
  if (!a) return true;
  const z = textEdge(el, true);
  return r.comparePoint(a[0], a[1]) === 0 && r.comparePoint(z[0], z[1]) === 0;
}

// ------------------------------------------------------------ The text

/**
 * `r` cut to the document when it reaches outside it (Edit ▸ Select All
 * selects the whole page: the toolbar, the notices); null when it holds
 * nothing of the document.
 */
export function inDocument(r) {
  const c = r.commonAncestorContainer;
  if (c === doc || doc.contains(c) || !c.contains(doc)) return r;
  const out = r.cloneRange();
  const whole = document.createRange();
  whole.selectNodeContents(doc);
  if (out.compareBoundaryPoints(Range.START_TO_START, whole) < 0) out.setStart(doc, 0);
  if (out.compareBoundaryPoints(Range.END_TO_END, whole) > 0) out.setEnd(doc, doc.childNodes.length);
  return out.collapsed ? null : out;
}

/**
 * The Markdown for a selection range; null when the page leaves the copy to
 * the browser (a selection inside an open comparison or removed-text panel).
 */
export function markdownOf(r) {
  let within = r.commonAncestorContainer;
  if (within.nodeType !== Node.ELEMENT_NODE) within = within.parentElement;
  if (!within || !doc.contains(within) || within.closest('.wd-panel, .del-pop')) return null;
  const blocks = touchedBlocks(r);
  if (!blocks.length) return null;
  if (blocks.length === 1) {
    const b = blocks[0];
    // Inside one code block, code span or formula: the code or the TeX.
    const math = within.closest('.math, .math-block, .math-display');
    if (math) return texOf(math, true);
    if (within.closest('pre, code') && !within.closest('.mermaid-block')) return r.toString();
    if (!coversAll(r, b)) return withDefinitions(partial(r, b, true));
  }
  let out = '';
  let prev = null;
  const lastBlock = blocks[blocks.length - 1];
  for (const b of blocks) {
    // Blocks between the first and the last are whole: only the ends are measured.
    const whole = (b !== blocks[0] && b !== lastBlock) || coversAll(r, b);
    const text = whole ? (sources.get(b) ?? convertBlock(b, b)) : partial(r, b, false);
    if (text === '') continue;
    if (prev) out += (sources.has(b) ? tight.has(b) && blockAfter(b, prevItem) === prev : tightAfter(prev, b)) ? '\n' : '\n\n';
    out += text;
    prev = b;
  }
  return withDefinitions(out);
}

/** Items of one tight list follow each other on the next line; everything else after a blank line. */
function tightAfter(a, b) {
  const la = a.firstElementChild, lb = b.firstElementChild;
  return a.classList.contains('k-listItem') && b.classList.contains('k-listItem')
    && la && lb && la.classList.contains('li-block') && lb.classList.contains('li-block')
    && !la.classList.contains('li-last') && !lb.classList.contains('li-first')
    && !la.classList.contains('li-loose') && la.tagName === lb.tagName;
}

/** The part of block `b` inside the range, as Markdown. */
function partial(r, b, alone) {
  // Front matter is copied whole unless the selection lies inside it.
  if (b.classList.contains('k-frontMatter')) return alone ? r.toString() : (sources.get(b) ?? convertBlock(b, b));
  const part = partIn(r, b);
  let within = part.commonAncestorContainer;
  if (within.nodeType !== Node.ELEMENT_NODE) within = within.parentElement;
  const box = document.createElement('div');
  box.appendChild(part.cloneContents());
  box.querySelectorAll(CHROME).forEach(e => e.remove());
  // A run of text in one paragraph, heading, item or cell: inline Markdown,
  // without the block's own marker when it is all that is copied.
  const leaf = within.closest('p, h1, h2, h3, h4, h5, h6, td, th, li, summary');
  if (alone && leaf && !box.querySelector(BLOCKS + ', li')) return literal(unmark(inline(box).trim()));
  // Items of one nested list (sub-points of an item): that list, on its own.
  if (alone && within.matches('ul, ol') && within.parentElement.closest('li')) {
    const shell = within.cloneNode(false);
    shell.append(...box.childNodes);
    return literal(list(shell, b));
  }
  // Part of a table: the rows it touches, whole, under the table's header.
  const t = b.querySelector('table');
  if (t && b.classList.contains('k-table')) {
    const rows = [...t.querySelectorAll('tbody tr')].filter(tr => r.intersectsNode(tr));
    const copy = document.createElement('table');
    copy.appendChild(document.createElement('tbody')).append(...rows.map(tr => tr.cloneNode(true)));
    return literal(table(copy, b));
  }
  // An item keeps the marker its source wrote (`*`, `7)`): a different one starts another list.
  hint = b.classList.contains('k-listItem') ? /^(?:[-*+]|\d{1,9}[.)])/.exec(sources.get(b) || '')?.[0] : null;
  // Otherwise the part keeps its block's form: it is wrapped in the
  // containers it was cut from (a heading's #, an item's marker, a quote's >).
  for (let e = within; e && e !== b; e = e.parentElement) {
    if (!e.matches(BLOCKS + ', li, thead, tbody, tr')) continue;
    const shell = e.cloneNode(false);
    shell.append(...box.childNodes);
    box.appendChild(shell);
  }
  try { return convertBlock(box, b); } finally { hint = null; }
}
let hint = null;

// ------------------------------------------------------------ HTML to Markdown

const BLOCKS = 'p, h1, h2, h3, h4, h5, h6, blockquote, ul, ol, pre, table, hr, div, section, details, figure, dl';
const isBlock = n => n.nodeType === Node.ELEMENT_NODE && n.matches(BLOCKS + ', li, thead, tbody, tr, summary');

/** Markdown for the content of `el` (a block, or a clone of part of one); `orig` is the block it came from. */
function convertBlock(el, orig) {
  return literal(chunks(el, orig).join('\n\n'));
}

function chunks(parent, orig, tight = false) {
  const out = [];
  let run = '';
  const flush = () => { const t = unmark(run.replace(/^[ \t]*\n+|\s+$/g, '').replace(/^[ \t]+/, '')); if (t) out.push(t); run = ''; };
  for (const n of parent.childNodes) {
    if (n.nodeType === Node.ELEMENT_NODE && n.matches(CHROME)) continue;
    if (isBlock(n)) { flush(); const s = block(n, orig); if (s !== '') out.push(s); } else run += inl(n);
  }
  flush();
  return tight ? [out.join('\n')] : out;
}

function block(n, orig) {
  const tag = n.tagName;
  const cls = n.classList;
  if (/^H[1-6]$/.test(tag)) return '#'.repeat(+tag[1]) + ' ' + inline(n).trim().replace(/\n/g, ' ');
  switch (tag) {
    case 'P': return cls.contains('alert-title') ? '' : unmark(inline(n).trim());
    case 'BLOCKQUOTE': return quote(convertBlock(n, orig));
    case 'UL': case 'OL': return list(n, orig);
    case 'LI': return list(document.createElement('ul'), orig, [n]);
    case 'PRE': return fence(n.textContent, n.closest('.code-block')?.dataset.lang || '');
    case 'TABLE': return table(n, orig);
    case 'THEAD': case 'TBODY': case 'TR': { const t = document.createElement('table'); t.appendChild(n.cloneNode(true)); return table(t, orig); }
    case 'HR': return '---';
    case 'DETAILS': {
      const s = n.querySelector(':scope > summary') || orig.querySelector?.('details > summary');
      const rest = [...n.childNodes].filter(c => c.tagName !== 'SUMMARY');
      const box = document.createElement('div'); box.append(...rest.map(c => c.cloneNode(true)));
      return `<details>\n<summary>${s ? inline(s).trim() : ''}</summary>\n\n${convertBlock(box, orig)}\n\n</details>`;
    }
    case 'SUMMARY': return inline(n).trim();
    case 'SECTION':
      if (cls.contains('footnotes')) {
        return [...n.querySelectorAll('li')].map(li => {
          const id = (li.id || '').replace(/^user-content-fn-/, '') || '?';
          return `[^${decodeURIComponent(id)}]: ` + indent(convertBlock(li, orig), '    ');
        }).join('\n');
      }
      break;
    case 'DIV':
      if (cls.contains('code-block')) return fence(n.querySelector('pre')?.textContent ?? '', n.dataset.lang || '');
      if (cls.contains('math-block') || cls.contains('math-display')) return texOf(n, false);
      if (cls.contains('mermaid-block')) return fence(n.querySelector('.mermaid-src')?.textContent ?? '', 'mermaid');
      if (cls.contains('alert')) {
        const kind = [...cls].find(c => c.startsWith('alert-'))?.slice(6).toUpperCase() || 'NOTE';
        const body = convertBlock(n, orig);
        return quote(`[!${kind}]` + (body ? '\n' + body : ''));
      }
      if (cls.contains('front-matter')) {
        const items = [...n.querySelectorAll('.fm-item')].map(i => {
          const k = i.querySelector('.fm-key')?.textContent ?? '';
          const v = [...i.childNodes].filter(c => !(c.classList && c.classList.contains('fm-key'))).map(c => c.textContent).join('').trim();
          return `${k}: ${v}`;
        });
        return items.length ? '---\n' + items.join('\n') + '\n---' : '';
      }
      break;
  }
  return convertBlock(n, orig);
}

function list(n, orig, only) {
  const ordered = n.tagName === 'OL';
  let num = +(n.getAttribute('start') || 1);
  const items = only || [...n.children].filter(c => c.tagName === 'LI');
  const loose = n.classList.contains('li-loose') || items.some(li => li.querySelector(':scope > p'));
  const own = n.classList.contains('li-block') && hint;
  const out = items.map(li => {
    const box = li.querySelector(':scope > .task-box');
    const marker = own ? (ordered ? `${num++}${hint.slice(-1)} ` : `${hint} `) : (ordered ? `${num++}. ` : '- ');
    const task = box ? (box.classList.contains('checked') ? '[x] ' : '[ ] ') : '';
    const body = chunks(li, orig).join(loose ? '\n\n' : '\n');
    return marker + task + indent(body, ' '.repeat(marker.length));
  });
  return out.join(loose ? '\n\n' : '\n');
}

function table(t, orig) {
  const rowsOf = el => [...el.querySelectorAll('tr')].map(tr => [...tr.children].map(c => inline(c).trim().replace(/\n/g, ' ').replace(/\|/g, '\\|')));
  let head = t.querySelector('thead');
  // A part of a table that left out its header row borrows it: a table needs one.
  if (!head) head = orig.querySelector?.('thead');
  const headRows = head ? rowsOf(head) : [];
  const ths = head ? [...head.querySelectorAll('th')] : [];
  const bodyRows = [...t.querySelectorAll('tbody tr')].length ? rowsOf(t.querySelector('tbody') || t) : (t.querySelector('thead') ? [] : rowsOf(t));
  const header = headRows[0] || (bodyRows[0] || []).map(() => '');
  const cols = Math.max(header.length, ...bodyRows.map(r => r.length));
  const align = i => {
    const a = ths[i]?.style.textAlign;
    return a === 'center' ? ':---:' : a === 'right' ? '---:' : a === 'left' ? ':---' : '---';
  };
  const row = cells => '| ' + Array.from({ length: cols }, (_, i) => cells[i] ?? '').join(' | ') + ' |';
  return [row(header), '| ' + Array.from({ length: cols }, (_, i) => align(i)).join(' | ') + ' |', ...bodyRows.map(row)].join('\n');
}

function fence(code, lang) {
  code = code.replace(/\n$/, '');
  const run = Math.max(2, ...(code.match(/`+/g) || []).map(s => s.length));
  const f = '`'.repeat(run + 1);
  return `${f}${lang}\n${code}\n${f}`;
}

/** The TeX a KaTeX rendering keeps in its MathML (undefined: none). */
const annotation = k => k.querySelector('annotation[encoding="application/x-tex"]')?.textContent;

function texOf(m, wrapInline) {
  const tex = m.dataset.tex ?? annotation(m) ?? m.textContent;
  const display = m.matches('.math-block, .math-display');
  if (display) return wrapInline ? `$$${tex}$$` : `$$\n${tex}\n$$`;
  return `$${tex}$`;
}

const quote = s => s.split('\n').map(l => l ? '> ' + l : '>').join('\n');
const indent = (s, pad) => s.replace(/\n(?!\n|$)/g, '\n' + pad).replace(/\n\n(?=\S)/g, '\n\n' + pad);

// ------------------------------------------------------------ Inline

function inline(el) {
  let s = '';
  for (const n of el.childNodes) s += isBlock(n) ? '\n' + block(n, el) + '\n' : inl(n);
  return s;
}

/** Text that would start a block where it starts a line (`22) `, `- `, `# `, `> `, `===`) keeps reading as text. */
function unmark(s) {
  return s.replace(/^([ \t]*)(?:(\d{1,9})([.)])(?=[ \t]|$)|([-+](?=[ \t]|$)|-(?=-*[ \t]*$)|=(?==*[ \t]*$))|(#{1,6})(?=[ \t]|$)|(>))/gm,
    (m, sp, num, delim, bullet, hash, gt) => sp + (num ? num + '\\' + delim : bullet ? '\\' + bullet : hash ? '\\' + hash : '\\>'));
}

function escapeText(t) {
  // `<` that could open a tag or an autolink, `&` that could be an entity: as text.
  // `]`, `!`, `~`, `$` and a last `<` are Markdown only by what follows them: marked (literal() decides).
  return t.replace(/[\\`*]/g, '\\$&').replace(/<(?=[A-Za-z\/!?])/g, '\\<').replace(/&(?=#?\w+;)/g, '\\&').replace(/(^|[^\p{L}\p{N}])_|_(?=$|[^\p{L}\p{N}])/gu, m => m.replace('_', '\\_')).replace(/[\]!~$]|<$/g, MAYBE + '$&');
}

// Before a text character that is Markdown only in context (escapeText);
// a noncharacter, never in a document.
const MAYBE = '\uFDD0';

/**
 * `s` with its marked characters escaped where they would be Markdown, and
 * as they are elsewhere (copies stay clean): `]` before `(` or `[` (a link),
 * `!` before `[` (an image), `~` with another in the run (strikethrough),
 * `$` where Readout opens math (MathProtector), `<` before a tag or address
 * (a link the page made of text after it).
 */
function literal(s) {
  if (!s.includes(MAYBE)) return s;
  // An escaped `$` moves where a later one closes: again until none opens.
  for (let more = true; more;) {
    more = false;
    s = s.replace(/\uFDD0\$/g, (m, i, t) => opensMath(t, i + 2) ? (more = true, '\\$') : m);
  }
  return s.replace(/\uFDD0([\]!~$<])/g, (m, c, i, t) => {
    const next = t[i + 2] === MAYBE ? t[i + 3] : t[i + 2];
    if (c === ']') return next === '(' || next === '[' ? '\\]' : c;
    if (c === '!') return next === '[' ? '\\!' : c;
    if (c === '<') return /[A-Za-z\/!?]/.test(next || '') ? '\\<' : c;
    if (c === '~') {
      const later = t.indexOf('~', i + 2), end = t.indexOf('\n\n', i);
      return (t[i - 1] === '~' && t[i - 2] !== MAYBE) || (later >= 0 && (end < 0 || later < end)) ? '\\~' : c;
    }
    return c;
  });
}

/** Whether the `$` before `t[k]` opens inline math: `$$`, or GitHub's strict `$x$` on one line. */
function opensMath(t, k) {
  const at = j => t[j] === MAYBE ? t[j + 1] : t[j];
  const c = at(k);
  if (c === '$') return true;
  if (c === undefined || /\s/.test(c)) return false;
  for (let j = k; j < t.length && t[j] !== '\n'; j++) {
    if (t[j] === '\\') { j++; continue; }
    if (t[j] !== '$') continue;
    const prev = t[j - 1] === MAYBE ? t[j - 2] : t[j - 1], next = at(j + 1);
    return !/\s/.test(prev) && !(next && /\p{N}/u.test(next)) && next !== '$';
  }
  return false;
}

function wrap(mark, inner) {
  const m = inner.match(/^(\s*)([\s\S]*?)(\s*)$/);
  return m[2] ? `${m[1]}${mark}${m[2]}${mark}${m[3]}` : inner;
}

function codeSpan(text) {
  if (!text) return '';
  const run = Math.max(0, ...(text.match(/`+/g) || []).map(s => s.length));
  const f = '`'.repeat(run + 1);
  const pad = text.startsWith('`') || text.endsWith('`') || (run && /^ | $/.test(text)) ? ' ' : '';
  return f + pad + text + pad + f;
}

function inl(n) {
  if (n.nodeType === Node.TEXT_NODE) return escapeText(n.data);
  if (n.nodeType !== Node.ELEMENT_NODE) return '';
  const cls = n.classList;
  if (n.matches(CHROME) || cls.contains('task-box') || cls.contains('mermaid-src')) return '';
  if (cls.contains('math')) return texOf(n, true);
  if (cls.contains('katex')) { const tex = annotation(n); return tex != null ? `$${tex}$` : ''; }
  if (cls.contains('remote-img')) return `![${n.dataset.alt || ''}](${n.dataset.src || ''})`;
  if (cls.contains('fm-key')) return n.textContent + ':';
  switch (n.tagName) {
    case 'EM': case 'I': return wrap('*', inline(n));
    case 'STRONG': case 'B': return wrap('**', inline(n));
    case 'DEL': case 'S': return wrap('~~', inline(n));
    case 'CODE': return codeSpan(n.textContent);
    case 'BR': return '\n';
    case 'WBR': return '';
    case 'IMG': {
      const title = n.getAttribute('title');
      return `![${n.getAttribute('alt') || ''}](${n.getAttribute('src') || ''}${title ? ` "${title}"` : ''})`;
    }
    case 'A': {
      if (n.hasAttribute('data-footnote-backref')) return '';
      const href = n.getAttribute('href') || '';
      if (n.hasAttribute('data-footnote-ref')) return `[^${decodeURIComponent(href.replace(/^#user-content-fn-/, ''))}]`;
      const text = inline(n);
      const bare = text.replaceAll(MAYBE, '');
      if (bare === href || 'mailto:' + bare === href || 'http://' + bare === href) return bare;
      // The page titles links with their address (a tooltip): not the source's title.
      const title = n.getAttribute('title') === href ? null : n.getAttribute('title');
      return `[${text}](${/[\s()]/.test(href) ? `<${href}>` : href}${title ? ` "${title.replace(/"/g, '\\"')}"` : ''})`;
    }
    case 'SUP':
      if (cls.contains('fn-ref')) return inline(n);
      return `<sup>${inline(n)}</sup>`;
    case 'SUB': case 'KBD': case 'MARK': case 'INS': case 'U': case 'SMALL': case 'ABBR': {
      const t = n.tagName.toLowerCase();
      return `<${t}>${inline(n)}</${t}>`;
    }
  }
  return inline(n);
}

// ------------------------------------------------------------ Rich text

/**
 * The range as clean HTML: the page's blocks without its controls,
 * panels, marks and state; math as its TeX; task boxes as [ ] and [x];
 * alerts as quotes with their title; diagrams as their source; highlighted
 * code in its light colours. Safe to paste (`safeHTML`).
 */
export function htmlOf(range) {
  const box = document.createElement('div');
  box.appendChild(range.cloneContents());
  let within = range.commonAncestorContainer;
  if (within.nodeType !== Node.ELEMENT_NODE) within = within.parentElement;
  const math = within && within.closest('.math, .math-block, .math-display');
  if (math) box.replaceChildren(math.cloneNode(true));
  box.querySelectorAll('.wd-panel, .del-pop, .del-mark, button, .cb-tools').forEach(e => e.remove());
  // Where a path in a table may break (enhance.js: <wbr>) is the page's, not the text's.
  box.querySelectorAll('wbr').forEach(e => e.remove());
  for (const m of box.querySelectorAll('.mermaid-block')) {
    const pre = document.createElement('pre');
    pre.appendChild(document.createElement('code')).textContent = m.querySelector('.mermaid-src')?.textContent ?? '';
    m.replaceWith(pre);
  }
  for (const m of box.querySelectorAll('.math, .math-block, .math-display')) {
    if (!box.contains(m)) continue;
    m.replaceWith(texOf(m, true));
  }
  for (const k of box.querySelectorAll('.katex')) { const tex = annotation(k); k.replaceWith(tex != null ? `$${tex}$` : ''); }
  for (const t of box.querySelectorAll('.task-box')) t.replaceWith(t.classList.contains('checked') ? '[x] ' : '[ ] ');
  box.querySelectorAll('[data-footnote-backref]').forEach(e => e.remove());
  for (const a of box.querySelectorAll('[data-footnote-ref]')) (a.closest('sup') || a).replaceWith(`[${a.textContent.trim()}]`);
  for (const a of box.querySelectorAll('.alert')) {
    const q = document.createElement('blockquote');
    const title = a.querySelector(':scope > .alert-title');
    if (title) { const p = document.createElement('p'); const b = document.createElement('strong'); b.textContent = title.textContent; p.appendChild(b); title.replaceWith(p); }
    q.append(...a.childNodes);
    a.replaceWith(q);
  }
  // Shiki colours are custom properties the destination does not have.
  for (const e of box.querySelectorAll('[style*="--shiki-light"]')) {
    const m = /--shiki-light:\s*(#[0-9a-fA-F]{3,8})/.exec(e.getAttribute('style'));
    const bg = /--shiki-light-bg:\s*(#[0-9a-fA-F]{3,8})/.exec(e.getAttribute('style'));
    e.setAttribute('style', (m ? `color:${m[1]};` : '') + (bg ? `background-color:${bg[1]};` : ''));
  }
  for (const r of box.querySelectorAll('.remote-img')) {
    const a = document.createElement('a');
    a.href = r.dataset.src || '';
    a.textContent = r.dataset.alt || r.dataset.src || '';
    r.replaceWith(a);
  }
  // Front matter: a table of its keys and values (its spans would run together, "title Planstatus draft").
  for (const f of box.querySelectorAll('.front-matter')) {
    const table = document.createElement('table'), body = table.appendChild(document.createElement('tbody'));
    for (const i of f.querySelectorAll('.fm-item')) {
      const row = body.appendChild(document.createElement('tr'));
      row.appendChild(document.createElement('td')).textContent = i.querySelector('.fm-key')?.textContent ?? '';
      // The value's text, its line breaks (a literal block's <br>) kept.
      const cell = row.appendChild(document.createElement('td'));
      const parts = [];
      for (const c of i.childNodes) {
        if (c.classList && c.classList.contains('fm-key')) continue;
        const w = document.createTreeWalker(c, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        for (let n = w.currentNode; n; n = w.nextNode()) {
          if (n.nodeType === Node.TEXT_NODE) parts.push(n.data);
          else if (n.tagName === 'BR') parts.push('\n');
        }
      }
      parts.join('').trim().split('\n').forEach((line, k) => { if (k) cell.appendChild(document.createElement('br')); cell.append(line); });
    }
    if (body.rows.length) f.replaceWith(table); else f.remove();
  }
  for (const b of box.querySelectorAll('.chunk, .blk')) b.replaceWith(...b.childNodes);
  box.querySelectorAll('[tabindex]').forEach(e => e.removeAttribute('tabindex'));
  safeHTML(box);
  return box.innerHTML;
}

// Pasted HTML runs nowhere and loads nothing: no scripts, embeds or media,
// no attribute but a few that carry content, links only to the web, mail
// or a place in the text. (On macOS WebKit writes it to the pasteboard with
// its own default inline styles added: smoke run.)
const DROP = 'script, style, link, meta, base, iframe, frame, object, embed, svg, math, video, audio, source, track, canvas, form, input, textarea, select, button, template, noscript';
const KEEP_ATTRS = new Set(['href', 'colspan', 'rowspan', 'start', 'style']);
const KEEP_STYLES = ['color', 'background-color', 'text-align'];
const safeHref = h => { const t = h.replace(/[\u0000-\u0020\u007f]+/g, ''); return /^(?:https?:|mailto:|#)/i.test(t) ? h : null; };

/** Makes `box`'s content safe to paste, in place. */
function safeHTML(box) {
  box.querySelectorAll(DROP).forEach(e => e.remove());
  for (const p of box.querySelectorAll('picture')) p.replaceWith(...p.childNodes);
  // An image: a link to it on the web, else its description.
  for (const img of box.querySelectorAll('img')) {
    const src = img.getAttribute('src') || '', alt = img.getAttribute('alt') || '';
    if (/^https?:/i.test(src.trim())) {
      const a = document.createElement('a');
      a.setAttribute('href', src.trim());
      a.textContent = alt || src.trim();
      img.replaceWith(a);
    } else img.replaceWith(alt);
  }
  for (const e of box.querySelectorAll('*')) {
    for (const { name } of [...e.attributes]) if (!KEEP_ATTRS.has(name)) e.removeAttribute(name);
    if (e.hasAttribute('href') && (e.tagName !== 'A' || safeHref(e.getAttribute('href')) == null)) e.removeAttribute('href');
    if (e.hasAttribute('style')) {
      const kept = KEEP_STYLES.map(p => [p, e.style.getPropertyValue(p)]).filter(([, v]) => v && !/url\(|expression/i.test(v));
      if (kept.length) e.setAttribute('style', kept.map(([p, v]) => `${p}:${v}`).join(';'));
      else e.removeAttribute('style');
    }
  }
}
