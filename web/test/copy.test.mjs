// What ⌘C puts on the clipboard, in WebKit, over the whole corpus.
//
// 1. Select All, Copy: the plain text is the document's Markdown. Compared
//    with the file line by line, modulo the documented normalisations
//    (normalise() below); and how many documents are exact to the byte.
// 2. Every block copied whole is its source, byte for byte.
// 3. Every partial selection (inside a block, and from the middle of one
//    block to the middle of the block after next) copies valid Markdown:
//    rendered again (marked, GFM) it has the selection's text and the same
//    inline formatting (strong, em, code, links, struck).
// 4. A selection inside a code block, a code span or a formula copies the
//    code or the TeX only; rich text is clean HTML (no controls, no state).
// 5. fixtures/copy-cases.md (every construct, ReadoutCore's patch in
//    copy-cases.json; regenerate with readout-dump): Select All is the file
//    to the byte but for the documented normalisations; each defect of the
//    3.8 audit (C2) by name; rich text always the clean HTML (C3); the link
//    definitions a copy uses appended (C5); a drag carries the same (C8);
//    Edit ▸ Select All copies the document; escaped text stays text.
//    5b: a source-only edit (copy-edit.json); 5c: safe rich text (copy-unsafe.json).
// 6. A large selection (C7): ~650,000 characters copy in well under a second, as
//    Markdown only (rich text is skipped above 100,000 characters, F8).
// 7. Random selections (B1, B4): two seeded random text positions over any
//    blocks, in every document and fixtures/copy-escapes.md; each copy parsed
//    again by ReadoutCore (readout-dump) reads as the selection did.
//    COPY_FUZZ selections per document (default 8; 12 times that on copy-escapes).
//
// Partial and cross-block selections are tried on every STRIDE-th block
// (default 3, bounded for CI); COPY_STRIDE=1 tries every block.
// Usage: node test/copy.test.mjs [--quick]
import { launchBrowser } from './engine.mjs';
import http from 'node:http';
import { readFileSync, existsSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { extname, join } from 'node:path';
import { marked } from 'marked';
import { collectPageErrors } from './pageerrors.mjs';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const CORPUS = 'test/corpus';
const quick = process.argv.includes('--quick');
const STRIDE = Math.max(1, +(process.env.COPY_STRIDE || 3));
const docs = readdirSync(`${CORPUS}/patches`).filter(f => f.endsWith('.json')).sort();

let failures = 0;
const fail = (msg) => { failures++; console.log('FAIL', msg); };

/**
 * The file as Select All copies it. Normalisations, all of them Markdown
 * that renders the same:
 *  - trailing white space on a line is compared without (copies keep it: fixture checks below)
 *  - blank lines: one between blocks, none between items of a tight list
 *  - link reference definitions are not blocks: those used come last (fixture checks below)
 *  - footnote definitions come last, in the order they are referenced
 *  - HTML comments between blocks are not copied (they are not blocks)
 * Compared as the sequence of non-blank lines; blank lines are counted apart.
 */
function normalise(md) {
  const lines = md.replace(/\r\n?/g, '\n').split('\n').map(l => l.replace(/[ \t]+$/, ''));
  const out = [];
  let fence = null, inComment = false;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const f = /^ {0,3}(`{3,}|~{3,})/.exec(l.replace(/^(?:\s*>\s?)+/, ''));
    if (fence) { if (f && f[1][0] === fence[0] && f[1].length >= fence.length && !/\S/.test(l.replace(/^(?:\s*>\s?)+/, '').trim().slice(f[1].length))) fence = null; out.push(l); continue; }
    if (f) { fence = f[1]; out.push(l); continue; }
    if (inComment) { if (l.includes('-->')) inComment = false; continue; }
    if (/^\s{0,3}<!--/.test(l) && (out.length === 0 || out[out.length - 1] === '')) { if (!l.includes('-->')) inComment = true; continue; }
    if (/^ {0,3}\[\^[^\]]+\]:/.test(l)) {   // footnote definition and its continuation
      while (i + 1 < lines.length && (/^(?: {4}|\t)/.test(lines[i + 1]) || (lines[i + 1] !== '' && !/^\s{0,3}(?:\[\^|#|[-*+] |\d+[.)] |>|```|~~~|\|)/.test(lines[i + 1])) || (lines[i + 1] === '' && /^(?: {4}|\t)/.test(lines[i + 2] || '')))) i++;
      continue;
    }
    if (/^ {0,3}\[[^\]^][^\]]*\]:\s*\S/.test(l)) continue;   // link reference definition
    out.push(l);
  }
  return out;
}
const nonBlank = ls => ls.filter(l => l.trim() !== '');

const browser = await launchBrowser();
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
const errors = [];
collectPageErrors(page, errors);
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));

// In the page: copy a range; return what the clipboard got.
await page.evaluate(() => {
  window.__copy = range => {
    const out = {};
    const grab = e => { out.text = e.clipboardData.getData('text/plain'); out.html = e.clipboardData.getData('text/html'); out.handled = e.defaultPrevented; };
    window.addEventListener('copy', grab);
    getSelection().removeAllRanges(); getSelection().addRange(range);
    out.selected = getSelection().toString();
    document.execCommand('copy');
    window.removeEventListener('copy', grab);
    return out;
  };
  // n random selections (two text positions, any blocks; seeded): what each selects and copies.
  window.__fuzz = (n, seed) => {
    let s = seed >>> 0;
    const rnd = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2 ** 32; };
    // Left out, by design: code, formulas, diagrams and front matter copy their source, footnotes their definitions.
    const skip = 'button, .cb-tools, code, pre, .katex, .math, .math-block, .math-display, .mermaid-block, .front-matter, .wd-panel, .del-pop, .del-mark, .k-footnotes, .fn-ref, details, .alert-title';
    const w = document.createTreeWalker(document.getElementById('ro-doc'), NodeFilter.SHOW_TEXT, { acceptNode: t => t.data.length && !t.parentElement.closest(skip) && t.parentElement.getClientRects().length ? 1 : 3 });
    const nodes = []; for (let t; (t = w.nextNode());) nodes.push(t);
    const out = [];
    for (let i = 0; nodes.length > 1 && i < n; i++) {
      const x = Math.floor(rnd() * nodes.length), y = Math.min(nodes.length - 1, x + (rnd() < 0.5 ? 0 : Math.floor(rnd() * 12)));
      const a = nodes[x], z = nodes[y];
      const ao = Math.floor(rnd() * (a.data.length + 1));
      const zo = x === y ? ao + Math.floor(rnd() * (z.data.length - ao + 1)) : Math.floor(rnd() * (z.data.length + 1));
      const r = document.createRange(); r.setStart(a, ao); r.setEnd(z, zo);
      if (/[\uDC00-\uDFFF]/.test(a.data[ao] || '') || /[\uDC00-\uDFFF]/.test(z.data[zo] || '')) continue;   // half a character
      const box = document.createElement('div'); box.appendChild(r.cloneContents());
      if (r.collapsed || box.querySelector(skip)) continue;
      const c = window.__copy(r);
      // A part of a table copies the rows it touches, whole.
      if (c.selected.trim() && !r.commonAncestorContainer.parentElement?.closest('table')) out.push({ selected: c.selected, text: c.text });
    }
    return out;
  };
  // A position `frac` of the way through an element's visible text.
  window.__point = (el, frac) => {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, { acceptNode: n => n.data.trim() && !n.parentElement.closest('button, .cb-tools, .katex-mathml, .mermaid-src, .front-matter') && n.parentElement.getClientRects().length ? 1 : 3 });
    const nodes = []; let total = 0;
    for (let n; (n = w.nextNode());) { nodes.push(n); total += n.data.length; }
    if (!total) return null;
    let at = Math.max(1, Math.floor(total * frac));
    for (const n of nodes) { if (at < n.data.length) return [n, at]; at -= n.data.length; }
    return null;
  };
});

// The text a reader sees in rendered Markdown, and its inline formatting.
function shape(html) {
  const counts = {};
  for (const t of ['strong', 'em', 'code', 'a', 'del']) counts[t] = (html.match(new RegExp(`<${t}(?:\\s[^>]*)?>(?!</${t}>)`, 'g')) || []).length;
  return counts;
}
const entities = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", nbsp: ' ' };
// The words of rendered HTML (tags out, entities decoded) and of the plain text selected (as it is).
const textWords = s => s.replace(/\[!(\w+)\]/g, '').replace(/\b(note|tip|important|warning|caution)\b/gi, '').toLowerCase().replace(/[\s​]+/g, ' ').replace(/[*_`~\\[\]()|>#$-]/g, '').replace(/\s+/g, '').trim();
const words = html => textWords(html.replace(/<[^>]+>/g, ' ').replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (_, e) => entities[e]));

// Random selections for 7: what they select and copy, without a table's rows (copied whole, by design).
const FUZZ = Math.max(0, +(process.env.COPY_FUZZ ?? 8));
const copies = [];
const fuzz = (doc, got) => { for (const c of got) if (!/^(?:> ?)*\|.*\|$/m.test(c.text)) copies.push({ doc, ...c }); };

let exact = 0, structural = 0, blankDiffs = 0, partials = 0, wholes = 0;
// The break opportunities ReadoutCore puts in a long URL (<wbr>) are the page's, not the text's.
const carriesBreaks = c => /<wbr/i.test(c.html || '') || /[\u200b\u00ad]/.test(c.text || '');
for (const [k, name] of (quick ? docs.slice(0, 4) : docs).entries()) {
  const patch = JSON.parse(readFileSync(`${CORPUS}/patches/${name}`, 'utf8'));
  const source = readFileSync(`${CORPUS}/${name.replace(/\.json$/, '.md')}`, 'utf8');
  await page.evaluate(p => window.readout.apply(p), patch);
  await page.waitForTimeout(400);
  // Its code on screen highlighted (in the worker; the first paint waits for it).
  for (let i = 0; i < 400 && await page.evaluate(() => getComputedStyle(document.getElementById('ro-doc')).visibility === 'hidden'); i++) await page.waitForTimeout(25);

  // 1. Select All.
  const all = await page.evaluate(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById('ro-doc')); return window.__copy(r); });
  if (!all.handled) fail(`${name}: select-all copy not handled`);
  const want = normalise(source), got = normalise(all.text);
  // Footnote definitions come last: compare without them, then them alone.
  const notes = patch.ops.filter(o => o.kind === 'footnotes').map(o => o.src);
  const body = notes.length ? all.text.slice(0, all.text.lastIndexOf(notes[notes.length - 1])) : all.text;
  const a = nonBlank(want), b = nonBlank(normalise(body));
  if (a.join('\n') === b.join('\n')) structural++;
  else {
    const i = a.findIndex((l, k) => l !== b[k]);
    fail(`${name}: select-all differs from the source at non-blank line ${i}:\n  source: ${JSON.stringify(a[i])}\n  copied: ${JSON.stringify(b[i])}`);
  }
  if (want.join('\n').replace(/\n{3,}/g, '\n\n').trim() !== got.join('\n').trim()) blankDiffs++;
  if (source.replace(/\s+$/, '') === all.text) exact++;
  if (process.env.COPY_DUMP) (await import('node:fs')).writeFileSync(`${process.env.COPY_DUMP}/${name}.all.md`, all.text);
  if (carriesBreaks(all)) fail(`${name}: select-all copies break opportunities (<wbr>) as text or markup`);

  // 2-4. Per block.
  const res = await page.evaluate(stride => {
    const blocks = [...document.querySelectorAll('#ro-doc > .chunk > .blk')];
    const out = [];
    blocks.forEach((b, i) => {
      const r = document.createRange(); r.selectNodeContents(b);
      out.push({ kind: 'whole', slot: +b.dataset.slot, ...window.__copy(r) });
      if (i % stride) return;
      const a = window.__point(b, 0.3), z = window.__point(b, 0.7);
      if (a && z) {
        const p = document.createRange(); p.setStart(...a); p.setEnd(...z);
        if (!p.collapsed) {
          // (Inside a long code path the selection's container is the code itself: its <wbr> split the text.)
          const c = p.commonAncestorContainer, leaf = (c.nodeType === 1 ? c : c.parentElement)?.closest('pre, code, .math, .math-block, .k-frontMatter');
          out.push({ kind: 'part', slot: +b.dataset.slot, leaf: leaf ? leaf.className || leaf.tagName : null, fragment: (() => { const d = document.createElement('div'); d.appendChild(p.cloneContents()); d.querySelectorAll('button, .cb-tools, .katex-mathml, .mermaid-src').forEach(e => e.remove()); return d.innerHTML; })(), ...window.__copy(p) });
        }
      }
      const c = blocks[i + 2] && window.__point(blocks[i + 2], 0.5);
      if (a && c) {
        const x = document.createRange(); x.setStart(...a); x.setEnd(...c);
        out.push({ kind: 'cross', slot: +b.dataset.slot, ...window.__copy(x) });
      }
    });
    return out;
  }, STRIDE);
  for (const r of res) if (carriesBreaks(r)) fail(`${name}: a copy of block ${r.slot} (${r.kind}) carries break opportunities: ${JSON.stringify((r.html || r.text).slice(0, 200))}`);
  fuzz(name, await page.evaluate(([n, seed]) => window.__fuzz(n, seed), [FUZZ, k * 7 + 11]));
  const srcOf = new Map(patch.ops.map(o => [o.slot, o.src]));
  for (const r of res) {
    if (!r.selected) continue;   // an empty block: nothing to select
    if (!r.handled) { fail(`${name} ${r.kind} ${r.slot}: not handled`); continue; }
    if (/<button|cb-tools|wd-panel|data-slot|tabindex/.test(r.html)) fail(`${name} ${r.kind} ${r.slot}: page furniture in the rich text`);
    if (r.kind === 'whole') {
      wholes++;
      if (r.text !== srcOf.get(r.slot)) fail(`${name} whole ${r.slot}: not its source\n  source: ${JSON.stringify(srcOf.get(r.slot)).slice(0, 200)}\n  copied: ${JSON.stringify(r.text).slice(0, 200)}`);
      continue;
    }
    partials++;
    if (r.kind === 'part' && r.leaf) {
      // Code, a code span, TeX or front matter: the text itself, no Markdown.
      if (/^(pre|code|CODE|PRE)/i.test(r.leaf) && r.text !== r.selected) fail(`${name} part ${r.slot}: code copied with Markdown: ${JSON.stringify(r.text)}`);
      continue;
    }
    // Rendered again, the copy reads as the selection did.
    const html = marked.parse(r.text, { gfm: true });
    // A part of a table copies the rows it touches, whole: the copy holds the selection.
    const table = /^(?:> ?)*\| .* \|$/m.test(r.text);
    const same = table ? words(html).includes(textWords(r.selected).replace(/\t/g, '')) || words(html).length >= textWords(r.selected).length : words(html) === textWords(r.selected);
    // A closed <details> copies its body, which the selection's text leaves out;
    // a diagram copies its source, where the selection reads its drawing's labels (C2).
    if (!same && !r.text.includes('$') && !r.text.includes('[^') && !r.text.includes('<details') && !r.text.includes('```mermaid')) {
      fail(`${name} ${r.kind} ${r.slot}: text changed\n  selected: ${JSON.stringify(r.selected).slice(0, 300)}\n  copied:   ${JSON.stringify(r.text).slice(0, 300)}`);
    }
    if (r.kind === 'part' && !table) {
      const s1 = shape(r.fragment), s2 = shape(html);
      for (const t of Object.keys(s1)) {
        // marked autolinks bare URLs; the fragment may hold half of one.
        if (t === 'a') continue;
        // Readout's parser takes CJK emphasis that CommonMark does not (`**（…）**的`, CJKEmphasis.swift): so does the source.
        if (s1[t] !== s2[t] && !/[\u3000-\u303f\uff00-\uffef]\*|\*[\u3000-\u303f\uff00-\uffef]/.test(r.text)) { fail(`${name} part ${r.slot}: ${t} ${s1[t]} selected, ${s2[t]} copied: ${JSON.stringify(r.text).slice(0, 200)}`); break; }
      }
    }
  }
}

// 4. Leaves: a code block, a code span, a formula.
await page.evaluate(p => window.readout.apply(p), JSON.parse(readFileSync(`${CORPUS}/patches/31-readout-typesetting-cases.json`, 'utf8')));
await page.waitForTimeout(400);
const leaves = await page.evaluate(() => {
  const r = document.createRange();
  const code = document.querySelector('.k-code pre code');
  r.selectNodeContents(code);
  const block = window.__copy(r);
  const span = document.querySelector('.k-table td code');
  r.selectNodeContents(span);
  const inlineCode = window.__copy(r);
  return { block, inlineCode, codeText: code.textContent, spanText: span.textContent };
});
if (leaves.block.text !== leaves.codeText) fail(`code block selection: ${JSON.stringify(leaves.block.text)}`);
if (leaves.inlineCode.text !== leaves.spanText) fail(`code span selection: ${JSON.stringify(leaves.inlineCode.text)}`);

// 5. Every construct (fixtures/copy-cases.md).
{
  const md = readFileSync('test/fixtures/copy-cases.md', 'utf8');
  await page.evaluate(p => window.readout.apply(p), JSON.parse(readFileSync('test/fixtures/copy-cases.json', 'utf8')));
  await page.waitForTimeout(400);
  const got = await page.evaluate(() => {
    const doc = document.getElementById('ro-doc');
    const range = el => { const r = document.createRange(); r.selectNodeContents(el); return r; };
    const blockOf = (sel, text) => [...doc.querySelectorAll(`:scope > .chunk > .blk${sel}`)].find(b => b.textContent.includes(text));
    const all = window.__copy(range(doc));
    const refPara = window.__copy(range(blockOf('.k-paragraph', 'reference link')));
    // Part of one plain paragraph: no page control in it, so on main WebKit copied it with Readout's styles.
    const plain = blockOf('.k-paragraph', 'Status: green').querySelector('p').firstChild;
    const r = document.createRange(); r.setStart(plain, 0); r.setEnd(plain, 6);
    const inPara = window.__copy(r);
    // A drag of the selection (C8): the same payload as a copy.
    getSelection().removeAllRanges(); getSelection().addRange(range(blockOf('.k-table', 'pipe')));
    const dt = new DataTransfer();
    blockOf('.k-table', 'pipe').querySelector('td').dispatchEvent(new DragEvent('dragstart', { dataTransfer: dt, bubbles: true, cancelable: true }));
    const table = window.__copy(range(blockOf('.k-table', 'pipe')));
    // Edit ▸ Select All selects the page (its toolbar, notices), not the document.
    const selAll = {};
    const grab = e => { selAll.text = e.clipboardData.getData('text/plain'); selAll.html = e.clipboardData.getData('text/html'); selAll.handled = e.defaultPrevented; };
    getSelection().removeAllRanges();
    document.execCommand('selectAll');
    selAll.ancestor = getSelection().getRangeAt(0).commonAncestorContainer.nodeName;
    addEventListener('copy', grab); document.execCommand('copy'); removeEventListener('copy', grab);
    // Part of a paragraph with escaped text (`\<br\>`, `\&amp;`): still text when pasted as Markdown.
    const lit = blockOf('.k-paragraph', 'Literal').querySelector('p');
    const lr = document.createRange(); lr.setStart(lit.firstChild, 1); lr.setEnd(lit.lastChild, lit.lastChild.data.length - 1);
    const literal = window.__copy(lr);
    return { all, refPara, inPara, table, selAll, literal, drag: { text: dt.getData('text/plain'), html: dt.getData('text/html') } };
  });
  // Select All: the file, with the footnote definition and then the link definition it uses last.
  const note = '[^n]: The note text.', ref = '[ref]: https://example.com/ref';
  const want = md.replace(`\n${note}\n`, '').replace(`\n${ref}\n`, '').replace(/\s+$/, '') + `\n\n${note}\n\n${ref}`;
  if (got.all.text !== want) {
    const a = want.split('\n'), b = got.all.text.split('\n');
    const i = a.findIndex((l, k) => l !== b[k]);
    fail(`copy-cases select-all is not the file at line ${i + 1}:\n  file:   ${JSON.stringify(a[i])}\n  copied: ${JSON.stringify(b[i])}`);
  }
  // Edit ▸ Select All, then Copy: the same as selecting the document (review).
  if (!got.selAll.handled || got.selAll.text !== got.all.text) fail(`copy-cases: Select All (${got.selAll.ancestor}) then Copy is not the document's Markdown: ${JSON.stringify((got.selAll.text || '').slice(0, 120))}`);
  // Escaped text in a partial copy stays text (review): rendered again it reads as selected.
  {
    const html = marked.parse(got.literal.text, { gfm: true });
    if (words(html) !== textWords(got.literal.selected) || /<br>/.test(html)) fail(`copy-cases: escaped text in a partial copy: ${JSON.stringify(got.literal.text)} renders ${JSON.stringify(html)}`);
  }
  // Each defect main had (C2), by name: true when the copy has it right.
  const t = got.all.text;
  const cases = {
    'loose task item keeps its marker and box': t.includes('- [ ] Loose task\n\n  Step 1'),
    'nested items keep their indentation': t.includes('- tight two\n  - nested **a**\n  - nested b\n- tight three'),
    'separate lists stay apart': t.includes('- tight three\n\n* star marker'),
    'a blank line after code, alerts and tables': t.includes('> > Nested quote.\n\n> [!WARNING]\n> Watch the `flag`.\n\n```swift') && t.includes('| 中文 | 2 | 3 |\n\nInline math'),
    'tables keep pipes and inline formatting': t.includes('| a \\| pipe | `b` | **c** |'),
    'links keep their URL, images their alt text': t.includes('[link](https://example.com/a "Title")') && t.includes('![An image](https://example.com/img.png)'),
    'alerts keep [!KIND]': t.includes('> [!WARNING]'),
    'footnote references keep their label': t.includes('reference.[^n]') && t.includes(note),
    'front matter keeps its fences and keys': t.startsWith('---\ntitle: Copy cases\nstatus: draft\n---\n'),
    'a closed <details> keeps its body': t.includes('Hidden **content**.'),
    'mermaid copies its source': t.includes('```mermaid\ngraph TD\n  A --> B\n```'),
    'display math keeps its lines': t.includes('$$\n\\int_0^1 x\\,dx\n$$'),
    'a hard break keeps its two spaces (C4)': t.includes('soft break,  \nand a hard break'),
  };
  for (const [what, ok] of Object.entries(cases)) if (!ok) fail(`copy-cases: ${what}`);
  // C5: a whole block that uses a reference gets its definition after it.
  if (!got.refPara.text.endsWith(`this line.\n\n${ref}`)) fail(`copy-cases: reference definition not appended: ${JSON.stringify(got.refPara.text.slice(-80))}`);
  // C3: rich text is the clean HTML whatever the selection touches: handled by the page, no page classes or styles.
  if (!got.inPara.handled || got.inPara.text !== 'Status' || !got.inPara.html || /class=|style=/.test(got.inPara.html)) fail(`copy-cases: a selection in a paragraph is not the clean copy: ${JSON.stringify(got.inPara)}`);
  if (!got.table.html.includes('<table') || /data-slot|tabindex|<button|class=/.test(got.table.html)) fail(`copy-cases: table rich text: ${got.table.html.slice(0, 200)}`);
  // Front matter's rich text is a table of keys and values, not spans that run together ("title Copy casesstatus draft").
  if (!got.all.html.includes('<table><tbody><tr><td>title</td><td>Copy cases</td></tr><tr><td>status</td><td>draft</td></tr>') || /title Copy casesstatus/.test(got.all.html.replace(/<[^>]+>/g, ''))) fail(`copy-cases: front matter rich text: ${got.all.html.slice(0, 300)}`);
  // A value with line breaks (a literal block: the parser's <br>, ParserTests) keeps them in its cell.
  {
    const html = await page.evaluate(() => {
      const fm = document.querySelector('#ro-doc .front-matter'), val = fm.querySelector('.fm-val'), was = val.innerHTML;
      val.innerHTML = 'line one<br>line two<br><br>after a blank line';
      const r = document.createRange(); r.selectNodeContents(fm.closest('.blk'));
      const out = window.__copy(r).html;
      val.innerHTML = was;
      return out;
    });
    if (!html.includes('<td>line one<br>line two<br><br>after a blank line</td>')) fail(`copy-cases: a front matter value loses its line breaks: ${html.slice(0, 300)}`);
  }
  // C8: the drag carries the copy's Markdown and HTML.
  if (got.drag.text !== got.table.text || got.drag.html !== got.table.html) fail(`copy-cases: drag payload differs from the copy: ${JSON.stringify(got.drag.text.slice(0, 120))}`);
}

// 5b. A source-only edit (copy-edit-1.md -> copy-edit-2.md, ReadoutCore's
//     two patches in copy-edit.json): the page keeps the block as it is (an
//     open <details> stays open) and copies the new source; a copy across a
//     removed item's marker keeps the tight list tight (review).
{
  const [first, second] = JSON.parse(readFileSync('test/fixtures/copy-edit.json', 'utf8'));
  await page.evaluate(p => window.readout.apply(p), first);
  await page.waitForTimeout(300);
  await page.evaluate(() => { document.querySelector('#ro-doc details').open = true; });
  await page.evaluate(p => window.readout.apply(p), second);
  await page.waitForTimeout(300);
  const got = await page.evaluate(() => {
    const doc = document.getElementById('ro-doc');
    const blockOf = text => [...doc.querySelectorAll(':scope > .chunk > .blk')].find(b => b.textContent.includes(text));
    const range = (a, z) => { const r = document.createRange(); r.setStart(a, 0); r.setEnd(z, z.childNodes.length); return r; };
    return {
      open: doc.querySelector('details').open,
      details: window.__copy(range(blockOf('Hidden body'), blockOf('Hidden body'))).text,
      list: window.__copy(range(blockOf('one'), blockOf('two'))).text,
      marker: !!doc.querySelector('.del-mark'),
      files: window.__copy(range(blockOf('Files:'), blockOf('gamma three'))).text,
    };
  });
  if (!got.open) fail('copy-edit: a source-only edit closed the open <details>');
  if (got.details !== '<details>\n<summary>More</summary>\n\nHidden body text.\n\n</details>') fail(`copy-edit: the <details> copies its old source: ${JSON.stringify(got.details)}`);
  if (got.list !== '- one\n- two') fail(`copy-edit: the list copies its old markers: ${JSON.stringify(got.list)}`);
  if (!got.marker || got.files !== '**Files:**\n- alpha one\n- gamma three') fail(`copy-edit: across the removed item (marker ${got.marker}): ${JSON.stringify(got.files)}`);
}

// 5c. Rich text is safe to paste (copy-unsafe.md): nothing that loads, runs
//     or styles beyond colour and alignment; links only to the web, mail or a
//     place in the text (review).
{
  await page.evaluate(p => window.readout.apply(p), JSON.parse(readFileSync('test/fixtures/copy-unsafe.json', 'utf8')));
  await page.waitForTimeout(300);
  const html = (await page.evaluate(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById('ro-doc')); return window.__copy(r); })).html;
  const bad = [/<img/i, /<video/i, /<source/i, /<picture/i, /srcset/i, /poster/i, /url\(/i, /javascript:/i, /vbscript:/i, /data:/i, /blocked:/i, /\sclass=/i, /\sdata-/i, /\stitle=/i, /\sid=/i];
  const hrefs = [...html.matchAll(/href="([^"]*)"/g)].map(m => m[1]);
  if (!html || bad.some(b => b.test(html)) || hrefs.some(h => !/^(https?:|mailto:|#)/.test(h)) || !hrefs.includes('https://example.com/ok') || !hrefs.includes('mailto:a@b.c') || !hrefs.includes('#top')) {
    fail(`copy-unsafe: rich text not safe to paste: ${html.slice(0, 600)}`);
  }
}

// 6. A large selection (C7): the copy costs what the two end blocks do, not
//    every block's layout (main: 35 s at 5 MB); past 100,000 characters, no rich text (F8).
{
  const ops = [];
  let slot = 0, bytes = 0;
  for (let round = 0; bytes < 650_000; round++) {
    for (const f of docs) {
      const p = JSON.parse(readFileSync(`${CORPUS}/patches/${f}`, 'utf8'));
      for (const op of p.ops) {
        if (op.op !== 'insert' || op.kind === 'footnotes' || op.kind === 'frontMatter') continue;
        ++slot;
        ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
        bytes += (op.src || '').length + 2;
      }
      if (bytes >= 650_000) break;
    }
  }
  await page.evaluate(p => window.readout.apply(p), { version: 9, reset: true, rewrite: false, ops, marks: [], deletions: [] });
  await page.waitForTimeout(500);
  const big = await page.evaluate(() => {
    const r = document.createRange(); r.selectNodeContents(document.getElementById('ro-doc'));
    getSelection().removeAllRanges(); getSelection().addRange(r);
    // Selected, every block is laid out (content-visibility): that is Select All's cost, not the copy's.
    void document.documentElement.offsetHeight;
    let text = null, html = null;
    const grab = e => { text = e.clipboardData.getData('text/plain'); html = e.clipboardData.getData('text/html'); };
    addEventListener('copy', grab);
    const t0 = performance.now();
    document.execCommand('copy');
    const ms = performance.now() - t0;
    removeEventListener('copy', grab);
    // A third of it (~200,000 characters): Markdown only too (F8: WebKit takes 0.3 s for 400 KB of rich text).
    const blocks = document.querySelectorAll('#ro-doc > .chunk > .blk');
    r.setEnd(blocks[Math.floor(blocks.length / 3)], 0);
    const third = window.__copy(r);
    return { ms, chars: text.length, html: html.length, third: { chars: third.text.length, html: third.html.length } };
  });
  console.log(`copy: ${ops.length} blocks (${bytes} characters of source) copied in ${big.ms.toFixed(0)} ms, ${big.chars} characters, rich text ${big.html}`);
  if (big.ms > 1000) fail(`a large copy took ${big.ms.toFixed(0)} ms`);
  if (big.chars <= 500_000 || big.html !== 0) fail(`a large copy: ${big.chars} characters of Markdown, ${big.html} of rich text (want none)`);
  if (big.third.chars <= 100_000 || big.third.chars >= 500_000 || big.third.html !== 0) fail(`a copy of a third: ${big.third.chars} characters of Markdown, ${big.third.html} of rich text (want none)`);
}

// 7. Random selections, parsed again by ReadoutCore.
{
  for (const [k, f] of ['copy-cases.json', 'copy-escapes.json'].entries()) {
    await page.evaluate(p => window.readout.apply(p), JSON.parse(readFileSync(`test/fixtures/${f}`, 'utf8')));
    await page.waitForTimeout(200);
    fuzz(f, await page.evaluate(([n, seed]) => window.__fuzz(n, seed), [k ? FUZZ * 12 : FUZZ, 1000 + k]));
  }
  // By name (copy-escapes.md): sub-points of an item (B1), escaped text inside a paragraph (B4).
  const named = await page.evaluate(() => {
    const find = (s, from) => {
      const w = document.createTreeWalker(document.getElementById('ro-doc'), NodeFilter.SHOW_TEXT);
      if (from) w.currentNode = from;
      for (let n = from || w.nextNode(); n; n = w.nextNode()) if (n.data.includes(s)) return n;
    };
    const copy = (a, ao, z, zo) => {
      const na = find(a), nz = find(z, na), r = document.createRange();
      r.setStart(na, na.data.indexOf(a) + ao); r.setEnd(nz, nz.data.indexOf(z) + zo);
      const c = window.__copy(r);
      return { selected: c.selected, text: c.text };
    };
    return [copy('succeeds when the key', 0, 'both hold', 4), copy('Literal', 2, 'here.', 4), copy('Struck', 1, 'too.', 3),
      copy('Money', 1, 'here.', 4), copy('Exclaim', 1, 'footnote', 0), copy('Inline', 1, 'text.', 4), copy('Brackets', 1, 'link.', 4)];
  });
  // ⌘C on a find match (the find bar selects it once its frame is painted): its Markdown, escaped as any partial copy.
  const found = [];
  for (const q of ['~one tilde~', '[ref]']) {
    found.push(await page.evaluate(q => new Promise(done => {
      const n = window.readout.find(q);
      requestAnimationFrame(() => setTimeout(() => setTimeout(() => {
        const r = getSelection().rangeCount ? getSelection().getRangeAt(0) : null;
        done({ n, ...(r ? window.__copy(r) : {}) });
      }, 0), 0));
    }), q));
  }
  await page.evaluate(() => window.readout.findEnd());
  if (!found[0].handled || found[0].text !== '\\~one tilde~' || found[1].text !== '[ref]') fail(`copy-escapes: ⌘C on a find match: ${JSON.stringify(found.map(f => [f.n, f.text]))}`);
  if (named[0].text !== '- succeeds when the key exists.\n- `p2p` -- succeeds when port 30303 is open.\n- `ready` -- succeeds when both') fail(`copy-escapes: sub-points of an item do not copy as a list: ${JSON.stringify(named[0].text)}`);
  copies.push(...named.map(c => ({ doc: 'copy-escapes.md (by name)', ...c })));
  // Parsed by ReadoutCore as the app parses a file: the text a reader sees, without white space.
  // READOUT_DUMP, else built here with swift; neither: a failure that says so (CI must run this).
  const howTo = 'build it (swift build --package-path Packages/ReadoutCore --product readout-dump) and set READOUT_DUMP to the binary, or put swift on PATH';
  const dump = process.env.READOUT_DUMP || (() => {
    const pkg = ['--package-path', '../Packages/ReadoutCore'];
    try {
      execFileSync('swift', ['build', ...pkg, '--product', 'readout-dump'], { stdio: ['ignore', 'ignore', 'inherit'] });
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
      console.log(`FAIL copy round trips need ReadoutCore's readout-dump, and swift is not on PATH: ${howTo}`);
      process.exit(1);
    }
    return join(execFileSync('swift', ['build', ...pkg, '--show-bin-path'], { encoding: 'utf8' }).trim(), 'readout-dump');
  })();
  if (!existsSync(dump)) { console.log(`FAIL READOUT_DUMP=${dump} does not exist: ${howTo}`); process.exit(1); }
  const dir = 'test/out/copy-fuzz';
  mkdirSync(dir, { recursive: true });
  const squash = t => t.replace(/[\s​]+/g, '');
  const visible = html => html.replace(/<[^>]+>/g, '').replace(/&(lt|gt|quot|#39|nbsp|amp);/g, (_, e) => entities[e]);
  const run = promisify(execFile);
  let bad = 0;
  for (let i = 0; i < copies.length; i += 8) {
    await Promise.all(copies.slice(i, i + 8).map(async (c, j) => {
      const file = `${dir}/${i + j}.md`;
      writeFileSync(file, c.text);
      const [patch] = JSON.parse((await run(dump, [file], { maxBuffer: 1 << 26 })).stdout);
      const seen = squash(patch.ops.filter(o => o.kind !== 'footnotes').map(o => visible(o.html)).join(''));
      if (seen !== squash(c.selected) && bad++ < 10) fail(`${c.doc}: a random selection reads differently when its copy is parsed again\n  selected: ${JSON.stringify(c.selected).slice(0, 300)}\n  copied:   ${JSON.stringify(c.text).slice(0, 300)}\n  reads:    ${JSON.stringify(seen).slice(0, 300)}`);
    }));
  }
  if (bad > 10) fail(`${bad - 10} more random selections read differently`);
  console.log(`copy: ${copies.length} random selections parsed again by ReadoutCore, ${bad} read differently`);
}

if (errors.length) fail(`page errors: ${errors.join('; ')}`);
console.log(`copy: ${docs.length} documents; select-all matches the source (non-blank lines) in ${structural}, byte-exact in ${exact}, blank lines differ in ${blankDiffs}; ${wholes} whole blocks, ${partials} partial selections; ${failures} failures`);
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
