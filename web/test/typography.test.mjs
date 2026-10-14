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
  ['heading', '<h2 id="after-rule">After the rule</h2>', { anchor: 'after-rule' }],
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
// (In a quote the space is the gap below the paragraph above, spaced like
// the quote's paragraphs; the code block's own top margin is 0 there.)
const nested = await page.evaluate(() => {
  const qcb = document.querySelector('blockquote > .code-block');
  return {
    li: parseFloat(getComputedStyle(document.querySelector('.li-block li > .code-block')).marginTop),
    quote: Math.round(qcb.getBoundingClientRect().top - qcb.previousElementSibling.getBoundingClientRect().bottom),
  };
});
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
const afterRule = await page.evaluate(() => Math.round(document.getElementById('after-rule').getBoundingClientRect().top - document.querySelector('hr').getBoundingClientRect().bottom));
check('a heading under a rule keeps the rule\'s 2em, not 2em plus its own margin', Math.abs(afterRule - 32) <= 2, `gap=${afterRule}px`);
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

// ---------- 3.4 visual refinements ----------

// A page as the app shows it before setAppearance has run (the first paint),
// with the system in light or dark mode.
async function openRaw(width, scheme) {
  const p = await browser.newPage({ viewport: { width, height: 800 }, colorScheme: scheme });
  p.on('pageerror', e => errors.push(String(e)));
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  return p;
}
const TOKENS = ['--bg', '--text', '--text-2', '--text-3', '--rule', '--fill', '--fill-2', '--link', '--accent-soft', '--mark-read',
  '--note', '--tip', '--important', '--warning', '--caution', '--pop-bg', '--pop-shadow', '--mark-bg', 'color-scheme'];
const tokens = pg => pg.evaluate(t => { const cs = getComputedStyle(document.documentElement); return Object.fromEntries(t.map(k => [k, cs.getPropertyValue(k).trim()])); }, TOKENS);

// 2. Dark mode opens dark: no hard-coded light theme in the page, the
//    system's dark mode applies until the app says, and the app wins both ways.
{
  const dark = await openRaw(600, 'dark');
  const first = await dark.evaluate(() => ({ attr: document.documentElement.getAttribute('data-theme'), bg: getComputedStyle(document.documentElement).backgroundColor,
    body: getComputedStyle(document.body).backgroundColor }));
  check('the page has no theme of its own before the app sets one', first.attr === null, JSON.stringify(first));
  check('in system dark mode the first paint is dark, not white', first.bg === 'rgb(30, 30, 31)', JSON.stringify(first));
  const sys = await tokens(dark);
  await dark.evaluate(() => window.readout.setAppearance({ dark: false }));
  const forcedLight = await dark.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
  check('an app-chosen light theme wins over system dark mode', forcedLight === 'rgb(255, 255, 255)', forcedLight);
  await dark.evaluate(() => window.readout.setAppearance({ dark: true }));
  const explicit = await tokens(dark);
  const differ = TOKENS.filter(k => k !== '--accent-soft' && sys[k] !== explicit[k]);
  check('system dark and app-chosen dark use the same colours', differ.length === 0, JSON.stringify(differ.map(k => [k, sys[k], explicit[k]])));
  await dark.close();
  const light = await openRaw(600, 'light');
  const l0 = await light.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
  await light.evaluate(() => window.readout.setAppearance({ dark: true }));
  const l1 = await light.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
  check('system light paints light; an app-chosen dark theme wins over it', l0 === 'rgb(255, 255, 255)' && l1 === 'rgb(30, 30, 31)', JSON.stringify([l0, l1]));
  await light.close();
}

const wideRow = ['Agent runtime WAL', 'append to object storage segment then ack', 'tail via conditional GET', 'merge every 64 MB',
  'Readers may see a segment before its manifest lands; the manifest is the commit point and anything not listed there is garbage collected after one hour.',
  'wal_segment_bytes', 'manifest_commit_interval_ms', 'compaction_parallelism', 'gc_grace_period_seconds'];
const v34 = patch([
  ['heading', '<h1 id="v-top">Visual</h1>', { anchor: 'v-top' }],
  ['paragraph', '<p>Text with a <a id="lnk" href="https://example.com">link</a>, a note<sup class="fn-ref"><a href="#user-content-fn-9" id="ref9" data-footnote-ref>1</a></sup> and <code class="path-link">web/src/reader.css</code>.</p>'],
  ['code', '<div class="code-block" data-lang="sh"><pre><code>npm test</code></pre></div>'],
  ['paragraph', '<p id="after-code">After the code.</p>'],
  ['paragraph', '<p id="after-p">After a paragraph.</p>'],
  ['quote', '<blockquote><p>Quote:</p><div class="table-wrap"><table><thead><tr><th>K</th><th>V</th></tr></thead><tbody><tr><td>a</td><td>1</td></tr></tbody></table></div><p id="q-after-table">After the table.</p><p id="q-after-p">After a paragraph.</p><div class="code-block" data-lang="sh"><pre><code>make</code></pre></div></blockquote>'],
  ['alert', '<div class="alert alert-note"><p class="alert-title">Note</p><p>Body.</p><div class="math-block" data-tex="a+b">a+b</div></div>'],
  ['table', `<div class="table-wrap" id="wide"><table><thead><tr>${['Workload', 'Write path', 'Read path', 'Compaction', 'Notes', 'Setting A', 'Setting B', 'Setting C', 'Setting D'].map(c => `<th>${c}</th>`).join('')}</tr></thead><tbody><tr>${wideRow.map(c => `<td>${c}</td>`).join('')}</tr></tbody></table></div>`],
  ['table', '<div class="table-wrap" id="headless"><table><thead><tr><th></th><th></th></tr></thead><tbody><tr><td>Name</td><td>Readout</td></tr></tbody></table></div>'],
  ['table', '<div class="table-wrap" id="nums"><table><thead><tr><th>Metric</th><th class="num">ms</th></tr></thead><tbody><tr><td>update</td><td class="num">1,204.9</td></tr></tbody></table></div>'],
  ['math', '<div class="math-block" id="m-short" data-tex="\\int_0^1 x\\,dx = \\frac{1}{2}">\\int_0^1 x\\,dx = \\frac{1}{2}</div>'],
  ['math', `<div class="math-block" id="m-long" data-tex="${Array.from({ length: 16 }, (_, i) => `a_{${i}} x^{${i}}`).join(' + ')}">${Array.from({ length: 16 }, (_, i) => `a_{${i}} x^{${i}}`).join(' + ')}</div>`],
  ['paragraph', '<p>After math.</p>'],
  ['heading', '<h4 id="v4">Four</h4>', { anchor: 'v4' }],
  ['paragraph', '<p>Body.</p>'],
  ['heading', '<h5 id="v5">Five</h5>', { anchor: 'v5' }],
  ['paragraph', '<p>Body.</p>'],
  ['heading', '<h6 id="v6">Six</h6>', { anchor: 'v6' }],
  ['paragraph', '<p>Body.</p>'],
  ['listItem', '<ol class="li-block li-first li-last" start="1"><li>One<ol id="ol2"><li>two<ol id="ol3"><li>three</li></ol></li></ol></li></ol>'],
  ['listItem', '<ol class="li-block li-first li-last ol-w3" id="w3" start="100"><li>Hundred</li></ol>'],
  ['listItem', '<ol class="li-block li-first li-last ol-w4" id="w4" start="1000"><li>Thousand</li></ol>'],
  ['listItem', '<ol class="li-block li-first li-last ol-w5" id="w5" start="10000"><li>Ten thousand</li></ol>'],
  ['paragraph', '<p id="p-mod">Modified.</p>'],
  ['paragraph', '<p id="p-read">Read.</p>'],
  ['footnotes', '<section class="footnotes" data-footnotes><ol><li id="user-content-fn-9"><p>Note. <a href="#ref9" class="fn-back" data-footnote-backref aria-label="Back">↩</a></p></li></ol></section>'],
]);
const vslot = sel => v34.ops.findIndex(o => o.html.includes(sel)) + 1;
const settleMath = pg => until(pg, () => document.querySelectorAll('.math-block.done').length === 3);

for (const dark of [false, true]) {
  const th = dark ? 'dark' : 'light';
  page = await open(600, dark);
  await page.evaluate(p => window.readout.apply(p), v34);
  await settleMath(page);
  await page.waitForTimeout(300);

  // 1. At rest the document starts the same distance under any toolbar.
  const tops = [];
  for (const inset of [0, 52, 80]) {
    await page.evaluate(i => window.readout.setAppearance({ topInset: i }), inset);
    tops.push(await page.evaluate(() => { window.scrollTo(0, 0); return Math.round(document.getElementById('v-top').getBoundingClientRect().top); }));
  }
  await page.evaluate(() => window.readout.setAppearance({ topInset: 0 }));
  check(`first heading sits 28 px under the toolbar at insets 0/52/80 (${th})`, tops[0] === 28 && tops[1] === 80 && tops[2] === 108, JSON.stringify(tops));

  const g = await page.evaluate(() => {
    const $ = s => document.querySelector(s);
    const gap = (a, b) => Math.round((b.getBoundingClientRect().top - a.getBoundingClientRect().bottom) * 10) / 10;
    const cs = (e, p) => getComputedStyle(e, p);
    const blk = id => $(`#${id}`).closest('.blk');
    const codeBlk = $('.code-block[data-lang="sh"]').closest('.blk');
    const q = $('blockquote');
    const wide = $('#wide');
    const wrapCell = [...wide.querySelectorAll('td')][1];
    const range = document.createRange(); range.selectNodeContents(wrapCell);
    const lines = new Set([...range.getClientRects()].map(r => Math.round(r.top))).size;
    const link = $('#lnk');
    const alert = $('.alert');
    const ms = $('#m-short');
    const h = id => { const e = $(`#${id}`); return { mt: parseFloat(cs(e).marginTop), fs: parseFloat(cs(e).fontSize), color: cs(e).color, tt: cs(e).textTransform }; };
    return {
      afterCode: gap(codeBlk.querySelector('.code-block'), $('#after-code')), afterP: gap($('#after-code'), $('#after-p')),
      qTable: gap(q.querySelector('.table-wrap'), $('#q-after-table')), qP: gap($('#q-after-table'), $('#q-after-p')),
      qCode: gap($('#q-after-p'), q.querySelector('.code-block')), qLastMb: parseFloat(cs(q.querySelector('.code-block')).marginBottom),
      alertMathMt: parseFloat(cs(alert.querySelector('.math-block')).marginTop), alertMathGap: gap(alert.querySelector('.math-block').previousElementSibling, alert.querySelector('.math-block')),
      wideScrolls: wide.classList.contains('scrolls'), wideTableW: Math.round(wide.querySelector('table').getBoundingClientRect().width), wideClient: wide.clientWidth,
      wrapLines: lines, maxCell: Math.max(...[...wide.querySelectorAll('td')].map(c => c.getBoundingClientRect().width)), em30: 30 * parseFloat(cs(wrapCell).fontSize),
      link: { line: cs(link).textDecorationLine, color: cs(link).textDecorationColor, offset: cs(link).textUnderlineOffset, text: cs(link).color },
      fnRef: cs($('.fn-ref a')).textDecorationLine, fnBack: cs($('.fn-back')).textDecorationLine, pathLink: cs($('code.path-link')).textDecorationLine,
      alertBorder: cs(alert).borderLeftWidth, alertShadow: cs(alert).boxShadow,
      headless: cs($('#headless thead')).display, headed: cs($('#wide thead')).display,
      num: [cs($('#nums td.num')).textAlign, cs($('#nums th.num')).textAlign, cs($('#nums td')).textAlign],
      katexMargin: [cs(ms.querySelector('.katex-display')).marginTop, cs(ms.querySelector('.katex-display')).marginBottom], mathBg: cs(ms).backgroundImage,
      longOverflows: $('#m-long').scrollWidth > $('#m-long').clientWidth,
      h4: h('v4'), h5: h('v5'), h6: h('v6'), text3: cs(document.documentElement).getPropertyValue('--text-3').trim(), rem: parseFloat(cs(document.documentElement).fontSize),
      ol2: cs($('#ol2')).listStyleType, ol3: cs($('#ol3')).listStyleType,
      w: ['w3', 'w4', 'w5'].map(id => parseFloat(cs($(`#${id}`)).paddingLeft) / parseFloat(cs($(`#${id}`)).fontSize)),
    };
  });
  // 4. Below a code block the gap is the body text's, not the code font's.
  check(`gap after a code block matches the gap after a paragraph (${th})`, Math.abs(g.afterCode - g.afterP) <= 0.5, JSON.stringify([g.afterCode, g.afterP]));
  // 6. Inside a quote or alert, nested blocks are spaced like its paragraphs.
  check(`in a quote, a table and a code block are spaced like paragraphs (${th})`, Math.abs(g.qTable - g.qP) <= 0.5 && Math.abs(g.qCode - g.qP) <= 0.5 && g.qLastMb === 0, JSON.stringify(g));
  check(`in an alert, a nested block keeps no extra top margin (${th})`, g.alertMathMt === 0 && g.alertMathGap > 10, JSON.stringify([g.alertMathMt, g.alertMathGap]));
  // 3. A table that scrolls anyway takes its natural width, each cell at most 30em.
  check(`a wide table takes its natural width (${th})`, g.wideScrolls && g.wideTableW > g.wideClient && g.wrapLines === 1, JSON.stringify([g.wideScrolls, g.wideTableW, g.wideClient, g.wrapLines]));
  check(`a long cell in a wide table still wraps at 30em (${th})`, g.maxCell <= g.em30 + 1, JSON.stringify([g.maxCell, g.em30]));
  // 7. Links carry a quiet underline; footnote marks, back links and paths do not.
  const alpha = (g.link.color.match(/[\d.]+/g) || []).map(Number)[3];
  check(`links have a subtle underline (${th})`, g.link.line === 'underline' && alpha > 0.25 && alpha < 0.45 && parseFloat(g.link.offset) > 2, JSON.stringify(g.link));
  check(`footnote refs, back links and path links are not underlined (${th})`, g.fnRef === 'none' && g.fnBack === 'none' && g.pathLink === 'none', JSON.stringify([g.fnRef, g.fnBack, g.pathLink]));
  // 8. Alert edge: an inset shadow that follows the corners, no border.
  check(`alert edge is an inset shadow, not a border (${th})`, g.alertBorder === '0px' && /inset/.test(g.alertShadow) && /3px 0px 0px/.test(g.alertShadow), JSON.stringify([g.alertBorder, g.alertShadow]));
  // 9. An empty header row is hidden; a real one is not.
  check(`an empty header row is hidden (${th})`, g.headless === 'none' && g.headed !== 'none', JSON.stringify([g.headless, g.headed]));
  // 13. Numeric columns align right.
  check(`numeric cells align right (${th})`, g.num[0] === 'right' && g.num[1] === 'right' && g.num[2] !== 'right', JSON.stringify(g.num));
  // 5. A display formula: no KaTeX margins on top of the block's; a shade when it overflows.
  check(`display math has no extra KaTeX margin (${th})`, g.katexMargin.every(m => m === '0px'), JSON.stringify(g.katexMargin));
  check(`a formula block carries the overflow shade (${th})`, /gradient/.test(g.mathBg) && g.longOverflows, JSON.stringify([g.mathBg.slice(0, 60), g.longOverflows]));
  // 10. Heading levels: h4 has room above it, h5/h6 some; h6 is quieter than h5.
  check(`h4/h5/h6 keep space above (${th})`, Math.abs(g.h4.mt - 0.6 * g.rem) < 0.5 && Math.abs(g.h5.mt - 0.3 * g.rem) < 0.5 && Math.abs(g.h6.mt - 0.3 * g.rem) < 0.5, JSON.stringify([g.h4, g.h5, g.h6]));
  check(`h6 is smaller and quieter than h5, not uppercase (${th})`, g.h6.fs < g.h5.fs && g.h6.color !== g.h5.color && g.h6.tt === 'none', JSON.stringify([g.h5, g.h6]));
  // 11, 12. Nested numbered lists: i, then a. Long numbered lists: a wider indent.
  check(`nested numbered lists use roman, then letters (${th})`, g.ol2 === 'lower-roman' && g.ol3 === 'lower-alpha', JSON.stringify([g.ol2, g.ol3]));
  check(`3, 4 and 5 digit numbered lists widen the indent (${th})`, [2.1, 2.6, 3.1].every((v, i) => Math.abs(g.w[i] - v) < 0.01), JSON.stringify(g.w));

  // 5. Nothing to scroll, no shade: the formula block's right edge is the page.
  const short = await page.evaluate(() => { const e = document.getElementById('m-short'); e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return { x: r.right - 3, y: r.top + r.height / 2 }; });
  const px = PNG.sync.read(await page.screenshot({ clip: { x: short.x, y: short.y, width: 1, height: 1 } })).data;
  const bgc = dark ? [30, 30, 31] : [255, 255, 255];
  check(`a formula that fits shows no shade at its edge (${th})`, [0, 1, 2].every(i => Math.abs(px[i] - bgc[i]) <= 2), JSON.stringify([...px.subarray(0, 3)]));

  // 7. Hover shows the full underline.
  await page.evaluate(() => document.getElementById('lnk').scrollIntoView({ block: 'center' }));
  await page.hover('#lnk');
  const hov = await page.evaluate(() => { const s = getComputedStyle(document.getElementById('lnk')); return [s.textDecorationColor, s.color]; });
  check(`hovering a link shows the full underline (${th})`, hov[0] === hov[1], JSON.stringify(hov));

  // 17. Code tools: Wrap and Copy look alike, filled under the pointer; the
  //     language label is quieter; the fade reaches only a little over the code.
  const cb = '.code-block[data-lang="sh"]';
  await page.evaluate(s => document.querySelector(s).scrollIntoView({ block: 'center' }), cb);
  await page.hover(`${cb} pre`);
  const look = await page.evaluate(s => {
    const k = ['border-top-width', 'border-top-left-radius', 'background-color', 'color', 'font-size', 'padding-left', 'padding-top', 'box-shadow'];
    const st = e => Object.fromEntries(k.map(p => [p, getComputedStyle(e).getPropertyValue(p)]));
    const c = document.querySelector(s);
    return { wrap: st(c.querySelector('.cb-wrap')), copy: st(c.querySelector('.cb-copy')), lang: st(c.querySelector('.cb-lang')),
      toolsPad: parseFloat(getComputedStyle(c.querySelector('.cb-tools')).paddingLeft) };
  }, cb);
  check(`Wrap and Copy share one style (${th})`, JSON.stringify(look.wrap) === JSON.stringify(look.copy) && look.copy['box-shadow'] === 'none' && look.copy['border-top-width'] === '0px' && parseFloat(look.copy['border-top-left-radius']) >= 9, JSON.stringify(look));
  check(`language label is quieter than the buttons (${th})`, look.lang.color !== look.copy.color && parseFloat(look.lang['font-size']) < parseFloat(look.copy['font-size']), JSON.stringify([look.lang, look.copy]));
  check(`code tools fade over at most 14 px of code (${th})`, look.toolsPad <= 14, String(look.toolsPad));
  await page.hover(`${cb} .cb-copy`);
  const hovFill = await page.evaluate(s => [getComputedStyle(document.querySelector(`${s} .cb-copy`)).backgroundColor, getComputedStyle(document.documentElement).getPropertyValue('--fill-2').trim()], cb);
  const fill2 = await page.evaluate(c => { const d = document.createElement('div'); d.style.color = c; document.body.appendChild(d); const v = getComputedStyle(d).color; d.remove(); return v; }, hovFill[1]);
  check(`a code button fills under the pointer (${th})`, hovFill[0] === fill2, JSON.stringify([hovFill[0], fill2]));

  // 14, 16. Marks: read marks are a hairline, an edited mark in a grey accent
  //         stays a full bar; the removed-text popover is raised and unstruck;
  //         word diff keeps a space between a removal and its replacement.
  await page.evaluate(() => window.readout.setAppearance({ accent: '#8c8c8c' }));
  const [ms, rs] = [vslot('id="p-mod"'), vslot('id="p-read"')];
  await page.evaluate(([m, r]) => window.readout.apply({ version: 2, reset: false, rewrite: false,
    ops: [{ op: 'replace', slot: m, kind: 'paragraph', change: 'content', html: '<p id="p-mod">Modified now.</p>' }],
    marks: [{ slot: m, kind: 'modified', diff: 'Modified <del>before</del><ins>now</ins>.' }],
    deletions: [{ id: 5, after: r, count: 1, preview: 'Removed text.' }], toc: [], tasks: { done: 0, total: 0 } }), [ms, rs]);
  const mk = await page.evaluate(([m, r]) => {
    const a = document.querySelector(`.blk[data-slot="${m}"]`), b = document.querySelector(`.blk[data-slot="${r}"]`);
    a.classList.remove('m-read'); b.classList.add('m-modified', 'm-read');
    const s = e => { const c = getComputedStyle(e, '::before'); return { w: c.width, o: c.opacity, bg: c.backgroundColor }; };
    return { mod: s(a), read: s(b) };
  }, [ms, rs]);
  check(`with a grey accent an unread edit is not drawn like a read mark (${th})`, parseFloat(mk.mod.w) >= 3 && parseFloat(mk.read.w) <= 1, JSON.stringify(mk));
  await page.evaluate(m => window.readout.toggleDiff(m), ms);
  await page.evaluate(() => document.querySelector('.del-mark > button').click());
  const pop = await page.evaluate(() => {
    const p = document.querySelector('.del-pop'), cs = getComputedStyle(p);
    const ins = document.querySelector('.wd-body del + ins');
    return { deco: cs.textDecorationLine, bg: cs.backgroundImage, base: cs.backgroundColor, shadow: cs.boxShadow,
      page: getComputedStyle(document.documentElement).backgroundColor, insMl: ins ? parseFloat(getComputedStyle(ins).marginLeft) / parseFloat(getComputedStyle(ins).fontSize) : null };
  });
  check(`removed text is shown without strike-through, tinted (${th})`, pop.deco === 'none' && /gradient/.test(pop.bg), JSON.stringify(pop));
  check(`the removed-text popover is raised above the page (${th})`, dark ? pop.base !== pop.page : pop.shadow !== 'none', JSON.stringify(pop));
  check(`word diff keeps a space between a removal and its replacement (${th})`, Math.abs(pop.insMl - 0.25) < 0.01, JSON.stringify(pop.insMl));

  // 15. Increase contrast. Playwright's WebKit cannot emulate
  //     prefers-contrast, so the block's rules are applied directly.
  await page.evaluate(() => {
    for (const sh of document.styleSheets) for (const r of [...sh.cssRules]) {
      if (r.media && /prefers-contrast:\s*more/.test(r.conditionText)) {
        const st = document.createElement('style'); st.id = 'contrast-more';
        st.textContent = [...r.cssRules].map(x => x.cssText).join('\n');
        document.head.appendChild(st);
      }
    }
  });
  const hc = await page.evaluate(([m, r]) => {
    const cs = getComputedStyle(document.documentElement);
    const a = document.querySelector(`.blk[data-slot="${m}"]`), b = document.querySelector(`.blk[data-slot="${r}"]`);
    return { found: !!document.getElementById('contrast-more'), t2: cs.getPropertyValue('--text-2').trim(), t3: cs.getPropertyValue('--text-3').trim(),
      rule: cs.getPropertyValue('--rule').trim(), modW: getComputedStyle(a, '::before').width, modO: getComputedStyle(a, '::before').opacity,
      readW: getComputedStyle(b, '::before').width, panel: getComputedStyle(document.querySelector('.wd-panel')).boxShadow, pop: getComputedStyle(document.querySelector('.del-pop')).boxShadow };
  }, [ms, rs]);
  const hcWant = dark ? { t2: '#c4c4ca', t3: '#a1a1a7', rule: '#6c6c72' } : { t2: '#46464c', t3: '#636369', rule: '#b4b4bb' };
  check(`increase contrast strengthens secondary text and rules (${th})`, hc.found && hc.t2 === hcWant.t2 && hc.t3 === hcWant.t3 && hc.rule === hcWant.rule, JSON.stringify(hc));
  // WebKit reports no opacity for ::before: read the bar's pixel instead
  // (the grey accent at full strength is rgb(140, 140, 140)).
  await page.waitForTimeout(700);   // the marks' colour transition
  const bar = await page.evaluate(m => { const b = document.querySelector(`.blk[data-slot="${m}"]`); b.scrollIntoView({ block: 'center' }); const r = b.getBoundingClientRect(); return { x: r.left + 12, y: r.top + 8 }; }, ms);
  const barPx = [...PNG.sync.read(await page.screenshot({ clip: { x: bar.x, y: bar.y, width: 1, height: 1 } })).data.subarray(0, 3)];
  check(`increase contrast: solid 4 px change marks (${th})`, hc.modW === '4px' && barPx.every(v => Math.abs(v - 140) <= 3) && parseFloat(hc.readW) >= 2, JSON.stringify({ ...hc, barPx }));
  check(`increase contrast: the diff panel and popover have edges (${th})`, /inset/.test(hc.panel) && hc.pop !== 'none', JSON.stringify(hc));
  await page.close();
}

// 5. Printed, a formula wider than the page wraps instead of being cut off;
//    a wide table goes back to the page's width.
page = await open(600);
await page.evaluate(p => window.readout.apply(p), v34);
await settleMath(page);
await page.emulateMedia({ media: 'print' });
const pm = await page.evaluate(() => {
  const m = document.getElementById('m-long'), k = m.querySelector('.katex-display > .katex');
  const w = document.getElementById('wide');
  return { mFits: m.scrollWidth <= m.clientWidth + 1, katexRight: Math.round(k.getBoundingClientRect().right), mRight: Math.round(m.getBoundingClientRect().right),
    ws: getComputedStyle(k).whiteSpace, tFits: w.scrollWidth <= w.clientWidth + 1, bg: getComputedStyle(m).backgroundImage };
});
check('a long formula wraps to the printed page', pm.mFits && pm.katexRight <= pm.mRight + 1 && pm.ws === 'normal' && pm.bg === 'none', JSON.stringify(pm));
check('a wide table still wraps to the printed page', pm.tFits, JSON.stringify(pm));
await page.close();

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all typography checks passed');
process.exit(failures ? 1 : 0);
