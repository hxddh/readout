// Typography and layout details of the reader (3.3 refinements), in WebKit.
// Usage: node test/typography.test.mjs  (requires web/build.mjs to have run)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { PNG } from 'pngjs';

const WEB = process.env.READOUT_WEB_DIR || 'build/Web';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
// A solid red 16 x 16 PNG for the inline-icon check.
const icon = new PNG({ width: 16, height: 16 });
for (let i = 0; i < icon.data.length; i += 4) icon.data.set([220, 0, 0, 255], i);
const ICON = PNG.sync.write(icon);
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(req.url.split('?')[0]);
  if (u === '/icon.png') { res.writeHead(200, { 'content-type': 'image/png' }); return res.end(ICON); }
  const p = join(WEB, u);
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}

const browser = await webkit.launch();
const errors = [];

async function open(width, dark = false) {
  const page = await browser.newPage({ viewport: { width, height: 800 } });
  page.on('pageerror', e => errors.push(String(e)));
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(d => window.readout.setAppearance({ dark: d, accent: '#0a84ff', width: 'narrow', fontSize: 16 }), dark);
  return page;
}

// Polls from Node: page.waitForFunction needs eval, which the reader's CSP forbids.
async function until(page, fn, ms = 30000) {
  for (const end = Date.now() + ms; Date.now() < end; await page.waitForTimeout(50)) if (await page.evaluate(fn)) return true;
  return false;
}

function patch(blocks, version = 1) {
  const ops = blocks.map(([kind, html, extra = {}], i) => ({ op: 'insert', slot: i + 1, after: i, kind, html, cjk: false, ...extra }));
  return { version, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
}

const longLine = 'const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key, Range: "bytes=0-1023", ChecksumMode: "ENABLED" }));';
const doc = patch([
  ['frontMatter', '<div class="front-matter"><span class="fm-item"><span class="fm-key">name</span> audit</span></div>'],
  ['heading', '<h1 id="top">Top title</h1>', { anchor: 'top' }],
  ['paragraph', '<p>Intro with a <mark>marked</mark> word, <kbd>⇧⌘K</kbd> and <samp>ok</samp>, and <code>an inline code span that is long enough to break across two lines in a narrow column</code>.</p>'],
  ['paragraph', '<p>A long URL: https://example.com/a/very/long/path/that/keeps/going/and/going/without/any/break/opportunities/at/all/index.html and Pneumonoultramicroscopicsilicovolcanoconiosis_supercalifragilisticexpialidocious_x.</p>'],
  ['heading', '<h2 id="sec">Section heading</h2>', { anchor: 'sec' }],
  ['paragraph', '<p>Body under the section.</p>'],
  ['code', `<div class="code-block" data-lang="ts"><pre><code>// fetch the first KiB\n${longLine}\nreturn result;</code></pre></div>`],
  ['code', `<div class="code-block" data-lang="diff"><pre><code>--- a/x.js\n+++ b/x.js\n-const b = 2;\n+const b = 3;\n+// ${longLine}\n console.log(b);</code></pre></div>`],
  ['heading', '<h1 id="part-two">Part two</h1>', { anchor: 'part-two' }],
  ['listItem', '<ul class="li-block li-first li-last"><li>Item with code:<div class="code-block" data-lang="sh"><pre><code>npm test</code></pre></div></li></ul>'],
  ['quote', '<blockquote><p>Quote with code:</p><div class="code-block" data-lang="sh"><pre><code>make</code></pre></div></blockquote>'],
  ['alert', '<div class="alert alert-tip"><p class="alert-title">Tip</p><p>Tip text.</p></div>'],
  ['alert', '<div class="alert alert-warning"><p class="alert-title">Warning</p><p>Warning text.</p></div>'],
  ['table', '<div class="table-wrap"><table><thead><tr><th>Field</th><th>Value</th></tr></thead><tbody><tr><td>(optional) name</td><td>"string"</td></tr></tbody></table></div>'],
  ['table', `<div class="table-wrap"><table><thead><tr>${Array.from({ length: 16 }, (_, i) => `<th>Column ${i + 1}</th>`).join('')}</tr></thead><tbody><tr>${Array.from({ length: 16 }, (_, i) => `<td>value-${i}</td>`).join('')}</tr></tbody></table></div>`],
  ['paragraph', '<p>Icon <img src="icon.png" alt="" width="16" height="16"> inline.</p>'],
  ['paragraph', '<p>日本語の段落です。「かぎ括弧」を含みます。</p>', { cjk: true }],
  ['paragraph', '<p>中文段落：直、骨、角。</p>', { cjk: true }],
  ['rule', '<hr>'],
  ['paragraph', '<p>After the rule.</p>'],
  ['footnotes', '<section class="footnotes" data-footnotes><ol><li id="fn-1"><p>A note.</p></li></ol></section>'],
]);
const slotOf = sel => doc.ops.findIndex(o => o.html.includes(sel)) + 1;

// ---------- 600 px, light ----------
let page = await open(600);
await page.evaluate(p => window.readout.apply(p), doc);
await page.waitForTimeout(600);

const support = await page.evaluate(() => ({
  'text-autospace: normal': CSS.supports('text-autospace', 'normal'),
  'text-spacing-trim: space-first': CSS.supports('text-spacing-trim', 'space-first'),
  'hanging-punctuation: allow-end': CSS.supports('hanging-punctuation', 'allow-end'),
}));
console.log(`info: CSS.supports in this WebKit: ${JSON.stringify(support)}`);

// 2. Hanging punctuation: never in code or table cells, never at a line start.
const hang = await page.evaluate(() => {
  const v = e => getComputedStyle(e).getPropertyValue('hanging-punctuation');
  return { html: v(document.documentElement), pre: v(document.querySelector('.code-block pre')), code: v(document.querySelector('p code')),
           td: v(document.querySelector('td')), th: v(document.querySelector('th')), kbd: v(document.querySelector('kbd')) };
});
check('no hanging punctuation at a line start', !/first/.test(hang.html), JSON.stringify(hang));
check('no hanging punctuation in code, kbd and table cells', ['pre', 'code', 'td', 'th', 'kbd'].every(k => hang[k] === 'none'), JSON.stringify(hang));

// 3. A mid-document H1 has space above it; the first one (under front matter) does not.
const h1 = await page.evaluate(() => {
  const [first, mid] = [...document.querySelectorAll('.k-heading h1')];
  const h2 = document.querySelector('.k-heading h2');
  return { first: parseFloat(getComputedStyle(first).marginTop), mid: parseFloat(getComputedStyle(mid).marginTop), h2: parseFloat(getComputedStyle(h2).marginTop) };
});
check('first H1 under front matter starts at the top', h1.first === 0, JSON.stringify(h1));
check('mid-document H1 has a top margin at least an H2\'s', h1.mid >= h1.h2 && h1.mid > 0, JSON.stringify(h1));

// 4. Blocks nested in a list item or quote keep vertical margins.
const nested = await page.evaluate(() => ({
  li: parseFloat(getComputedStyle(document.querySelector('.li-block li > .code-block')).marginTop),
  quote: parseFloat(getComputedStyle(document.querySelector('blockquote > .code-block')).marginTop),
}));
check('code block in a list item has space above', nested.li >= 6, JSON.stringify(nested));
check('code block in a quote has space above', nested.quote >= 6, JSON.stringify(nested));

// 5. Long URLs and words wrap: the page never scrolls sideways.
const sideways = await page.evaluate(() => document.scrollingElement.scrollWidth - window.innerWidth);
check('long URL and word do not widen the page', sideways <= 0, `overflow=${sideways}px`);
const wideTable = await page.evaluate(() => { const t = [...document.querySelectorAll('.table-wrap')][1]; return { scrolls: t.classList.contains('scrolls'), bg: getComputedStyle(t).backgroundImage }; });
check('wide table still scrolls inside its wrapper', wideTable.scrolls, JSON.stringify(wideTable));

// 6. Diff bands run edge to edge, across the full scrolled width.
const diff = await page.evaluate(() => {
  const cb = document.querySelector('.code-block[data-lang="diff"]');
  const pre = cb.querySelector('pre');
  const lines = [...pre.querySelectorAll('.line.add, .line.del')];
  const c = cb.getBoundingClientRect();
  return { highlighted: cb.dataset.hl, n: lines.length, lefts: lines.map(l => Math.round(l.getBoundingClientRect().left - c.left)),
           widths: lines.map(l => Math.round(l.getBoundingClientRect().width)), scrollW: pre.scrollWidth };
});
check('diff lines are highlighted', diff.highlighted === 'done' && diff.n === 3, JSON.stringify(diff));
check('diff bands start at the block edge', diff.lefts.every(l => Math.abs(l) <= 1), JSON.stringify(diff));
check('diff bands span the full scroll width', diff.widths.every(w => Math.abs(w - diff.scrollW) <= 2), JSON.stringify(diff));

// 7. The code toolbar sits on the block's fill, not over bare code.
const tools = await page.evaluate(() => getComputedStyle(document.querySelector('.cb-tools')).backgroundImage);
check('code toolbar has a fill behind it', tools && tools !== 'none', tools);

// 9. The section link and the change bar line up with the heading's first line.
const align = await page.evaluate(() => {
  const out = [];
  for (const blk of document.querySelectorAll('.k-heading')) {
    const h = blk.querySelector('h1, h2');
    const r = h.getBoundingClientRect();
    const lh = parseFloat(getComputedStyle(h).lineHeight);
    const link = blk.querySelector('.h-link').getBoundingClientRect();
    const barTop = parseFloat(getComputedStyle(blk, '::before').top) + blk.getBoundingClientRect().top;
    out.push({ id: h.id, linkMid: Math.round((link.top + link.bottom) / 2 - r.top), lh: Math.round(lh), bar: Math.round(barTop - r.top), left: Math.round(link.left - blk.getBoundingClientRect().left) });
  }
  return out;
});
check('section link sits on the heading\'s first line', align.every(a => a.linkMid > 0 && a.linkMid < a.lh), JSON.stringify(align));
check('section link stays in the gutter', align.every(a => a.left >= 0 && a.left < 20), JSON.stringify(align));
check('change bar starts at the heading text', align.every(a => a.bar >= 0 && a.bar < a.lh * 0.4), JSON.stringify(align));

// 10. <mark> and <kbd> are styled.
const marks = await page.evaluate(() => {
  const m = document.querySelector('mark'), p = m.parentElement, k = document.querySelector('kbd'), s = document.querySelector('samp');
  return { markBg: getComputedStyle(m).backgroundColor, markColor: getComputedStyle(m).color, pColor: getComputedStyle(p).color,
           kbdFont: getComputedStyle(k).fontFamily, kbdShadow: getComputedStyle(k).boxShadow, sampFont: getComputedStyle(s).fontFamily };
});
check('mark is a soft highlight that keeps the text colour', marks.markBg !== 'rgb(255, 255, 0)' && marks.markColor === marks.pColor, JSON.stringify(marks));
check('kbd and samp use the reader\'s monospace', /ui-monospace/.test(marks.kbdFont) && /ui-monospace/.test(marks.sampFont), JSON.stringify(marks));
check('kbd has a key outline', marks.kbdShadow && marks.kbdShadow !== 'none', JSON.stringify(marks));

// 11. Light-mode text meets WCAG AA (4.5:1).
await until(page, () => document.querySelector('.code-block[data-lang="ts"]').dataset.hl === 'done');
const contrast = await page.evaluate(() => {
  const rgb = s => s.match(/[\d.]+/g).slice(0, 3).map(Number);
  const lum = c => { const [r, g, b] = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const [x, y] = [lum(rgb(a)), lum(rgb(b))].sort((p, q) => q - p); return +((x + 0.05) / (y + 0.05)).toFixed(2); };
  const cs = s => getComputedStyle(document.querySelector(s));
  const fill = cs('.code-block').backgroundColor, bg = getComputedStyle(document.documentElement).backgroundColor;
  // Shiki's comment colour: the token whose text starts with //.
  const comment = [...document.querySelectorAll('.code-block[data-lang="diff"] span, .code-block span')].find(s => s.textContent.startsWith('//') && s.children.length === 0);
  return {
    tip: ratio(cs('.alert-tip .alert-title').color, cs('.alert-tip').backgroundColor),
    warning: ratio(cs('.alert-warning .alert-title').color, cs('.alert-warning').backgroundColor),
    frontMatter: ratio(cs('.front-matter').color, bg),
    comment: comment ? ratio(getComputedStyle(comment).color, fill) : 0,
  };
});
for (const [k, v] of Object.entries(contrast)) check(`${k} text reaches 4.5:1`, v >= 4.5, `${k}=${v}`);

// 12. A rule and the footnotes keep their wider spacing.
const spacing = await page.evaluate(() => ({
  hrBelow: parseFloat(getComputedStyle(document.querySelector('hr')).marginBottom),
  hrAbove: parseFloat(getComputedStyle(document.querySelector('hr')).marginTop),
  fnAbove: parseFloat(getComputedStyle(document.querySelector('.footnotes')).marginTop),
}));
check('a rule has 2em below it and space above', spacing.hrBelow >= 31 && spacing.hrAbove > 0, JSON.stringify(spacing));
check('footnotes keep their space above', spacing.fnAbove > 0, JSON.stringify(spacing));

// 13. Han characters get Japanese forms next to kana, Chinese forms otherwise.
const langs = await page.evaluate(() => [...document.querySelectorAll('#ro-doc > .blk')].map(b => b.lang || ''));
const ja = slotOf('日本語'), zh = slotOf('中文段落'), en = slotOf('Body under');
check('a block with kana is lang=ja', langs[ja - 1] === 'ja', JSON.stringify(langs));
check('a Chinese block is lang=zh', langs[zh - 1] === 'zh', JSON.stringify(langs));
check('an English block has no lang of its own', langs[en - 1] === '', JSON.stringify(langs));
await page.evaluate(([s]) => window.readout.apply({ version: 2, reset: false, rewrite: false,
  ops: [{ op: 'replace', slot: s, html: '<p>Now in English.</p>', kind: 'paragraph', cjk: false, change: 'content' }],
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }), [ja]);
const relang = await page.evaluate(s => document.querySelector(`.blk[data-slot="${s}"]`).lang, ja);
check('an edited block drops a lang it no longer needs', relang === '', relang);

// 14. Small polish.
const polish = await page.evaluate(() => {
  const c = getComputedStyle(document.querySelector('p code'));
  const img = document.querySelector('img[src="icon.png"]');
  return { clone: c.getPropertyValue('-webkit-box-decoration-break') || c.getPropertyValue('box-decoration-break'),
           tableFade: getComputedStyle([...document.querySelectorAll('.table-wrap')][1]).backgroundImage };
});
check('inline code broken across lines keeps its padding', polish.clone === 'clone', JSON.stringify(polish));
check('a scrolling table hints at more on the right', polish.tableFade && polish.tableFade !== 'none', JSON.stringify(polish));
// A 16 px icon keeps its corners: the pixel next to a corner is the icon's, not the page's.
await page.evaluate(() => document.querySelector('img[src="icon.png"]').scrollIntoView({ block: 'center' }));
const iconBox = await page.evaluate(() => { const r = document.querySelector('img[src="icon.png"]').getBoundingClientRect(); return { x: r.left, y: r.top, width: r.width, height: r.height }; });
const iconShot = PNG.sync.read(await page.screenshot({ clip: iconBox }));
const corner = [...iconShot.data.subarray(((1 * iconShot.width) + 1) * 4, ((1 * iconShot.width) + 1) * 4 + 3)];
check('a small inline icon is not rounded into a blob', iconBox.width === 16 && corner[0] > 150 && corner[1] < 90, JSON.stringify({ iconBox, corner }));

// 15. Copying a heading, a paragraph and a code block copies none of the reader's labels.
const copied = await page.evaluate(() => {
  const h = document.querySelector('.k-heading h2');
  const cb = document.querySelector('.code-block[data-lang="ts"]');
  const range = document.createRange();
  range.setStartBefore(h.closest('.blk'));
  range.setEndAfter(cb.closest('.blk'));
  const sel = getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  const text = sel.toString();
  sel.removeAllRanges();
  const btn = cb.querySelector('.cb-copy');
  return { text, copyName: btn.getAttribute('aria-label'), copyShown: getComputedStyle(btn, '::before').content };
});
check('copied text has the heading, body and code', /Section heading/.test(copied.text) && /Body under/.test(copied.text) && copied.text.includes('return result;'), JSON.stringify(copied.text));
check('copied text has no §, language, Wrap or Copy label', !/§|\bts\b|Wrap|Copy/.test(copied.text), JSON.stringify(copied.text));
check('the copy button is still labelled', copied.copyName === 'Copy' && /Copy/.test(copied.copyShown), JSON.stringify(copied));
await page.close();

// 1. Mermaid diagrams keep their natural size: not stretched in a wide column,
//    not shrunk below three quarters in a narrow one (the block scrolls).
const diagram = patch([
  ['mermaid', '<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A[Agent writes] --> B[WAL segment on object storage]\n  B --> C[Compactor merges]\n  C --> D[Readers see new data]\n  D --> E[Garbage collected]</pre></div>'],
  ['mermaid', '<div class="mermaid-block"><pre class="mermaid-src">flowchart TD\n  A --> B</pre></div>'],
]);
for (const width of [1100, 600]) {
  page = await open(width);
  if (width >= 1100) await page.evaluate(() => window.readout.setAppearance({ width: 'wide' }));
  await page.evaluate(p => window.readout.apply(p), diagram);
  await until(page, () => document.querySelectorAll('.mermaid-block.done svg').length === 2);
  const sizes = await page.evaluate(() => [...document.querySelectorAll('.mermaid-block')].map(b => {
    const svg = b.querySelector('svg');
    return { natural: Math.round(svg.viewBox.baseVal.width), shown: Math.round(svg.getBoundingClientRect().width), column: b.clientWidth, scrollW: b.scrollWidth };
  }));
  check(`diagrams are never wider than their natural size (${width})`, sizes.every(s => s.shown <= s.natural + 1), JSON.stringify(sizes));
  check(`diagrams are not shrunk below 3/4 of natural size (${width})`, sizes.every(s => s.shown >= Math.min(s.natural, Math.round(s.natural * 0.75)) - 1), JSON.stringify(sizes));
  check(`a diagram fits the column or scrolls in its block (${width})`, sizes.every(s => s.shown <= s.column + 1 || s.scrollW > s.column), JSON.stringify(sizes));
  await page.close();
}

// 8. Printing a dark page prints light: dark text, Shiki's light colours, wrapped tables.
page = await open(800, true);
await page.evaluate(p => window.readout.apply(p), doc);
await until(page, () => document.querySelector('.code-block[data-lang="ts"]').dataset.hl === 'done');
const screenColor = await page.evaluate(() => getComputedStyle(document.querySelector('p')).color);
await page.emulateMedia({ media: 'print' });
const print = await page.evaluate(() => {
  const span = [...document.querySelectorAll('.code-block[data-lang="ts"] span[style]')].find(s => s.style.getPropertyValue('--shiki-light'));
  const probe = document.createElement('span');
  probe.style.color = span.style.getPropertyValue('--shiki-light');
  document.body.appendChild(probe);
  const light = getComputedStyle(probe).color;
  probe.remove();
  const t = [...document.querySelectorAll('.table-wrap')][1];
  return { text: getComputedStyle(document.querySelector('p')).color, bg: getComputedStyle(document.documentElement).backgroundColor,
           scheme: getComputedStyle(document.documentElement).colorScheme, code: getComputedStyle(span).color, light,
           tableFits: t.scrollWidth <= t.clientWidth + 1 };
});
check('screen is dark before printing', screenColor === 'rgb(232, 232, 234)', screenColor);
check('a dark page prints dark text on white', print.text === 'rgb(29, 29, 31)' && print.bg === 'rgb(255, 255, 255)' && print.scheme === 'light', JSON.stringify(print));
check('code prints in Shiki\'s light colours', print.code === print.light, JSON.stringify(print));
check('a wide table wraps to the page when printed', print.tableFits, JSON.stringify(print));
await page.close();

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all typography checks passed');
process.exit(failures ? 1 : 0);
