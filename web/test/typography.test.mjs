// Typography and layout details of the reader (3.3 refinements), in WebKit.
// Usage: node test/typography.test.mjs  (requires web/build.mjs to have run)
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { PNG } from 'pngjs';
import { collectPageErrors } from './pageerrors.mjs';

const WEB = process.env.READOUT_WEB_DIR || 'build/Web';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
// A solid red 16 x 16 PNG for the inline-icon check.
const icon = new PNG({ width: 16, height: 16 });
for (let i = 0; i < icon.data.length; i += 4) icon.data.set([220, 0, 0, 255], i);
const ICON = PNG.sync.write(icon);
const requests = [];   // every path the pages asked for, in order
const delays = [];     // [pattern, ms]: responses held back (a slow grammar import)
const server = http.createServer(async (req, res) => {
  const u = decodeURIComponent(req.url.split('?')[0]);
  requests.push(u);
  const held = delays.find(([re]) => re.test(u));
  if (held) await new Promise(r => setTimeout(r, held[1]));
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
  collectPageErrors(page, errors);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await page.goto(`${base}/reader.html`);
  await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(d => window.readout.setAppearance({ dark: d, accent: '#0a84ff', fontSize: 16 }), dark);
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

// 9. The change bar lines up with the heading's first line (3.9 E9: no
//    section link in the gutter beside it any more).
const align = await page.evaluate(() => {
  const out = [];
  for (const blk of document.querySelectorAll('.k-heading')) {
    const h = blk.querySelector('h1, h2');
    const r = h.getBoundingClientRect();
    const lh = parseFloat(getComputedStyle(h).lineHeight);
    const barTop = parseFloat(getComputedStyle(blk, '::before').top) + blk.getBoundingClientRect().top;
    out.push({ id: h.id, lh: Math.round(lh), bar: Math.round(barTop - r.top), link: !!blk.querySelector('.h-link') });
  }
  return out;
});
check('no section link in the heading\'s gutter', align.length > 0 && align.every(a => !a.link), JSON.stringify(align));
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
// 3.9 E13: front matter is metadata: smaller than the body's small text, keys not bold.
const fm = await page.evaluate(() => {
  const root = getComputedStyle(document.documentElement), px = v => parseFloat(v) * parseFloat(root.fontSize);
  return { size: parseFloat(getComputedStyle(document.querySelector('.front-matter')).fontSize), xs: px(root.getPropertyValue('--fs-xs')),
    key: +getComputedStyle(document.querySelector('.fm-key')).fontWeight };
});
check('front matter is set small, its keys not bold', fm.size === fm.xs && fm.key <= 500, JSON.stringify(fm));

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
const langs = await page.evaluate(() => [...document.querySelectorAll('#ro-doc > .chunk > .blk')].map(b => b.lang || ''));
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
// On whole pixels: a clip at a fractional position starts a pixel early, on the page.
const iconBox = await page.evaluate(() => { const r = document.querySelector('img[src="icon.png"]').getBoundingClientRect(); return { x: Math.round(r.left), y: Math.round(r.top), width: r.width, height: r.height }; });
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
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p.goto(`${base}/reader.html`);
  await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
  return p;
}
const TOKENS = ['--bg', '--text', '--text-2', '--text-3', '--rule', '--fill', '--fill-2', '--link', '--accent-soft',
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
  // 3.5: 12 px (was 28): the document starts close under the toolbar.
  check(`first heading sits 12 px under the toolbar at insets 0/52/80 (${th})`, tops[0] === 12 && tops[1] === 64 && tops[2] === 92, JSON.stringify(tops));

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
      alertBorder: cs(alert).borderLeftWidth, alertShadow: cs(alert).boxShadow, alertFill: cs(alert).backgroundColor,
      alertTitle: cs(alert.querySelector('.alert-title')).color,
      noteColor: (d => { d.style.color = 'var(--note)'; document.body.appendChild(d); const c = cs(d).color; d.remove(); return c; })(document.createElement('div')),
      headless: cs($('#headless thead')).display, headed: cs($('#wide thead')).display,
      num: [cs($('#nums td.num')).textAlign, cs($('#nums th.num')).textAlign, cs($('#nums td')).textAlign],
      katexMargin: [cs(ms.querySelector('.katex-display')).marginTop, cs(ms.querySelector('.katex-display')).marginBottom], mathBg: cs(ms).backgroundImage,
      longOverflows: $('#m-long').scrollWidth > $('#m-long').clientWidth,
      h4: h('v4'), h5: h('v5'), h6: h('v6'), text3: cs(document.documentElement).getPropertyValue('--text-3').trim(), rem: parseFloat(cs(document.documentElement).fontSize),
      pageBg: cs(document.documentElement).backgroundColor,
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
  // 8. 3.9 E2: an alert has no coloured edge (beside a change bar it read
  //    as a second one); its fill and coloured title stay.
  check(`an alert has no coloured edge, its fill and title colour stay (${th})`,
    g.alertBorder === '0px' && g.alertShadow === 'none' && g.alertFill !== 'rgba(0, 0, 0, 0)' && g.alertTitle === g.noteColor, JSON.stringify([g.alertBorder, g.alertShadow, g.alertFill, g.alertTitle, g.noteColor]));
  // 9. An empty header row is hidden; a real one is not.
  check(`an empty header row is hidden (${th})`, g.headless === 'none' && g.headed !== 'none', JSON.stringify([g.headless, g.headed]));
  // 13. Numeric columns align right.
  check(`numeric cells align right (${th})`, g.num[0] === 'right' && g.num[1] === 'right' && g.num[2] !== 'right', JSON.stringify(g.num));
  // 5. A display formula: no KaTeX margins on top of the block's; a shade when it overflows.
  check(`display math has no extra KaTeX margin (${th})`, g.katexMargin.every(m => m === '0px'), JSON.stringify(g.katexMargin));
  check(`a formula block carries the overflow shade (${th})`, /gradient/.test(g.mathBg) && g.longOverflows, JSON.stringify([g.mathBg.slice(0, 60), g.longOverflows]));
  // 10. Heading levels: h4 has room above it, h5/h6 some; h6 is quieter than h5.
  check(`h4/h5/h6 keep space above (${th})`, Math.abs(g.h4.mt - 0.6 * g.rem) < 0.5 && Math.abs(g.h5.mt - 0.3 * g.rem) < 0.5 && Math.abs(g.h6.mt - 0.3 * g.rem) < 0.5, JSON.stringify([g.h4, g.h5, g.h6]));
  const ratio = (a, b) => { const lum = c => { const [r, gg, bb] = c.match(/[\d.]+/g).slice(0, 3).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * gg + 0.0722 * bb; };
    const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  check(`h6 is smaller than h5, not uppercase, and meets AA (${th})`, g.h6.fs < g.h5.fs && g.h6.tt === 'none' && ratio(g.h6.color, g.pageBg) >= 4.5, JSON.stringify([g.h5, g.h6, g.pageBg]));
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

  // 14, 16. Marks (3.9 E1, E3): one bar for every change at full strength,
  //         3:1 on the page with the default and a grey (Graphite) accent
  //         (an edit at 55% was 2.0:1, 1.8:1 in grey); a ticked box's change
  //         is that bar, not a dot; a read mark fades to nothing (not a grey
  //         hairline). The removed-text popover is raised and unstruck;
  //         word diff keeps a space between a removal and its replacement.
  const [ms, rs] = [vslot('id="p-mod"'), vslot('id="p-read"')];
  await page.evaluate(([m, r]) => window.readout.apply({ version: 2, reset: false, rewrite: false,
    ops: [{ op: 'replace', slot: m, kind: 'paragraph', change: 'content', html: '<p id="p-mod">Modified now.</p>' }],
    marks: [{ slot: m, kind: 'modified', diff: 'Modified <del>before</del><ins>now</ins>.' }],
    deletions: [{ id: 5, after: r, count: 1, preview: 'Removed text.' }], toc: [], tasks: { done: 0, total: 0 } }), [ms, rs]);
  // Measured without the bar's fade (it would be read mid-transition).
  await page.emulateMedia({ reducedMotion: 'reduce' });
  const bars = {};
  for (const accent of ['#0a84ff', '#8c8c8c']) {
    await page.evaluate(a => window.readout.setAppearance({ accent: a }), accent);
    bars[accent] = await page.evaluate(([m, r]) => {
      const rgb = s => { const n = (s.match(/[\d.]+/g) || []).map(Number); return [n[0], n[1], n[2], n[3] ?? 1]; };
      const lum = c => { const [x, y, z] = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * x + 0.7152 * y + 0.0722 * z; };
      const page = rgb(getComputedStyle(document.documentElement).backgroundColor);
      const a = document.querySelector(`.blk[data-slot="${m}"]`), b = document.querySelector(`.blk[data-slot="${r}"]`);
      const bar = (el, cls = []) => {
        el.classList.add(...cls);
        const c = getComputedStyle(el, '::before'), f = rgb(c.backgroundColor), alpha = f[3] * +c.opacity;
        const seen = [0, 1, 2].map(i => f[i] * alpha + page[i] * (1 - alpha));
        const [hi, lo] = [lum(seen), lum(page)].sort((p, q) => q - p);
        const out = { w: parseFloat(c.width), h: parseFloat(c.height), alpha, ratio: +((hi + 0.05) / (lo + 0.05)).toFixed(2) };
        el.classList.remove(...cls);
        return out;
      };
      return { edited: bar(a), added: bar(b, ['m-inserted']), ticked: bar(b, ['m-state']), read: bar(b, ['m-modified', 'm-read']) };
    }, [ms, rs]);
  }
  await page.emulateMedia({ reducedMotion: null });
  check(`every change bar reaches 3:1, with the default and a grey accent (${th})`,
    Object.values(bars).every(k => [k.edited, k.added, k.ticked].every(x => x.ratio >= 3 && x.w === 3)), JSON.stringify(bars));
  const g8 = bars['#8c8c8c'];
  check(`a ticked box is marked with the change bar, not a dot; a read mark is gone (${th})`,
    g8.ticked.w === g8.added.w && g8.ticked.h === g8.added.h && g8.ticked.h > 10 && g8.read.alpha === 0, JSON.stringify(g8));
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

// 12, 13. Real parser output (web/test/fixtures/lists-tables.md rendered by
//         ReadoutCore to lists-tables.json): numeric columns carry class
//         "num" and align right; long numbered lists carry ol-w3/4/5, top
//         level and nested, and their numbers fit inside the indent.
{
  const real = JSON.parse(readFileSync(new URL('./fixtures/lists-tables.json', import.meta.url), 'utf8'));
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), real);
  await page.waitForTimeout(300);
  const r = await page.evaluate(() => {
    const cs = e => getComputedStyle(e);
    const cells = [...document.querySelectorAll('.table-wrap tr:nth-child(1) td'), ...document.querySelectorAll('.table-wrap th')]
      .map(c => [c.tagName, c.className, cs(c).textAlign]);
    const lists = [...document.querySelectorAll('ol.ol-w3, ol.ol-w4, ol.ol-w5')].map(ol => {
      const li = ol.querySelector(':scope > li:last-child');
      const n = (+ol.getAttribute('start') || 1) + ol.children.length - 1;
      const probe = document.createElement('span');
      probe.textContent = `${n}.`;
      probe.style.cssText = `font: ${cs(li).font}; font-variant-numeric: tabular-nums; position: absolute; white-space: nowrap`;
      document.body.appendChild(probe);
      const w = probe.getBoundingClientRect().width; probe.remove();
      return { cls: ol.className, nested: !ol.classList.contains('li-block'), pad: parseFloat(cs(ol).paddingLeft), em: parseFloat(cs(ol).fontSize), marker: Math.round(w), type: cs(ol).listStyleType };
    });
    return { cells, lists };
  });
  const numOK = r.cells.every(([, cls, align]) => (cls === 'num') === (align === 'right'));
  check('parser-marked numeric columns align right, others do not', numOK && r.cells.filter(c => c[1] === 'num').length === 4, JSON.stringify(r.cells));
  const want = { 'ol-w3': 2.1, 'ol-w4': 2.6, 'ol-w5': 3.1 };
  const wOK = r.lists.length === 8 && r.lists.every(l => { const k = l.cls.match(/ol-w\d/)[0]; return Math.abs(l.pad / l.em - want[k]) < 0.01; });
  check('parser ol-w3/4/5 lists (top level and nested) get the wider indent', wOK && r.lists.some(l => l.nested), JSON.stringify(r.lists));
  // A number may hang a little into the gutter, as two-figure ones do with
  // the plain 1.5em indent, but never as far as the change bar (10-13 px into
  // the 28 px gutter): at most half an em past the indent. Without the
  // classes the 4 and 5 figure numbers would hang 14-32 px.
  check('their largest numbers stay clear of the change bar', r.lists.every(l => l.marker <= l.pad + 0.5 * l.em), JSON.stringify(r.lists));
  check('a nested list numbered past 99 keeps decimal numbers', r.lists.filter(l => l.nested).every(l => l.type === 'decimal'), JSON.stringify(r.lists));
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

// ---------- 3.5 visual refinements ----------

const lum = c => { const [r, gg, bb] = c.slice(0, 3).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * gg + 0.0722 * bb; };
const contrastOf = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return +((x + 0.05) / (y + 0.05)).toFixed(2); };
// A colour as the page computes it (rgb(), rgba() or color(srgb …)), 0-255 with alpha 0-1.
const parseColor = s => {
  const n = (s.match(/[\d.]+/g) || []).map(Number);
  if (/^color\(srgb/.test(s)) return [n[0] * 255, n[1] * 255, n[2] * 255, n[3] ?? 1];
  return [n[0], n[1], n[2], n[3] ?? 1];
};
const over = (fg, bg) => [0, 1, 2].map(i => fg[i] * fg[3] + bg[i] * (1 - fg[3]));
const pixel = async (pg, x, y) => [...PNG.sync.read(await pg.screenshot({ clip: { x: Math.round(x), y: Math.round(y), width: 1, height: 1 } })).data.subarray(0, 3)];

const v35 = patch([
  ['heading', '<h1 id="t-top">Visual 3.5</h1>', { anchor: 't-top' }],
  ['paragraph', '<p id="t-p">Body text with <em id="t-em">Latin emphasis</em> and <del id="t-del">struck text</del>.</p>'],
  ['code', `<div class="code-block" id="cb-long" data-lang="ts"><pre><code>// a line too long for the column\n${longLine}\nreturn result;</code></pre></div>`],
  ['code', '<div class="code-block" id="cb-short" data-lang="sh"><pre><code>npm test</code></pre></div>'],
  ['code', `<div class="code-block" id="cb-diff" data-lang="diff"><pre><code>--- a/x.js\n+++ b/x.js\n-const b = 2;\n+const b = 3; // ${longLine}\n console.log(b);</code></pre></div>`],
  ['paragraph', '<p id="t-zh">中文里的<em id="t-zh-em">强调文字</em>不用斜体。</p>', { cjk: true }],
  ['paragraph', '<p id="t-ja">日本語の<em id="t-ja-em">強調</em>は傍点です。</p>', { cjk: true }],
  ['paragraph', '<p id="t-zh-lat">中文段落里的<em id="t-zh-lat-em">a whole English sentence in italics, 例如</em>，以及<em id="t-zh-mix-em">调用 API 接口</em>。</p>', { cjk: true }],
  ['listItem', '<ol class="li-block li-first li-last" id="t-ol" start="97"><li>Ninety-seven</li><li>Ninety-eight</li><li id="t-li99">Ninety-nine</li></ol>'],
  ['listItem', '<ul class="li-block li-first li-last"><li class="task" id="t-done"><span class="task-box checked" aria-hidden="true"></span>Done parent<ul><li class="task" id="t-open"><span class="task-box" aria-hidden="true"></span>Open sub-item</li></ul></li></ul>'],
  ['paragraph', '<p>A <mark id="t-mark">highlighted phrase</mark>.</p>'],
  ['table', '<div class="table-wrap"><table id="t-table"><thead><tr><th>K</th><th>V</th></tr></thead><tbody><tr><td>a</td><td>1</td></tr></tbody></table></div>'],
  ['footnotes', '<section class="footnotes" id="t-fn" data-footnotes><ol><li id="fn-35"><p>A note.</p></li></ol></section>'],
]);

for (const dark of [false, true]) {
  const th = dark ? 'dark' : 'light';
  page = await open(600, dark);
  await page.evaluate(() => window.readout.setAppearance({ topInset: 52 }));
  await page.evaluate(p => window.readout.apply(p), v35);
  await until(page, () => [...document.querySelectorAll('.code-block')].every(c => c.dataset.hl === 'done'));
  await page.waitForTimeout(300);

  // 3. A code block whose lines run past the column shows the right-edge
  //    shade (as a wide table does); one that fits, or one scrolled to the
  //    end, does not. Diff bands stay tinted under it.
  const fill = await page.evaluate(() => { const d = document.createElement('div'); d.style.color = 'var(--fill)'; document.body.appendChild(d); const v = getComputedStyle(d).color; d.remove(); return v; });
  const fillRGB = parseColor(fill);
  const edge = async id => {
    const r = await page.evaluate(i => { const pre = document.querySelector(`#${i} pre`); pre.scrollIntoView({ block: 'center' }); const b = pre.getBoundingClientRect(); return { x: b.right - 2, y: b.top + 14, over: pre.scrollWidth > pre.clientWidth }; }, id);
    return { ...r, px: await pixel(page, r.x, r.y) };
  };
  const long = await edge('cb-long'), short = await edge('cb-short');
  const darker = (px, base) => px.every((v, i) => (dark ? v > base[i] + 3 : v < base[i] - 3));   // the shade is 9% of the text colour
  const same = (px, base) => px.every((v, i) => Math.abs(v - base[i]) <= 2);
  check(`an overflowing code block shades its right edge (${th})`, long.over && darker(long.px, fillRGB), JSON.stringify({ long, fill }));
  check(`a code block that fits has no shade (${th})`, !short.over && same(short.px, fillRGB), JSON.stringify({ short, fill }));
  await page.evaluate(() => { const pre = document.querySelector('#cb-long pre'); pre.scrollLeft = pre.scrollWidth; });
  await page.waitForTimeout(50);
  const end = await edge('cb-long');
  check(`scrolled to the end, the shade is gone (${th})`, same(end.px, fillRGB), JSON.stringify({ end, fill }));
  const band = await page.evaluate(() => { const l = document.querySelector('#cb-diff .line.add'); const pre = l.closest('pre'); pre.scrollIntoView({ block: 'center' }); const b = l.getBoundingClientRect(), p = pre.getBoundingClientRect(); return { x: p.right - 3, mid: p.left + 40, y: b.top + b.height / 2 }; });
  const [bandEdge, bandMid] = [await pixel(page, band.x, band.y), await pixel(page, band.mid, band.y)];
  check(`a diff band stays green under the shade (${th})`, bandEdge[1] > bandEdge[0] + 4 && bandMid[1] > bandMid[0] + 4, JSON.stringify({ bandEdge, bandMid }));
  await page.evaluate(() => window.readout.setAppearance({ codeWrap: true }));
  await page.waitForTimeout(50);
  const wrapped = await edge('cb-long');
  check(`a wrapped code block has no shade (${th})`, !wrapped.over && same(wrapped.px, fillRGB), JSON.stringify(wrapped));
  await page.evaluate(() => window.readout.setAppearance({ codeWrap: false }));

  const g = await page.evaluate(() => {
    const $ = s => document.querySelector(s), cs = (e, p) => getComputedStyle(e, p);
    const rules = [];
    for (const sh of document.styleSheets) for (const r of sh.cssRules) rules.push(r.cssText);
    const em = e => {
      const dot = e.querySelector('.em-dot'), d = dot && cs(dot);
      return { style: cs(e).fontStyle, synth: cs(e).getPropertyValue('font-synthesis-style'), mark: cs(e).getPropertyValue('text-emphasis-style') || cs(e).getPropertyValue('-webkit-text-emphasis-style'),
        dots: e.querySelectorAll('.em-dot').length, text: e.textContent,
        drawn: d && { image: d.backgroundImage, top: parseFloat(d.paddingTop), bottom: parseFloat(d.paddingBottom), display: d.display } };
    };
    const root = cs(document.documentElement);
    return {
      selection: rules.filter(t => /::selection/.test(t)),
      latin: em($('#t-em')), zh: em($('#t-zh-em')), ja: em($('#t-ja-em')),
      zhLatin: em($('#t-zh-lat-em')), zhMix: em($('#t-zh-mix-em')),
      font: root.getPropertyValue('--font'), fontDisplay: root.getPropertyValue('--font-display').trim(),
      h1Font: cs($('#t-top')).fontFamily, pFont: cs($('#t-p')).fontFamily,
      del: cs($('#t-del')).color, text2: cs($('#t-p')).color, bg: root.backgroundColor,
      marker: cs($('#t-li99'), '::marker').color,
      done: cs($('#t-done')).color, open: cs($('#t-open')).color, body: cs($('#t-p')).color,
      box: cs($('#t-done > .task-box')).backgroundColor, text3: (d => { d.style.color = 'var(--text-3)'; document.body.appendChild(d); const c = cs(d).color; d.remove(); return c; })(document.createElement('div')),
      mark: cs($('#t-mark')).backgroundColor, markText: cs($('#t-mark')).color,
      sizes: { table: cs($('#t-table')).fontSize, footnotes: cs($('#t-fn')).fontSize, code: cs($('#cb-long')).fontSize,
        buttons: cs($('.cb-copy')).fontSize, lang: cs($('.cb-lang')).fontSize },
      tokens: ['--fs-sm', '--fs-code', '--fs-xs', '--flow'].map(k => root.getPropertyValue(k).trim()),
    };
  });
  // 4. Native selection colour (follows the accent, greys in an inactive window).
  check(`no custom ::selection colour (${th})`, g.selection.length === 0, JSON.stringify(g.selection));
  // 5. CJK emphasis: upright, a dot under each Chinese character and a sesame
  //    over each Japanese one (drawn per character by .em-dot, not
  //    text-emphasis, which grew the line and marked punctuation; since 3.7
  //    as the span's own background in its padding, below or above the
  //    glyph, inline so line breaking is unchanged); Latin emphasis stays
  //    italic without marks. Where the marks land is checked in pixels (T1).
  const dotted = (e, n) => e.style === 'normal' && e.synth === 'none' && /none/.test(e.mark) && e.dots === n && e.drawn?.display === 'inline' && /radial-gradient/.test(e.drawn.image);
  check(`Chinese emphasis: upright, a dot under each character (${th})`, dotted(g.zh, 4) && g.zh.drawn.bottom > 0 && g.zh.drawn.top === 0, JSON.stringify(g.zh));
  check(`Japanese emphasis: upright, a sesame over each character (${th})`, dotted(g.ja, 2) && g.ja.drawn.top > 0 && g.ja.drawn.bottom === 0, JSON.stringify(g.ja));
  check(`Latin emphasis stays italic, without marks (${th})`, g.latin.style === 'italic' && /none/.test(g.latin.mark) && g.latin.synth !== 'none' && g.latin.dots === 0, JSON.stringify(g.latin));
  // Only emphasis that is mostly CJK takes the dots: Latin emphasis in a CJK
  // block stays italic; mostly-CJK emphasis with a Latin word gets dots (on
  // its Han characters only), no slant.
  check(`Latin emphasis in a CJK block stays italic, without dots; mostly-CJK emphasis gets them (${th})`,
    g.zhLatin.style === 'italic' && /none/.test(g.zhLatin.mark) && g.zhLatin.synth !== 'none' && g.zhLatin.dots === 0
    && dotted(g.zhMix, 4), JSON.stringify({ zhLatin: g.zhLatin, zhMix: g.zhMix }));
  // 7. One system font family: -apple-system gives headings SF's display optical size.
  check(`no SF Pro names and no display stack; headings use the body font (${th})`, !/SF Pro/.test(g.font) && /-apple-system/.test(g.font) && g.fontDisplay === '' && g.h1Font === g.pFont, JSON.stringify(g));
  // 8. Struck-through text and list numbers reach AA; a ticked task greys
  //    only its own text; the dark highlight is gold, not olive, and AA.
  const bg = parseColor(g.bg);
  check(`struck-through text reaches 4.5:1 (${th})`, contrastOf(parseColor(g.del), bg) >= 4.5, `${g.del} on ${g.bg}`);
  check(`numbered list numbers reach 4.5:1 (${th})`, contrastOf(parseColor(g.marker), bg) >= 4.5, `${g.marker} on ${g.bg}`);
  check(`a ticked task greys its text, not its open sub-items (${th})`, g.done !== g.body && g.open === g.body, JSON.stringify([g.done, g.open, g.body]));
  // 3.9 E2: the accent means unread: a ticked box is a neutral fill.
  check(`a ticked box is filled in a neutral colour, not the accent (${th})`, g.box === g.text3 && g.box !== 'rgb(10, 132, 255)', JSON.stringify([g.box, g.text3]));
  const markRGB = over(parseColor(g.mark), bg);
  const hue = (([r, gg, b]) => { const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b); if (mx === mn) return 0; const h = mx === r ? (gg - b) / (mx - mn) : mx === gg ? 2 + (b - r) / (mx - mn) : 4 + (r - gg) / (mx - mn); return (h * 60 + 360) % 360; })(markRGB);
  check(`highlighted text reaches 4.5:1 on its highlight (${th})`, contrastOf(parseColor(g.markText), markRGB) >= 4.5, JSON.stringify({ markRGB, text: g.markText }));
  if (dark) check('the dark highlight is a warm gold, not olive', hue >= 30 && hue <= 46, `hue=${hue.toFixed(1)} ${JSON.stringify(markRGB)}`);
  // 9. Three small sizes: secondary text, code, labels (16 px reading size).
  check(`small type uses the three size tokens (${th})`, g.tokens.map(parseFloat).join() === '0.875,0.84,0.75,1.1' && g.sizes.table === '14px' && g.sizes.footnotes === '14px'
    && Math.abs(parseFloat(g.sizes.code) - 13.44) < 0.01 && g.sizes.buttons === '12px' && parseFloat(g.sizes.lang) < 12, JSON.stringify(g));

  // 8. Two-figure numbers sit inside the column: no ink left of it.
  const col = await page.evaluate(() => {
    const d = document.getElementById('ro-doc'), li = document.getElementById('t-li99');
    li.scrollIntoView({ block: 'center' });
    const r = li.getBoundingClientRect();
    return { left: d.getBoundingClientRect().left + parseFloat(getComputedStyle(d).paddingLeft), top: r.top, h: r.height };
  });
  const strip = PNG.sync.read(await page.screenshot({ clip: { x: Math.round(col.left) - 20, y: Math.round(col.top), width: 20, height: Math.round(col.h) } }));
  // How far ink reaches into the gutter, in px (anti-aliasing of a glyph
  // edge at the column's own pixel boundary is allowed: 1 px).
  let into = 0;
  for (let y = 0; y < strip.height; y++) for (let x = 0; x < strip.width; x++) if (Math.abs(strip.data[(y * strip.width + x) * 4] - bg[0]) > 40) into = Math.max(into, strip.width - x);
  check(`two-figure list numbers stay inside the column (${th})`, into <= 1, `ink reaches ${into} px into the gutter`);
  await page.close();
}

// 1. Quick Look (no toolbar) keeps 28 px at the top; print has none.
{
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), v35);
  await page.evaluate(() => window.readout.setAppearance({ mode: 'quicklook' }));
  const ql = await page.evaluate(() => getComputedStyle(document.getElementById('ro-doc')).paddingTop);
  check('Quick Look keeps a 28 px top', ql === '28px', ql);
  await page.close();
}

// 2. The column's width: P4.4 below (4.0: it sizes itself; no narrow or wide).

// 6. Paragraphs and items ask for better line breaks (text-wrap: pretty; a
//    no-op in a WebKit without it, which drops it from the CSSOM: read the source).
{
  const css = readFileSync(new URL('../src/reader.css', import.meta.url), 'utf8');
  check('paragraphs and list items use text-wrap: pretty', /(^|\n)p, li \{ text-wrap: pretty; \}/.test(css));
}

// 8. Printed, two- and five-figure numbers are not cut at the page edge.
{
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['listItem', '<ol class="li-block li-first li-last" id="p2" start="99"><li>Ninety-nine</li></ol>'],
    ['listItem', '<ol class="li-block li-first li-last ol-w5" id="p5" start="99999"><li>Big</li></ol>'],
  ]));
  await page.emulateMedia({ media: 'print' });
  // The printed page starts at x = 0: a number cut there has ink in the
  // first pixel column. The leftmost ink must sit clear of the edge.
  const rows = await page.evaluate(() => ['p2', 'p5'].map(id => { const r = document.getElementById(id).firstElementChild.getBoundingClientRect(); return { id, y: r.top, h: r.height, text: r.left }; }));
  const pr = [];
  for (const r of rows) {
    const shot = PNG.sync.read(await page.screenshot({ clip: { x: 0, y: Math.round(r.y), width: Math.round(r.text), height: Math.round(r.h) } }));
    let left = Infinity;
    for (let y = 0; y < shot.height; y++) for (let x = 0; x < shot.width; x++) if (shot.data[(y * shot.width + x) * 4] < 200) { left = Math.min(left, x); break; }
    pr.push({ ...r, inkLeft: left });
  }
  check('printed list numbers are not cut at the page edge', pr.every(x => x.inkLeft >= 1 && x.inkLeft < x.text), JSON.stringify(pr));
  await page.close();
}

// 8. Diagram text follows the reading size (13 px at 16 px), redrawn when it changes.
{
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([['mermaid', '<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A[Agent writes] --> B[Reader shows]</pre></div>']]));
  await until(page, () => document.querySelector('.mermaid-block.done svg'));
  const size = () => page.evaluate(() => { const l = document.querySelector('.mermaid-block svg .nodeLabel, .mermaid-block svg text'); return l ? parseFloat(getComputedStyle(l).fontSize) : 0; });
  const at16 = await size();
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 20 }));
  const ok20 = await until(page, () => { const l = document.querySelector('.mermaid-block svg .nodeLabel, .mermaid-block svg text'); return l && Math.abs(parseFloat(getComputedStyle(l).fontSize) - 16.3) < 0.2; }, 15000);
  const at20 = await size();
  check('diagram text is 13 px at the 16 px reading size', Math.abs(at16 - 13) < 0.2, String(at16));
  check('diagram text follows the reading size (16.3 px at 20 px)', ok20, String(at20));
  await page.close();
}

// The same, read at the end of the page: the redraw at the new size keeps the
// reader at the end (the diagram grows after the type has reflowed).
{
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ...Array.from({ length: 30 }, (_, i) => ['paragraph', `<p>Paragraph ${i} above the diagram, long enough to wrap once in the column at this width.</p>`]),
    ['mermaid', '<div class="mermaid-block"><pre class="mermaid-src">flowchart TD\n  A[Agent writes the plan] --> B[Reader shows it]\n  B --> C[Agent edits]\n  C --> D[Reader marks the change]</pre></div>'],
  ]));
  await page.evaluate(() => document.querySelector('.mermaid-block').scrollIntoView());
  await until(page, () => document.querySelector('.mermaid-block.done svg'));
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
  await page.waitForTimeout(300);
  const gap = () => page.evaluate(() => { const se = document.scrollingElement; return Math.round(se.scrollHeight - se.scrollTop - window.innerHeight); });
  const g0 = await gap();
  const h0 = await page.evaluate(() => document.querySelector('.mermaid-block svg').getBoundingClientRect().height);
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 20 }));
  await until(page, () => { const l = document.querySelector('.mermaid-block svg .nodeLabel, .mermaid-block svg text'); return l && parseFloat(getComputedStyle(l).fontSize) > 16; }, 15000);
  await page.waitForTimeout(400);
  const h1 = await page.evaluate(() => document.querySelector('.mermaid-block svg').getBoundingClientRect().height);
  const g1 = await gap();
  check('reading at the end, a diagram redrawn at the new size keeps the reader at the end', g0 <= 1 && g1 <= 1 && h1 > h0 + 5, JSON.stringify({ g0, g1, h0, h1 }));
  await page.close();
}

// ---------- 3.6 typesetting ----------

// A paragraph's line boxes: [top, bottom] of each line of its text.
const lineBoxes = (pg, sel) => pg.evaluate(s => {
  const el = document.querySelector(s), r = document.createRange();
  r.selectNodeContents(el);
  const lines = [];
  for (const b of r.getClientRects()) {
    if (b.width < 1) continue;
    const l = lines.find(x => b.top < x[1] - 2 && b.bottom > x[0] + 2);
    if (l) { l[0] = Math.min(l[0], b.top); l[1] = Math.max(l[1], b.bottom); } else lines.push([b.top, b.bottom]);
  }
  return { h: el.getBoundingClientRect().height, n: lines.length };
}, sel);

const zhLong = '下一行的行距应当与上一行完全相同，不因为着重号而变大；这一段足够长，可以折成两三行来检查行距，再多写几个字。';
const v36 = patch([
  ['paragraph', `<p id="e-zh">中文里的<em id="e-em">强调文字</em>不用斜体，标点<em id="e-punct">不加点。——也不加</em>，<em id="e-mix">调用 API 接口</em>。${zhLong}</p>`, { cjk: true }],
  ['paragraph', `<p id="e-plain">中文里的强调文字不用斜体，标点不加点。——也不加，调用 API 接口。${zhLong}</p>`, { cjk: true }],
  ['paragraph', '<p id="e-ja">日本語の<em id="e-ja-em">強調は傍点</em>です。</p>', { cjk: true }],
  ['paragraph', '<p>长强调：<em id="e-long">正确性属性是系统在所有有效执行中都应保持为真的特征或行为本质上是关于系统应该做什么的陈述</em>。</p>', { cjk: true }],
  ['paragraph', '<p><em id="e-whole">整段强调不加着重号</em></p>', { cjk: true }],
  ['paragraph', '<p id="s-sup">E = mc<sup>2</sup>, H<sub>2</sub>O and a note<sup>[3]</sup> in a paragraph long enough to wrap onto a second line in the column at this width.</p>'],
  ['paragraph', '<p id="s-plain">E = mc2, H2O and a note[3] in a paragraph long enough to wrap onto a second line in the column at this width.</p>'],
  ['listItem', '<ul class="li-block li-first li-last"><li class="task" id="k-zh"><span class="task-box" aria-hidden="true"></span>检查复选框是否与这一行居中</li></ul>', { cjk: true }],
  ['listItem', '<ul class="li-block li-first li-last"><li class="task" id="k-en"><span class="task-box" aria-hidden="true"></span>A Latin task item</li></ul>'],
  ['heading', '<h1 id="h-zh">中文标题</h1>', { anchor: 'h-zh', cjk: true }],
  ['heading', '<h2 id="h-ja">日本語の見出し</h2>', { anchor: 'h-ja', cjk: true }],
  ['heading', '<h1 id="h-en">Latin title</h1>', { anchor: 'h-en' }],
  ['paragraph', '<details id="d-sum"><summary>Details</summary><p>Inside.</p></details>'],
  ['alert', '<div class="alert alert-note" id="a-note"><p class="alert-title">Note</p><p>Run:</p><div class="code-block" id="a-cb" data-lang="sh"><pre><code>npm ci &amp;&amp; npm run build</code></pre></div></div>'],
  ['code', '<div class="code-block" id="c-plain" data-lang="sh"><pre><code>npm test</code></pre></div>'],
  ['code', '<div class="code-block" id="c-tree"><pre><code>web/\n├── src/\n│   └── reader.css\n└── test/</code></pre></div>'],
  ['code', '<div class="code-block" id="c-console" data-lang="console"><pre><code>$ npm test\nall checks passed</code></pre></div>'],
  ['table', '<div class="table-wrap"><table id="t-cells"><thead><tr><th>Action</th><th>Status</th><th>Notes</th></tr></thead><tbody>'
    + '<tr><td><code id="t-code">actions/configure-pages</code></td><td id="t-short">S1 / GREEN</td><td id="t-long">A longer note that is allowed to wrap onto more than one line in a narrow column like this one.</td></tr>'
    + '<tr><td><code id="t-path">src/a/<wbr>very/<wbr>long/<wbr>path/<wbr>to/<wbr>some/<wbr>deeply/<wbr>nested/<wbr>module.ts</code></td><td id="t-zh">部分覆盖</td><td id="t-br">one<br>two</td></tr></tbody></table></div>'],
]);

{
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), v36);
  await until(page, () => [...document.querySelectorAll('.code-block[data-lang]')].every(c => c.dataset.hl === 'done'));

  // T1. Emphasis dots never change the line pitch, and never mark punctuation or Latin.
  const [withEm, without] = [await lineBoxes(page, '#e-zh'), await lineBoxes(page, '#e-plain')];
  check('CJK emphasis dots keep the line pitch', withEm.n >= 2 && withEm.n === without.n && Math.abs(withEm.h - without.h) < 0.5, JSON.stringify({ withEm, without }));
  const marks = await page.evaluate(() => {
    const dots = id => [...document.getElementById(id).querySelectorAll('.em-dot')].map(d => d.textContent).join('');
    const p = document.getElementById('e-zh'), sel = getSelection(), r = document.createRange();
    r.selectNodeContents(p); sel.removeAllRanges(); sel.addRange(r);
    const copied = sel.toString(); sel.removeAllRanges();
    return { em: dots('e-em'), punct: dots('e-punct'), mix: dots('e-mix'), ja: dots('e-ja-em'), copied, text: p.textContent };
  });
  check('a dot on each Han and kana character, none on punctuation or Latin', marks.em === '强调文字' && marks.punct === '不加点也不加' && marks.mix === '调用接口' && marks.ja === '強調は傍点', JSON.stringify(marks));
  check('emphasis dots are not copied', marks.copied.replace(/\s+$/, '') === marks.text, JSON.stringify(marks));
  // Under the characters in Chinese, inside the line; over them in Japanese.
  // Found in pixels: the marks are painted red, the text black.
  // The marks are drawn in the text colour (currentColor): red, with the glyphs filled black.
  const style = await page.addStyleTag({ content: '.em-dot { color: #f00 !important; -webkit-text-fill-color: #000 }' });
  const place = {};
  for (const [k, id] of [['zh', 'e-em'], ['ja', 'e-ja-em']]) {
    const r = await page.evaluate(i => { const d = document.querySelector(`#${i} .em-dot`); d.scrollIntoView({ block: 'center' }); const g = document.createRange(); g.selectNodeContents(d); const b = g.getBoundingClientRect(), lh = parseFloat(getComputedStyle(d.closest('p')).lineHeight);
      const p = d.closest('p').getBoundingClientRect(); const line = Math.floor((b.top - p.top) / lh); return { x: b.left, w: b.width, lineTop: p.top + line * lh, lh }; }, id);
    const y0 = Math.round(r.lineTop - r.lh / 2), shot = PNG.sync.read(await page.screenshot({ clip: { x: Math.round(r.x), y: y0, width: Math.round(r.w), height: Math.round(r.lh * 2) } }));
    const red = [], ink = [];
    for (let y = 0; y < shot.height; y++) for (let x = 0; x < shot.width; x++) { const [R, G, B] = shot.data.subarray((y * shot.width + x) * 4, (y * shot.width + x) * 4 + 3); if (R - G > 70 && R - B > 70) red.push(y + y0); else if (R < 110 && G < 110 && B < 110 && y + y0 >= r.lineTop && y + y0 < r.lineTop + r.lh) ink.push(y + y0); }
    place[k] = { line: [r.lineTop, r.lineTop + r.lh], ink: [Math.min(...ink), Math.max(...ink)], mark: red.length ? [Math.min(...red), Math.max(...red)] : null };
  }
  await style.evaluate(e => e.remove());
  check('Chinese dots sit under the text, inside its line', place.zh.mark && place.zh.mark[0] > place.zh.ink[1] && place.zh.mark[1] < place.zh.line[1], JSON.stringify(place.zh));
  check('Japanese sesames sit over the text, clear of the line above', place.ja.mark && place.ja.mark[1] < place.ja.ink[0] && place.ja.mark[0] > place.ja.line[0] - 0.4 * 16, JSON.stringify(place.ja));
  // A long run or a whole paragraph: a step heavier, no dots, upright.
  const long = await page.evaluate(() => ['e-long', 'e-whole'].map(id => { const e = document.getElementById(id), cs = getComputedStyle(e); return { id, cls: e.className, dots: e.querySelectorAll('.em-dot').length, weight: cs.fontWeight, style: cs.fontStyle }; }));
  check('long or whole-paragraph CJK emphasis is upright and a step heavier, without dots', long.every(l => l.dots === 0 && l.weight === '500' && l.style === 'normal' && /cjk-em-long/.test(l.cls)), JSON.stringify(long));

  // T5. Superscripts and subscripts keep the line pitch.
  const [sup, plain] = [await lineBoxes(page, '#s-sup'), await lineBoxes(page, '#s-plain')];
  check('sup and sub keep the line pitch', sup.n >= 2 && sup.n === plain.n && Math.abs(sup.h - plain.h) < 0.5, JSON.stringify({ sup, plain }));

  // T9. A task box is centred on its first line, Latin or CJK (taller lines).
  const boxes = await page.evaluate(() => ['k-zh', 'k-en'].map(id => {
    const li = document.getElementById(id), b = li.querySelector('.task-box').getBoundingClientRect();
    const lh = parseFloat(getComputedStyle(li).lineHeight), top = li.getBoundingClientRect().top;
    return { id, off: +((b.top + b.bottom) / 2 - (top + lh / 2)).toFixed(2), boxTop: +(b.top - top).toFixed(2), lh };
  }));
  // As high on a taller CJK line as on a Latin one (the Latin place, 0.32em, as before).
  check('task boxes sit alike on a CJK and a Latin first line', Math.abs(boxes[0].off - boxes[1].off) < 0.25 && Math.abs(boxes[1].boxTop - 0.32 * 16) < 0.05, JSON.stringify(boxes));
  // T9. Han and kana headings are not tracked in; Latin ones still are.
  const track = await page.evaluate(() => ['h-zh', 'h-ja', 'h-en'].map(id => getComputedStyle(document.getElementById(id)).letterSpacing));
  check('CJK h1/h2 have no negative tracking; Latin h1 keeps it', track[0] === 'normal' || parseFloat(track[0]) === 0 ? (parseFloat(track[1]) || 0) === 0 && parseFloat(track[2]) < 0 : false, JSON.stringify(track));
  // T9. The disclosure triangle is quiet (--text-3), not text-coloured.
  const tri = await page.evaluate(() => { const s = document.querySelector('#d-sum summary'); s.scrollIntoView({ block: 'center' }); const r = s.getBoundingClientRect(); return { x: r.left, y: r.top, h: r.height, text3: getComputedStyle(document.documentElement).getPropertyValue('--text-3').trim(), color: getComputedStyle(s).color }; });
  const triShot = PNG.sync.read(await page.screenshot({ clip: { x: Math.round(tri.x), y: Math.round(tri.y), width: 14, height: Math.round(tri.h) } }));
  let darkest = 255;
  for (let i = 0; i < triShot.data.length; i += 4) darkest = Math.min(darkest, triShot.data[i]);
  check('the disclosure triangle is drawn in --text-3', darkest > 100 && darkest < 200, `darkest red channel ${darkest}, ${JSON.stringify(tri)}`);

  // T3. A code block inside an alert stands off the alert's fill (--cb-bg), its shade and toolbar too.
  const cbg = await page.evaluate(() => {
    const v = n => { const d = document.createElement('div'); d.style.color = `var(${n})`; document.body.appendChild(d); const c = getComputedStyle(d).color; d.remove(); return c; };
    const cs = s => getComputedStyle(document.querySelector(s));
    return { alert: cs('#a-note').backgroundColor, inAlert: cs('#a-cb').backgroundColor, plain: cs('#c-plain').backgroundColor, fill: v('--fill'), fill2: v('--fill-2'),
      shade: cs('#a-cb pre').backgroundImage, tools: cs('#a-cb .cb-tools').backgroundImage };
  });
  check('a code block in an alert takes --fill-2, off the alert\'s --fill', cbg.alert === cbg.fill && cbg.inAlert === cbg.fill2 && cbg.plain === cbg.fill && cbg.inAlert !== cbg.alert, JSON.stringify(cbg));
  check('its right-edge shade and toolbar fade into --fill-2', cbg.shade.includes(cbg.fill2) && cbg.tools.includes(cbg.fill2), JSON.stringify(cbg));

  // TD. Box drawing: tighter lines. TI: code in a cell at 0.9 of the cell's size.
  const misc = await page.evaluate(() => {
    const cs = s => getComputedStyle(document.querySelector(s));
    return { tree: document.getElementById('c-tree').className, treeLh: parseFloat(cs('#c-tree').lineHeight) / parseFloat(cs('#c-tree').fontSize), plainLh: parseFloat(cs('#c-plain').lineHeight) / parseFloat(cs('#c-plain').fontSize),
      td: parseFloat(cs('#t-short').fontSize), tdCode: parseFloat(cs('#t-code').fontSize) };
  });
  check('a code block with box drawing has class cb-tree and line height 1.3', /cb-tree/.test(misc.tree) && Math.abs(misc.treeLh - 1.3) < 0.01 && Math.abs(misc.plainLh - 1.55) < 0.01, JSON.stringify(misc));
  check('code in a table cell is 0.9 of the cell\'s text', Math.abs(misc.tdCode - 0.9 * misc.td) < 0.05, JSON.stringify(misc));

  // T7. A console transcript highlights as a shell session: the command, not its output.
  // Each run of text and its colour (a token in the block's own colours is its text alone: highlight.js).
  const sess = await page.evaluate(() => { const lines = [...document.querySelectorAll('#c-console .line')]; return lines.map(l => { const w = document.createTreeWalker(l, NodeFilter.SHOW_TEXT), out = []; for (let t; (t = w.nextNode());) out.push([t.data, getComputedStyle(t.parentElement).color]); return out; }); });
  const colours = sess.flat().filter(([t]) => t.trim());
  const npm = colours.find(([t]) => t.includes('npm')), out = colours.find(([t]) => t.includes('passed'));
  check('a console block highlights the command apart from its output', npm && out && npm[1] !== out[1], JSON.stringify(sess));
  // A token in the block's own colours is its text alone, an element fewer (a theme switch restyles every span).
  const own = await page.evaluate(() => { const pre = document.querySelector('#c-console pre'), st = pre.getAttribute('style') || ''; const fg = /--shiki-light:(#\w+)/.exec(st)?.[1]?.toLowerCase(), fgd = /--shiki-dark:(#\w+)/.exec(st)?.[1]?.toLowerCase(); const spans = [...document.querySelectorAll('.code-block .line span[style]')]; return { spans: spans.length, own: spans.filter(x => { const v = (x.getAttribute('style') || '').toLowerCase(); return v === `--shiki-light:${fg};--shiki-dark:${fgd}`; }).length }; });
  check('a token in the code block\'s own colours is no span of its own', own.spans > 0 && own.own === 0, JSON.stringify(own));

  // T2. Short cells and identifiers stay on one line while the table fits; a
  //     long path may break after a slash; a cell with a <br> may wrap.
  const cells = await page.evaluate(() => {
    const lines = el => { const r = document.createRange(); r.selectNodeContents(el); return new Set([...r.getClientRects()].filter(b => b.width > 0).map(b => Math.round(b.top))).size; };
    const $ = id => document.getElementById(id);
    return { code: lines($('t-code')), short: lines($('t-short')), zh: lines($('t-zh')), long: lines($('t-long')), path: (el => { const out = []; const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); for (let t; (t = w.nextNode());) for (let i = 0; i < t.data.length; i++) { const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + 1); const top = Math.round(r.getClientRects()[0].top); if (!out.length || out[out.length - 1].top !== top) out.push({ top, text: '' }); out[out.length - 1].text += t.data[i]; } return out.map(l => l.text); })($('t-path')),
      codeNw: getComputedStyle($('t-code')).whiteSpace, brNw: getComputedStyle($('t-br')).whiteSpace, scrolls: $('t-cells').parentElement.classList.contains('scrolls') };
  });
  check('short cells and identifiers in a table stay on one line', cells.code === 1 && cells.short === 1 && cells.zh === 1 && cells.codeNw === 'nowrap', JSON.stringify(cells));
  check('a long cell still wraps, a cell with a line break is left alone, a long path breaks after its slashes (ReadoutCore\'s <wbr>)', cells.long > 1 && cells.brNw !== 'nowrap' && cells.path.length > 1 && cells.path.slice(0, -1).every(l => l.endsWith('/')) && !cells.scrolls, JSON.stringify(cells));
  await page.close();
}

// T2. Short cells that no longer fit make the table scroll, as any wide table does.
{
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['table', `<div class="table-wrap"><table><thead><tr>${Array.from({ length: 9 }, (_, i) => `<th>K${i}</th>`).join('')}</tr></thead><tbody><tr>${Array.from({ length: 9 }, (_, i) => `<td><code>pkg/module-${i}</code></td>`).join('')}</tr></tbody></table></div>`],
  ]));
  await page.waitForTimeout(100);
  const t = await page.evaluate(() => { const w = document.querySelector('.table-wrap'); return { scrolls: w.classList.contains('scrolls'), page: document.scrollingElement.scrollWidth - innerWidth }; });
  check('a table of short cells too wide for the column scrolls', t.scrolls && t.page <= 0, JSON.stringify(t));
  await page.close();
}

// TB. In a wide window, a code block whose lines run past the column widens
//     to 1.35 columns (centred, the text column unchanged); one that fits
//     does not; nor in a narrower window, with wrapping on, or in print. A
//     wide table widens to the right, as far as it needs (3.7). Change bars
//     stay beside them.
{
  const tb = patch([
    ['paragraph', '<p id="b-p">The text column stays as it is.</p>'],
    ['code', `<div class="code-block" id="b-long" data-lang="ts"><pre><code>${'const result = await client.send(new GetObjectCommand({ Bucket, Key, Range }));'}</code></pre></div>`],
    ['code', `<div class="code-block" id="b-huge" data-lang="ts"><pre><code>${longLine} ${longLine}</code></pre></div>`],
    ['code', '<div class="code-block" id="b-short" data-lang="sh"><pre><code>npm test</code></pre></div>'],
    ['listItem', `<ul class="li-block li-first li-last"><li>In a list:<div class="code-block" id="b-li"><pre><code>${longLine}</code></pre></div></li></ul>`],
    ['table', `<div class="table-wrap" id="b-table"><table><thead><tr>${Array.from({ length: 10 }, (_, i) => `<th>Column ${i + 1}</th>`).join('')}</tr></thead><tbody><tr>${Array.from({ length: 10 }, (_, i) => `<td>value ${i}</td>`).join('')}</tr></tbody></table></div>`],
  ]);
  tb.marks = [{ slot: 2, kind: 'inserted' }, { slot: 1, kind: 'inserted' }, { slot: 6, kind: 'inserted' }];
  tb.deletions = [{ id: 1, after: 1, count: 1 }];
  const measure = pg => pg.evaluate(() => {
    const r = id => document.getElementById(id).getBoundingClientRect();
    const col = r('b-p'), bar = blk => { const b = blk.getBoundingClientRect(); return b.left + parseFloat(getComputedStyle(blk, '::before').left); };
    const blk = id => document.getElementById(id).closest('.blk');
    const unread = b => { const read = b.classList.contains('m-read'); b.classList.remove('m-read'); const x = bar(b); if (read) b.classList.add('m-read'); return x; };
    const pre = document.querySelector('#b-long pre'), huge = document.querySelector('#b-huge pre');
    return { col: [col.left, col.width], long: [r('b-long').left, r('b-long').width], huge: [r('b-huge').left, r('b-huge').width], short: [r('b-short').left, r('b-short').width],
      li: r('b-li').width, table: [r('b-table').left, r('b-table').width], tableScrolls: document.getElementById('b-table').classList.contains('scrolls'),
      longScrolls: pre.scrollWidth > pre.clientWidth, hugeScrolls: huge.scrollWidth > huge.clientWidth,
      barGap: { long: r('b-long').left - bar(blk('b-long')), para: col.left - bar(blk('b-p')) },
      // As unread (a read mark has faded out).
      bars: { para: unread(blk('b-p')), table: unread(blk('b-table')),
        deletion: (b => b.getBoundingClientRect().left + parseFloat(getComputedStyle(b, '::before').left))(document.querySelector('.del-mark > button')) },
      vw: innerWidth,
      sideways: document.scrollingElement.scrollWidth - innerWidth };
  });
  page = await open(1600);
  await page.evaluate(p => window.readout.apply(p), tb);
  await until(page, () => [...document.querySelectorAll('.code-block[data-lang]')].every(c => c.dataset.hl === 'done'));
  await page.waitForTimeout(100);
  const w = await measure(page);
  const M = w.col[1], centre = w.col[0] + M / 2;
  const centred = ([l, wd]) => Math.abs(l + wd / 2 - centre) < 1;
  check('at 1600 px a long code block widens to 1.35 columns, centred, and no longer scrolls', Math.abs(w.long[1] - 1.35 * M) < 1 && centred(w.long) && !w.longScrolls, JSON.stringify(w));
  check('a longer one widens as far and scrolls (with its shade)', Math.abs(w.huge[1] - 1.35 * M) < 1 && centred(w.huge) && w.hugeScrolls, JSON.stringify(w));
  check('a code block that fits, and one in a list, keep the column', Math.abs(w.short[1] - M) < 0.5 && w.short[0] === w.col[0] && w.li < M, JSON.stringify(w));
  // 3.7 (T9): to the right only, so its first column and its change bar stay on the text's edge.
  check('a wide table widens to the right only, as far as it needs', w.tableScrolls && Math.abs(w.table[0] - w.col[0]) < 0.5 && w.table[1] > M + 10 && w.table[1] <= 1.35 * M + 1, JSON.stringify(w));
  check('the change bar stays beside a widened code block, as beside text', Math.abs(w.barGap.long - w.barGap.para) < 0.5 && w.sideways <= 0, JSON.stringify(w));
  check('a widened table\'s change bar and a deletion marker line up with the text\'s change bars', Math.abs(w.bars.table - w.bars.para) < 0.5 && Math.abs(w.bars.deletion - w.bars.para) < 0.5, JSON.stringify(w.bars));
  const tbPrint = await (async () => { await page.emulateMedia({ media: 'print' }); const m = await page.evaluate(() => [document.getElementById('b-long').getBoundingClientRect().width, document.getElementById('b-p').getBoundingClientRect().width]); await page.emulateMedia({ media: 'screen' }); return m; })();
  check('printed, a long code block keeps the text width', Math.abs(tbPrint[0] - tbPrint[1]) < 0.5, JSON.stringify(tbPrint));
  await page.evaluate(() => window.readout.setAppearance({ codeWrap: true }));
  const wrapped = await measure(page);
  check('with code wrapping on, code blocks keep the column', Math.abs(wrapped.long[1] - wrapped.col[1]) < 0.5, JSON.stringify(wrapped));
  // 4.0: the column follows the type size (35 rem): code widens from it in step.
  await page.evaluate(() => window.readout.setAppearance({ codeWrap: false, fontSize: 20 }));
  await page.waitForTimeout(100);
  const big = await page.evaluate(() => { const r = id => document.getElementById(id).getBoundingClientRect(); return { col: [r('b-p').left, r('b-p').width], long: [r('b-long').left, r('b-long').width], huge: [r('b-huge').left, r('b-huge').width], sideways: document.scrollingElement.scrollWidth - innerWidth }; });
  check('at 20 px the column is 35 rem and code that runs past it widens to 1.35 columns', Math.abs(big.col[1] - 700) < 0.5 && Math.abs(big.long[1] - 1.35 * 700) < 1 && Math.abs(big.huge[1] - 1.35 * 700) < 1 && big.sideways <= 0, JSON.stringify(big));
  await page.close();
  for (const width of [860, 1200]) {
    page = await open(width);
    await page.evaluate(p => window.readout.apply(p), tb);
    await page.waitForTimeout(150);
    const n = await measure(page);
    const fits = width === 1200;   // 1.35 x 560 px and 4 rem each side (884 px) fit in 1200 px, not in 860
    check(`at ${width} px code ${fits ? 'widens' : 'keeps the column'}`, fits ? Math.abs(n.long[1] - 1.35 * n.col[1]) < 1 : Math.abs(n.long[1] - n.col[1]) < 0.5 && n.sideways <= 0, JSON.stringify(n));
    // Widening to the right only, a table keeps 4 rem from the window's edge.
    check(`at ${width} px a table keeps the text's left edge and 4 rem from the window's edge`, Math.abs(n.table[0] - n.col[0]) < 0.5 && n.table[0] + n.table[1] <= n.vw - 64 + 0.5 && n.sideways <= 0, JSON.stringify(n));
    await page.close();
  }
}

// P11. Quick Look loads no grammar (nor Shiki) before a code block needs one;
//      the app preloads the three agent output uses most.
{
  const grammarRequests = () => requests.filter(u => /\/chunks\/(shellscript|json|typescript|javascript|python|swift|go|rust|yaml|diff|markdown|sql)-/.test(u));
  const openQuick = async quick => {
    const pg = await browser.newPage({ viewport: { width: 800, height: 700 } });
    pg.on('pageerror', e => errors.push(String(e)));
    await pg.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
    requests.length = 0;
    await pg.goto(`${base}/reader.html`);
    await until(pg, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
    await pg.evaluate(q => window.readout.setAppearance({ dark: false, fontSize: 15, ...(q ? { mode: 'quicklook' } : {}) }), quick);
    await pg.evaluate(p => window.readout.apply(p), patch([['paragraph', '<p>No code here.</p>']]));
    await pg.waitForTimeout(1500);
    return pg;
  };
  page = await openQuick(true);
  const ql = grammarRequests().length;
  await page.evaluate(p => window.readout.apply(p), patch([['code', '<div class="code-block" id="q-cb" data-lang="go"><pre><code>package main</code></pre></div>']], 2));
  const qlDone = await until(page, () => document.getElementById('q-cb')?.dataset.hl === 'done');
  const qlAfter = grammarRequests();
  check('Quick Look loads no grammar before a code block needs one', ql === 0, `${ql} requested`);
  check('Quick Look highlights the code it shows, loading only its grammar', qlDone && qlAfter.length === 1 && /go-/.test(qlAfter[0]), JSON.stringify(qlAfter));
  // Markdown's front matter is YAML: loaded with it, whatever is preloaded,
  // so the block highlights the same in Quick Look, a warmed tab or a cold one.
  await page.evaluate(p => window.readout.apply(p), patch([['code', '<div class="code-block" id="q-fm" data-lang="markdown"><pre><code>---\nname: plan\n---\n# Title</code></pre></div>']], 3));
  const fmDone = await until(page, () => document.getElementById('q-fm')?.dataset.hl === 'done');
  const fmKey = await page.evaluate(() => [...document.querySelectorAll('#q-fm pre.shiki span')].some(s => s.textContent === 'name'));
  check('a Markdown block with front matter highlights its YAML', fmDone && fmKey, JSON.stringify({ fmDone, fmKey }));
  await page.close();
  page = await openQuick(false);
  // Only the three agent output uses most: each preloaded grammar costs every tab memory.
  const preloaded = grammarRequests().map(u => u.match(/\/chunks\/([a-z]+)-/)[1]).sort().join(',');
  check('the app preloads shell, JSON and TypeScript, and nothing else', preloaded === 'json,shellscript,typescript', JSON.stringify(grammarRequests()));
  await page.close();

  // 3.9.1: the spare page also loads the rest of 3.8's twelve, so a
  // warm open colours them in its first paint as 3.8 did.
  requests.length = 0;
  page = await open(800);
  await page.evaluate(() => window.readout.warm());
  const warmDone = await until(page, () => performance.getEntriesByName('readout-hl-warm').length > 0, 40000);
  const spareSet = grammarRequests().map(u => u.match(/\/chunks\/([a-z]+)-/)[1]).sort().join(',');
  check("the spare page loads 3.8's twelve grammars", warmDone && spareSet === 'diff,go,javascript,json,markdown,python,rust,shellscript,sql,swift,typescript,yaml', JSON.stringify({ warmDone, spareSet }));
  await page.close();

  // 3.9.1: the fence languages of a document being parsed (readout.prepare)
  // are loaded and compiled before its apply, which then colours their
  // blocks in its first paint: a language never preloaded (Kotlin), and a
  // name as written in the fence (an alias, upper case).
  // blocks: [id, lang, code]; each block's state when the apply returns,
  // and whether its YAML front matter (if any) has a key token of its own.
  const firstPaint = (pg, blocks) => pg.evaluate(blocks => {
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
      ops: blocks.map(([id, lang, code], i) => ({ op: 'insert', slot: i + 1, after: i, kind: 'code', cjk: false, html: `<div class="code-block" id="${id}" data-lang="${lang}"><pre><code>${code}</code></pre></div>` })) });
    return Object.fromEntries(blocks.map(([id]) => {
      const cb = document.getElementById(id);
      return [id, { hl: cb.dataset.hl, colored: !!cb.querySelector('pre.shiki span[style]'), key: [...cb.querySelectorAll('pre.shiki span')].some(s => s.textContent === 'name') }];
    }));
  }, blocks);
  const FM = ['p-fm', 'markdown', '---\nname: plan\n---\n# Title'];
  const ok = b => b.hl === 'done' && b.colored;
  requests.length = 0;
  page = await open(800);
  await page.evaluate(() => window.readout.prepare(['Kotlin', 'kt', 'no-such-language', 'md']));
  // Kotlin, Markdown, and YAML with it (a Markdown block may start with front matter).
  const appIn = await until(page, () => performance.getEntriesByName('readout-hl-prepared').length >= 3, 20000);
  const app = await firstPaint(page, [['p-kt', 'kotlin', 'fun main() { println("hi") } // c'], FM]);
  check('a fence language prepared while the document parses is coloured in its first paint', appIn && ok(app['p-kt']), JSON.stringify({ appIn, app }));
  check('a prepared Markdown fence starting with front matter has its YAML in its first paint', ok(app['p-fm']) && app['p-fm'].key, JSON.stringify(app['p-fm']));
  await page.close();
  // Quick Look too, loading only what the document names (and YAML with Markdown).
  requests.length = 0;
  page = await browser.newPage({ viewport: { width: 800, height: 700 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await page.goto(`${base}/reader.html`);
  await until(page, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(() => { window.readout.setAppearance({ dark: false, fontSize: 15, mode: 'quicklook' }); window.readout.prepare(['go', 'markdown']); });
  const qlIn = await until(page, () => performance.getEntriesByName('readout-hl-prepared').length >= 3, 20000);
  const qlPrepared = grammarRequests().map(u => u.match(/\/chunks\/([a-z]+)-/)[1]).sort().join(',');
  const qlp = await firstPaint(page, [['p-go', 'go', 'package main\nfunc main() {}'], FM]);
  check('Quick Look prepares only the grammars the document names, coloured in its first paint', qlIn && qlPrepared === 'go,markdown,yaml' && ok(qlp['p-go']), JSON.stringify({ qlIn, qlPrepared, qlp }));
  check('in Quick Look a prepared Markdown fence starting with front matter has its YAML in its first paint', ok(qlp['p-fm']) && qlp['p-fm'].key, JSON.stringify(qlp['p-fm']));
  await page.close();
}

// P10. A diagram whose source keeps changing (an agent writing it) keeps its
//      last drawing and is drawn again once the source has been still; a page
//      with a flowchart loads Mermaid and ELK in idle time, before it is reached.
{
  page = await open(900);
  const mm = (label, version) => patch([['mermaid', `<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A[${label}] --> B[End]</pre></div>`]], version);
  await page.evaluate(p => window.readout.apply(p), mm('First', 1));
  await until(page, () => document.querySelector('.mermaid-block.done svg'));
  const label = () => page.evaluate(() => document.querySelector('.mermaid-block svg')?.textContent.includes('Second') ? 'Second' : document.querySelector('.mermaid-block svg')?.textContent.includes('First') ? 'First' : null);
  const replace = (l, v) => page.evaluate(([l, v]) => window.readout.apply({ version: v, reset: false, rewrite: false, ops: [{ op: 'replace', slot: 1, kind: 'mermaid', cjk: false, change: 'content', html: `<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A[${l}] --&gt; B[End</pre></div>` }], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }), [l, v]);
  const seen = [];
  // Streamed: a broken diagram growing every 100 ms.
  for (let i = 0; i < 6; i++) { await replace(`Sec${'o'.repeat(i)}`, 2 + i); await page.waitForTimeout(100); seen.push(await label()); }
  const errorsShown = await page.evaluate(() => document.querySelectorAll('.mermaid-error').length);
  check('while its source keeps changing, a diagram keeps its last drawing', seen.every(l => l === 'First') && errorsShown === 0, JSON.stringify({ seen, errorsShown }));
  await page.evaluate(() => window.readout.apply({ version: 20, reset: false, rewrite: false, ops: [{ op: 'replace', slot: 1, kind: 'mermaid', cjk: false, change: 'content', html: '<div class="mermaid-block"><pre class="mermaid-src">flowchart LR\n  A[Second] --&gt; B[End]</pre></div>' }], marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }));
  await page.waitForTimeout(150);
  const before = await label();
  const redrawn = await until(page, async () => document.querySelector('.mermaid-block svg')?.textContent.includes('Second'), 5000);
  check('once its source is still, the diagram is drawn again', before === 'First' && redrawn, JSON.stringify({ before, redrawn }));
  await page.close();

  requests.length = 0;
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ...Array.from({ length: 60 }, (_, i) => ['paragraph', `<p>Paragraph ${i} above the diagram, long enough to fill the column at this width.</p>`]),
    ['mermaid', '<div class="mermaid-block" id="far"><pre class="mermaid-src">flowchart TD\n  A[Far below] --> B[The fold]</pre></div>'],
  ]));
  const prefetched = await (async () => { for (let i = 0; i < 100; i++) { if (requests.some(u => /mermaid\/chunks\/.*elk-/.test(u))) return true; await page.waitForTimeout(50); } return false; })();
  const drawn = await page.evaluate(() => document.getElementById('far').classList.contains('done'));
  check('a page with a flowchart loads Mermaid and ELK in idle time, before the diagram is reached', prefetched && !drawn, JSON.stringify({ prefetched, drawn, mermaid: requests.filter(u => /mermaid/.test(u)).length }));
  await page.close();
}

// T9. The empty state reaches AA (--text-2).
{
  page = await open(600);
  await page.evaluate(p => window.readout.apply(p), patch([]));
  const c = await page.evaluate(() => {
    const e = document.getElementById('ro-empty');
    return { empty: e && getComputedStyle(e).color, bg: getComputedStyle(document.documentElement).backgroundColor };
  });
  check('the empty note reaches 4.5:1', !c.empty || contrastOf(parseColor(c.empty), parseColor(c.bg)) >= 4.5, JSON.stringify(c));
  await page.close();
}

// P3. The spare page compiles the common grammars in idle time once warmed,
//     but stops as soon as it shows a document (a window took it).
{
  page = await open(700);
  await page.evaluate(() => window.readout.warm());
  const done = await until(page, () => performance.getEntriesByName('readout-hl-warm').length > 0, 30000);
  await page.close();
  page = await open(700);
  await page.evaluate(p => { window.readout.warm(); window.readout.apply(p); }, patch([['paragraph', '<p>A document arrives.</p>']]));
  await page.waitForTimeout(15000);   // longer than the delay and the whole warm-up when not stopped
  const stopped = await page.evaluate(() => performance.getEntriesByName('readout-hl-warm').length === 0);
  check('a warmed spare page compiles the common grammars, and stops once it shows a document', done && stopped, JSON.stringify({ done, stopped }));
  await page.close();
  // Its longest slice (web_hl_warm_longest_slice_ms) counts the last one too:
  // here the last is made the longest, its one highlight held up 150 ms (the
  // tokenize limit is read only by a block's highlight, the warm-up's last step).
  page = await browser.newPage({ viewport: { width: 700, height: 800 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
    Object.defineProperty(globalThis, 'READOUT_TOKENIZE_LIMIT', { get() {
      if (!window.__held) { window.__held = true; for (const t = performance.now(); performance.now() - t < 150;); }
      return 500;
    } });
  });
  await page.goto(`${base}/reader.html`);
  await until(page, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(() => { window.readout.setAppearance({ dark: false }); window.readout.warm(); });
  await until(page, () => performance.getEntriesByName('readout-hl-warm').length > 0, 40000);
  const last = await page.evaluate(() => ({ held: !!window.__held, longest: performance.getEntriesByName('readout-hl-warm')[0].detail.longestSlice }));
  check("the warm-up's longest slice counts its last slice", last.held && last.longest >= 150, JSON.stringify(last));
  await page.close();
  // It waits for every preloaded grammar, however slow its import (SQL's
  // held back 7 s, longer than the warm-up's delay), and warms it before done.
  const openWarm = async () => {
    const pg = await browser.newPage({ viewport: { width: 700, height: 800 } });
    collectPageErrors(pg, errors);
    await pg.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
    await pg.goto(`${base}/reader.html`);
    await until(pg, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
    await pg.evaluate(() => { window.readout.setAppearance({ dark: false }); window.readout.warm(); });
    return pg;
  };
  delays.push([/\/chunks\/sql-/, 7000]);
  const t0 = Date.now();
  page = await openWarm();
  const slowDone = await until(page, () => performance.getEntriesByName('readout-hl-warm').length > 0, 40000);
  const slow = await page.evaluate(() => performance.getEntriesByName('readout-hl-warm')[0]?.detail ?? {});
  delays.length = 0;
  check('the warm-up waits for a slow grammar and warms it before it is done', slowDone && Date.now() - t0 > 7000 && (slow.grammars || []).includes('sql'), JSON.stringify({ slowDone, ms: Date.now() - t0, grammars: slow.grammars }));
  await page.close();
  // Walking a grammar for its patterns is a sliced step too: a walk held up
  // 150 ms (an inherited getter, added once the grammars are in, that the
  // walk reads on a grammar's root) shows in the longest slice.
  page = await openWarm();
  await page.waitForTimeout(3000);   // the grammars registered; the warm-up starts 5 s after
  await page.evaluate(() => {
    Object.defineProperty(Object.prototype, '__walkProbe', { enumerable: true, configurable: true, get() {
      if (!window.__walkHeld && typeof this.scopeName === 'string') { window.__walkHeld = true; for (const t = performance.now(); performance.now() - t < 150;); }
    } });
  });
  await until(page, () => performance.getEntriesByName('readout-hl-warm').length > 0, 40000);
  const walk = await page.evaluate(() => ({ held: !!window.__walkHeld, longest: performance.getEntriesByName('readout-hl-warm')[0]?.detail?.longestSlice }));
  check("walking a grammar for its patterns is counted in the warm-up's longest slice", walk.held && walk.longest >= 150, JSON.stringify(walk));
  await page.close();
  // A document arriving mid-warm-up names SQL, a grammar the spare page
  // queued late: its job moves to the front and is compiled before the
  // apply, which colours the block in its first paint; the apply (the window
  // taking the page) drops the spare jobs left.
  page = await openWarm();
  await page.waitForTimeout(5500);   // the grammars in, the idle delay over: compiling
  await page.evaluate(() => window.readout.prepare(['sql']));
  const sqlIn = await until(page, () => performance.getEntriesByName('readout-hl-prepared').length > 0, 10000);
  const mid = await page.evaluate(() => {
    const warmDone = performance.getEntriesByName('readout-hl-warm').length > 0;
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
      ops: [{ op: 'insert', slot: 1, after: 0, kind: 'code', cjk: false, html: '<div class="code-block" id="t-sql" data-lang="sql"><pre><code>SELECT 1 FROM t;</code></pre></div>' }] });
    const cb = document.getElementById('t-sql');
    return { warmDone, hl: cb.dataset.hl, colored: !!cb.querySelector('pre.shiki span[style]') };
  });
  await page.waitForTimeout(8000);
  const markedAfter = await page.evaluate(() => performance.getEntriesByName('readout-hl-warm').length > 0);
  check('a grammar the document requests mid-warm-up is compiled before its apply, which colours it', sqlIn && mid.hl === 'done' && mid.colored, JSON.stringify({ sqlIn, ...mid }));
  check('the apply drops the spare jobs left', mid.warmDone || !markedAfter, JSON.stringify({ ...mid, markedAfter }));
  await page.close();
  // A window taking the spare right after warm() (a rapid second open)
  // stops its spare-only grammars at the next step: none is fetched after
  // it, and the one in flight is not registered (its block is not coloured
  // in its apply; it loads as the block's own, as on any page not warmed).
  requests.length = 0;
  page = await browser.newPage({ viewport: { width: 700, height: 800 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await page.goto(`${base}/reader.html`);
  await until(page, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(p => new Promise(r => {
    window.readout.setAppearance({ dark: false });
    // 10 ms after the warm-up's loading starts (warm() resolves once it has).
    window.readout.warm().then(() => setTimeout(() => { window.readout.apply(p); r(); }, 10));
  }), patch([['paragraph', '<p>A window took the spare page.</p>']]));
  const spareOnly = () => requests.map(u => u.match(/\/chunks\/(javascript|python|swift|go|rust|yaml|diff|markdown|sql)-/)?.[1]).filter(Boolean);
  await page.waitForTimeout(3000);
  const later = spareOnly();
  // The chain stopped (one at a time: the last fetched was the one in
  // flight when the page was taken), and that one is not registered: its
  // block is not coloured in its apply.
  const inFlight = later[later.length - 1];
  const hl = inFlight ? await page.evaluate(lang => {
    window.readout.apply({ version: 2, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
      ops: [{ op: 'insert', slot: 1, after: 0, kind: 'code', cjk: false, html: `<div class="code-block" id="t-in" data-lang="${lang}"><pre><code>x = 1</code></pre></div>` }] });
    return document.getElementById('t-in').dataset.hl;
  }, inFlight) : null;
  check('a window taking the spare right after warm() stops its spare-only grammars', later.length < 9 && hl !== 'done', JSON.stringify({ later, inFlight, hl }));
  await page.close();
}

// 3.7 typesetting.
// T1. Short cells stay on one line only while the table fits that way: 3.6
//     kept them on one line regardless, which pushed tables of the real
//     corpus into scrolling sideways and hid columns at 640 and 900 px. Such
//     a table wraps them again and fits; one still too wide scrolls, with
//     them on one line.
{
  const corpusTables = async (name, width, which) => {
    const pg = await open(width);
    await pg.evaluate(p => window.readout.apply(p), JSON.parse(readFileSync(`test/corpus/patches/${name}.json`, 'utf8')));
    await pg.waitForTimeout(200);
    // Each on screen first: in a large document a table far down is measured
    // when it comes on screen (its block laid out by then). Scrolled to again
    // once its chunk is laid out: until then WebKit places a skipped chunk's
    // content at its top.
    const r = [];
    for (const i of which) {
      for (let k = 0; k < 2; k++) {
        await pg.evaluate(i => window.scrollBy(0, document.querySelectorAll('.table-wrap')[i].getBoundingClientRect().top - 100), i);
        await pg.waitForTimeout(300);
      }
      r.push(await pg.evaluate(i => { const t = document.querySelectorAll('.table-wrap')[i]; return { i, scrolls: t.classList.contains('scrolls'), over: t.scrollWidth - t.clientWidth }; }, i));
    }
    await pg.close();
    return r;
  };
  // (Not 17's two since 4.0: a 38-character identifier is more than the
  // 35 rem column leaves its cell, so they widen into the margin or scroll.)
  const cases = [['01-sdd-fix-loop-plan', 640, [0]], ['11-mongodb-adapter-deep-dive', 900, [0]]];
  for (const [name, width, which] of cases) {
    const r = await corpusTables(name, width, which);
    check(`corpus ${name.slice(0, 2)} at ${width} px: tables of short cells wrap them and fit instead of scrolling`, r.every(t => !t.scrolls && t.over <= 1), JSON.stringify(r));
  }
  page = await open(640);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['table', `<div class="table-wrap" id="w-fit"><table><thead><tr>${['Phase', 'Owner team', 'Status', 'Next step', 'Risk level', 'Due date', 'Reviewer'].map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody><tr>${['Phase one setup', 'platform team', 'S1 / GREEN', 'review the plan', 'medium risk', 'next sprint', 'second agent'].map(c => `<td>${c}</td>`).join('')}</tr></tbody></table></div>`],
    ['table', `<div class="table-wrap" id="w-wide"><table><thead><tr>${Array.from({ length: 12 }, (_, i) => `<th>Key ${i}</th>`).join('')}</tr></thead><tbody><tr>${Array.from({ length: 12 }, (_, i) => `<td>identifier_${i}_name</td>`).join('')}</tr></tbody></table></div>`],
  ]));
  await page.waitForTimeout(150);
  const t = await page.evaluate(() => {
    const st = id => { const w = document.getElementById(id); return { scrolls: w.classList.contains('scrolls'), over: w.scrollWidth - w.clientWidth, th: getComputedStyle(w.querySelector('th')).whiteSpace }; };
    return { fit: st('w-fit'), wide: st('w-wide') };
  });
  check('a table its short cells would push past the column wraps them and fits', !t.fit.scrolls && t.fit.over <= 1 && t.fit.th === 'normal', JSON.stringify(t.fit));
  check('a table too wide even so scrolls, its short cells on one line', t.wide.scrolls && t.wide.th === 'nowrap', JSON.stringify(t.wide));
  // In a window with room, a table widens before it wraps: short cells stay on one line.
  await page.setViewportSize({ width: 1600, height: 800 });
  await page.waitForTimeout(200);
  const roomy = await page.evaluate(() => { const w = document.getElementById('w-fit'); return { scrolls: w.classList.contains('scrolls'), over: w.scrollWidth - w.clientWidth, th: getComputedStyle(w.querySelector('th')).whiteSpace, td: getComputedStyle(w.querySelector('td')).whiteSpace }; });
  check('in a wide window such a table keeps short cells on one line (widened if needed)', roomy.over <= 1 && roomy.th === 'nowrap' && roomy.td === 'nowrap', JSON.stringify(roomy));
  await page.close();
}

// T2. A one-character emphasis-dot span at a line end keeps its dot under
//     it: an absolutely placed ::after was drawn on the next line (or lost)
//     when the span was split there. Swept across widths at which the line
//     ends right after a dotted character (CJK advances are 1 em = 16 px).
{
  page = await open(700);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p id="d-sweep">甲乙丙<em>强调文字</em>丁戊己庚<em>着重号</em>辛壬癸子丑寅卯辰巳午未申酉戌亥<em>再强调</em>一二三四五六七八九十</p>', { cjk: true }],
    ['paragraph', '<p id="d-twin">甲乙丙强调文字丁戊己庚着重号辛壬癸子丑寅卯辰巳午未申酉戌亥再强调一二三四五六七八九十</p>', { cjk: true }],
  ]));
  const sweep = await page.evaluate(() => {
    const p = document.getElementById('d-sweep'), twin = document.getElementById('d-twin'), dots = [...p.querySelectorAll('.em-dot')];
    let split = 0, atEnd = 0, pitch = 0;
    for (let k = 8; k <= 36; k++) for (const d of [0, 0.001, 0.01]) {
      p.style.width = twin.style.width = `${16 * k - d}px`;
      for (const e of dots) {
        const rs = e.getClientRects();
        if (rs.length > 1) split++;
        const r = document.createRange(); r.setStartAfter(e); r.setEnd(p, p.childNodes.length);
        const n = [...r.getClientRects()].find(x => x.width > 0);
        if (n && rs[0] && n.top > rs[0].top + 2) atEnd++;
      }
      if (Math.abs(p.getBoundingClientRect().height - twin.getBoundingClientRect().height) > 0.5) pitch++;
    }
    p.style.width = twin.style.width = '';
    return { split, atEnd, pitch };
  });
  check('an emphasis-dot span at a line end is never split onto the next line', sweep.split === 0 && sweep.atEnd > 20, JSON.stringify(sweep));
  check('emphasis dots change neither line breaks nor line pitch (as tall as the same text without them, at every width)', sweep.pitch === 0, JSON.stringify(sweep));
  // The dot is not text: find in page and copying see only the characters.
  const text = await page.evaluate(() => {
    const p = document.getElementById('d-sweep'), sel = getSelection(), r = document.createRange();
    r.selectNodeContents(p); sel.removeAllRanges(); sel.addRange(r);
    const copied = sel.toString(); sel.removeAllRanges();
    return { copied: copied.replace(/\s+$/, ''), found: window.find('强调文字', true, false, true), text: p.textContent };
  });
  check('emphasis dots stay out of copied and found text', text.copied === text.text && text.found, JSON.stringify(text));
  await page.close();
}

// T3. A terminal transcript's output is secondary grey, not link blue (the
//     colour the GitHub themes give constants); the command stays apart.
{
  page = await open(700);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['code', '<div class="code-block" id="sh-out" data-lang="console"><pre><code>$ npm test --silent\nall checks passed</code></pre></div>'],
  ]));
  await until(page, () => [...document.querySelectorAll('.code-block')].every(c => c.dataset.hl === 'done'));
  const colours = async () => page.evaluate(() => {
    // The element whose colour the text shows (a token in the block's own colours is its text alone: highlight.js).
    const span = (id, text) => { for (const l of document.querySelectorAll(`#${id} .line`)) { const w = document.createTreeWalker(l, NodeFilter.SHOW_TEXT); for (let t; (t = w.nextNode());) if (t.data.includes(text)) return t.parentElement; } return null; };
    const c = s => s && getComputedStyle(s).color;
    return { output: c(span('sh-out', 'passed')), command: c(span('sh-out', 'npm')) };
  });
  const light = await colours();
  await page.evaluate(() => window.readout.setAppearance({ dark: true }));
  const dark = await colours();
  check('console output is grey, not blue (light)', light.output === 'rgb(95, 95, 102)', JSON.stringify(light));
  check('console output is grey, not blue (dark)', dark.output === 'rgb(168, 168, 174)', JSON.stringify(dark));
  check('the command stays apart from its output', light.command && light.command !== light.output && dark.command !== dark.output, JSON.stringify({ light, dark }));
  await page.close();
}

// T7. Inline code right before full-width punctuation keeps only a sliver
//     of padding on that side (the punctuation brings its own space).
{
  page = await open(700);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p>结果写入 <code id="p-a">results/2026-10/</code>。另见 <a href="#x"><code id="p-b">docs/</code></a>，以及 <code id="p-c">npm test</code> 和 <code id="p-d">make</code>.</p>', { cjk: true }],
    ['paragraph', '<p>路径 <code class="path-link" id="p-e" data-path="a.md">a.md</code>。</p>', { cjk: true }],
  ]));
  const pad = await page.evaluate(() => Object.fromEntries(['p-a', 'p-b', 'p-c', 'p-d', 'p-e'].map(id => { const e = document.getElementById(id), cs = getComputedStyle(e); return [id, Math.round(parseFloat(cs.paddingRight) / parseFloat(cs.fontSize) * 100) / 100]; })));
  // 4.0 P4.2: the padding is 0.24em, a third of it before such punctuation.
  check('code before full-width punctuation trims its right padding to 0.08em; elsewhere 0.24em; a path link keeps its outline even', pad['p-a'] === 0.08 && pad['p-b'] === 0.08 && pad['p-c'] === 0.24 && pad['p-d'] === 0.24 && pad['p-e'] === 0.24, JSON.stringify(pad));
  await page.close();
}

// T12. Bulleted and numbered items start their text at the same place, so
//      a list next to one of the other kind lines up.
{
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p id="l-p">Text.</p>'],
    ['listItem', '<ul class="li-block li-first li-last"><li id="l-ul">Bullet</li></ul>'],
    ['listItem', '<ol class="li-block li-first li-last" start="9"><li id="l-ol">Nine</li><li id="l-ol10">Ten</li></ol>'],
  ]));
  const x = await page.evaluate(() => Object.fromEntries(['l-p', 'l-ul', 'l-ol', 'l-ol10'].map(id => { const r = document.createRange(); r.selectNodeContents(document.getElementById(id)); return [id, r.getClientRects()[0].left]; })));
  check('bulleted and numbered item text starts at the same x', Math.abs(x['l-ul'] - x['l-ol']) < 0.5 && Math.abs(x['l-ol'] - x['l-ol10']) < 0.5 && x['l-ul'] > x['l-p'], JSON.stringify(x));
  await page.close();
}

// 3.8 T1. Emphasis dots are whole dots on every character: a dot laid on the
//      fractional bottom edge of its padding was cut to a 1 px dash on some
//      characters and not others (3.7), depending on where each one fell.
//      Ink per dot, with the glyphs hidden, at 1x and 2x and 13 to 22 px.
{
  const dotDoc = patch([
    ['paragraph', '<p id="dz">复查时请<em>逐项核对</em>每家实现的差异，并<em>保存原始响应头</em>以便<em>复查</em>；<em>所有实现</em>都必须在<em>同一个版本</em>下<em>重新跑完</em>。</p>', { cjk: true }],
    ['paragraph', '<p id="dj">日本語の確認：<em>条件付き書き込み</em>は「<em>すべての実装</em>」で<em>同じ結果</em>になるはずです。</p>', { cjk: true }],
  ]);
  const spread = [];
  for (const dsf of [1, 2]) {
    const pg = await browser.newPage({ viewport: { width: 900, height: 900 }, deviceScaleFactor: dsf });
    collectPageErrors(pg, errors);
    await pg.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
    await pg.goto(`${base}/reader.html`);
    await pg.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
    await pg.addStyleTag({ content: '#ro-doc { -webkit-text-fill-color: transparent } .em-dot { color: #000 !important }' });
    for (let fs = 13; fs <= 22; fs++) {
      await pg.evaluate(f => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: f, topInset: 0 }), fs);
      if (fs === 13) await pg.evaluate(p => window.readout.apply(p), dotDoc);
      await pg.waitForTimeout(80);
      const info = await pg.evaluate(() => {
        const box = document.getElementById('dz').getBoundingClientRect(), end = document.getElementById('dj').getBoundingClientRect();
        const y = Math.max(0, Math.floor(box.top - 20)), clip = { x: 0, y, width: innerWidth, height: Math.ceil(end.bottom + 20 - y) };
        return { clip, dots: [...document.querySelectorAll('.em-dot')].map(e => { const r = e.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, ja: !!e.closest(':lang(ja)') }; }) };
      });
      const png = PNG.sync.read(await pg.screenshot({ clip: info.clip }));
      for (const ja of [false, true]) {
        const inks = info.dots.filter(d => d.ja === ja).map(d => {
          const x0 = Math.floor(d.x * dsf), x1 = Math.ceil((d.x + d.w) * dsf), top = (d.y - info.clip.y) * dsf;
          const band = ja ? [top - 1, top + 0.3 * fs * dsf] : [top + d.h * dsf - 0.3 * fs * dsf, top + d.h * dsf + 1];
          let ink = 0;
          for (let y = Math.max(0, Math.floor(band[0])); y < Math.min(png.height, Math.ceil(band[1])); y++) for (let x = x0; x < x1; x++) {
            const i = (y * png.width + x) * 4;
            ink += (255 - (0.2126 * png.data[i] + 0.7152 * png.data[i + 1] + 0.0722 * png.data[i + 2])) / 255;
          }
          return ink / dsf / dsf;
        });
        const mean = inks.reduce((a, b) => a + b, 0) / inks.length;
        const cv = Math.sqrt(inks.reduce((a, b) => a + (b - mean) ** 2, 0) / inks.length) / mean;
        spread.push({ lang: ja ? 'ja' : 'zh', dsf, fs, n: inks.length, mean: +mean.toFixed(2), cv: +cv.toFixed(3) });
      }
    }
    await pg.close();
  }
  const bad = spread.filter(s => !(s.n >= 8 && s.mean > 0.5 && s.cv < 0.1));
  check('emphasis dots carry the same ink on every character (spread under 0.1, zh and ja, 1x and 2x, 13-22 px)', bad.length === 0 && spread.length === 40, JSON.stringify(bad.length ? bad : spread.slice(0, 4)));
}

// 3.8 T2. Prose in a fence (no language, text, markdown, prompt...) wraps at
//      the column, never widens into the margins and has no Wrap button; code,
//      a box-drawing tree and an aligned listing keep scrolling.
{
  const prose = 'This is a prompt written as one long line of prose, the way agents embed instructions and SKILL.md text in a fence, and it goes on well past the column.';
  const aligned = Array.from({ length: 3 }, (_, i) => `row-${i}-name-that-is-long      value-${i}-also-quite-long-here      note ${i} with more words`).join('\n');
  const fences = [['f-none', ''], ['f-text', 'text'], ['f-txt', 'txt'], ['f-plain', 'plain'], ['f-plaintext', 'plaintext'], ['f-md', 'md'], ['f-markdown', 'markdown'], ['f-prompt', 'prompt']];
  const fp = patch([
    ['paragraph', '<p id="f-p">The text column.</p>'],
    ...fences.map(([id, lang]) => ['code', `<div class="code-block" id="${id}"${lang ? ` data-lang="${lang}"` : ''}><pre><code>${prose} ${prose}</code></pre></div>`]),
    ['code', `<div class="code-block" id="f-js" data-lang="js"><pre><code>${longLine} ${longLine}</code></pre></div>`],
    ['code', `<div class="code-block" id="f-tree"><pre><code>web/\n├── src/  ${prose}\n│   └── reader.css\n└── test/</code></pre></div>`],
    ['code', `<div class="code-block" id="f-aligned" data-lang="text"><pre><code>${aligned}</code></pre></div>`],
    ['code', '<div class="code-block" id="f-short-aligned"><pre><code>name   type   default\nid     int    0\nlabel  text   none</code></pre></div>'],
    ['code', `<div class="code-block" id="f-stack"><pre><code>error Error: Cannot find module 'readout-core' from the reader bundle while the reader was loading the document view\n    at Function.Module._resolveFilename (node:internal/modules/cjs/loader:1145:15)\n    at Object.&lt;anonymous&gt; (/work/web/build.mjs:12:3)</code></pre></div>`],
    ['code', `<div class="code-block" id="f-shell" data-lang="text"><pre><code>$ npm test\n${prose}</code></pre></div>`],
    ['code', `<div class="code-block" id="f-tabs" data-lang="text"><pre><code>path\tsize\tnote\nsrc/reader.css\t22 KB\t${prose}\nsrc/reader/enhance.js\t31 KB\tshort</code></pre></div>`],
  ]);
  for (const width of [860, 1600]) {
    page = await open(width);
    await page.evaluate(p => window.readout.apply(p), fp);
    await until(page, () => [...document.querySelectorAll('.code-block[data-lang]')].every(c => c.dataset.hl === 'done'));
    await page.waitForTimeout(100);
    const r = await page.evaluate(ids => {
      const col = document.getElementById('f-p').getBoundingClientRect();
      const one = id => { const c = document.getElementById(id), pre = c.querySelector('pre'), b = c.getBoundingClientRect();
        return { id, prose: c.classList.contains('cb-prose'), ws: getComputedStyle(pre).whiteSpace, scrolls: pre.scrollWidth > pre.clientWidth + 1, left: b.left - col.left, width: b.width - col.width, wrapBtn: getComputedStyle(c.querySelector('.cb-wrap')).display }; };
      return { prose: ids.map(one), js: one('f-js'), tree: one('f-tree'), aligned: one('f-aligned'), short: one('f-short-aligned'), tabs: one('f-tabs'), stack: one('f-stack'), shell: one('f-shell'), sideways: document.scrollingElement.scrollWidth - innerWidth };
    }, fences.map(f => f[0]));
    check(`prose fences (none, text, txt, plain, plaintext, md, markdown, prompt) wrap in the column, without a Wrap button (${width})`,
      r.prose.every(f => f.prose && f.ws === 'pre-wrap' && !f.scrolls && Math.abs(f.left) < 0.5 && Math.abs(f.width) < 0.5 && f.wrapBtn === 'none') && r.sideways <= 0, JSON.stringify(r.prose.filter(f => !(f.prose && !f.scrolls && Math.abs(f.left) < 0.5 && Math.abs(f.width) < 0.5 && f.wrapBtn === 'none'))));
    // At 1600 px they widen into the margins, where the aligned listing fits.
    check(`code, a tree and an aligned listing do not wrap and keep their Wrap button${width === 860 ? ', and scroll' : ''} (${width})`,
      [r.js, r.tree, r.aligned].every(f => !f.prose && f.ws === 'pre' && (width > 860 || f.scrolls) && f.wrapBtn !== 'none'), JSON.stringify([r.js, r.tree, r.aligned]));
    check(`a short aligned table and a tab-separated listing are not prose: unwrapped, with their Wrap button${width === 860 ? ', the long one scrolling' : ''} (${width})`,
      [r.short, r.tabs].every(f => !f.prose && f.ws === 'pre' && f.wrapBtn !== 'none') && (width > 860 || r.tabs.scrolls), JSON.stringify([r.short, r.tabs]));
    // Prose only on a positive signal: a stack trace (indented frames) and a
    // shell transcript are not prose, long sentences in them notwithstanding.
    check(`a stack trace and a shell transcript in an unlabelled or text fence are not prose (${width})`,
      [r.stack, r.shell].every(f => !f.prose && f.ws === 'pre' && f.wrapBtn !== 'none') && (width > 900 || r.stack.scrolls), JSON.stringify([r.stack, r.shell]));
    if (width === 1600) check('at 1600 px code still widens into the margins, prose does not', r.js.width > 10 && r.prose.every(f => Math.abs(f.width) < 0.5), JSON.stringify([r.js, r.prose[0]]));
    await page.close();
  }
}

// 3.8 T3. Chinese blocks take “ ” ‘ ’ — … from the Chinese font (its
//      full-width forms, clreq), Japanese and Latin blocks and code do not.
{
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p id="q-zh">复查每家实现的“条件写入”与‘最终一致’——见……</p>', { cjk: true }],
    ['paragraph', '<p id="q-ja">日本語の“引用”です。</p>', { cjk: true }],
    ['paragraph', '<p id="q-en">The “quoted” word — and so on…</p>'],
    ['code', '<div class="code-block" id="q-code" data-lang="text"><pre><code>中文的“引号”在代码里</code></pre></div>'],
  ]));
  const fam = await page.evaluate(() => {
    const f = id => getComputedStyle(document.getElementById(id)).fontFamily;
    const faces = [...document.fonts].filter(x => x.family.replace(/["']/g, '') === 'ro-zh-punct').map(x => ({ range: x.unicodeRange, weight: x.weight }));
    return { zh: f('q-zh'), ja: f('q-ja'), en: f('q-en'), code: getComputedStyle(document.querySelector('#q-code pre')).fontFamily, codeBlk: getComputedStyle(document.getElementById('q-code').closest('.blk')).fontFamily, faces };
  });
  check('a Chinese block puts the Chinese punctuation face first; Japanese, Latin and code do not',
    /^"?ro-zh-punct"?,/.test(fam.zh) && ![fam.ja, fam.en, fam.code, fam.codeBlk].some(v => /ro-zh-punct/.test(v)), JSON.stringify(fam));
  check('the punctuation face covers only “ ” ‘ ’ — …, regular and bold',
    fam.faces.length === 2 && fam.faces.every(x => /U\+2018-2019/i.test(x.range) && /U\+201C-201D/i.test(x.range) && /U\+2014/i.test(x.range) && /U\+2026/i.test(x.range) && !/U\+3/i.test(x.range)), JSON.stringify(fam.faces));
  await page.close();
}

// 3.8 T4. Front matter is a key/value grid: each key on a row of its own, the
//      keys in one column, the values in the next, a long value wrapping
//      beside its key, not under it.
{
  page = await open(700);
  await page.evaluate(p => window.readout.apply(p), patch([
    // As ReadoutCore writes it; the last value is a literal block (`notes: |`) with a blank line.
    ['frontMatter', '<div class="front-matter" id="fm"><span class="fm-item"><span class="fm-key">title</span> <span class="fm-val">Plan</span></span><span class="fm-item"><span class="fm-key">status</span> <span class="fm-val">draft</span></span><span class="fm-item"><span class="fm-key">description</span> <span class="fm-val">A long description that runs on well past the end of a single line in the column, so it has to wrap onto a second one at least.</span></span><span class="fm-item"><span class="fm-key">notes</span> <span class="fm-val">line one<br>line two<br><br>after a blank line</span></span></div>'],
    ['heading', '<h1 id="fm-h">Title</h1>', { anchor: 'fm-h' }],
  ]));
  const fm = await page.evaluate(() => {
    const keys = [...document.querySelectorAll('#fm .fm-key')].map(k => k.getBoundingClientRect());
    const vals = [...document.querySelectorAll('#fm .fm-val')].map(v => { const r = document.createRange(); r.selectNodeContents(v); return [...r.getClientRects()].filter(x => x.width > 0).map(x => ({ left: x.left, top: x.top })); });
    return { keys: keys.map(k => ({ left: k.left, right: k.right, top: k.top })), vals };
  });
  const k = fm.keys, v = fm.vals;
  check('front matter: keys line up in one column, each on its own row',
    k.length === 4 && k.every(x => Math.abs(x.left - k[0].left) < 0.5) && k[0].top < k[1].top && k[1].top < k[2].top, JSON.stringify(k));
  check('front matter: values line up beside the keys, a long one and one with blank lines staying in their own column',
    v.every(lines => lines.length && Math.abs(lines[0].left - v[0][0].left) < 0.5 && lines[0].left > Math.max(...k.map(x => x.right))) && v[2].length >= 2 && v[2].every(l => Math.abs(l.left - v[0][0].left) < 0.5)
      && v[3].length === 3 && v[3].every(l => Math.abs(l.left - v[0][0].left) < 0.5) && v[3][2].top - v[3][1].top > 1.5 * (v[3][1].top - v[3][0].top),
    JSON.stringify(v));
  await page.close();
}

// Code highlighted in one theme and shown after a switch to the other looks,
// character by character, as code highlighted in that theme from the start
// with every token in its span (READOUT_TOKEN_SPANS): a token left as bare
// text (in the block's own colours, highlight.js) keeps every colour and
// style it has in either theme (weight, italics, underline: Markdown
// headings and emphasis, diff lines, comments).
{
  const sample = [
    ['code', '<div class="code-block" data-lang="ts"><pre><code>// a comment\nexport async function f(a: number): Promise&lt;void&gt; { return g(a + 1, "s", /x+/g); }</code></pre></div>'],
    ['code', '<div class="code-block" data-lang="markdown"><pre><code># Heading\nSome *emphasis*, **strong**, `code` and [a link](https://example.com).\n&gt; quoted</code></pre></div>'],
    ['code', '<div class="code-block" data-lang="diff"><pre><code>--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old line\n+new line</code></pre></div>'],
    ['code', '<div class="code-block" data-lang="python"><pre><code>@decorator\ndef f(x: int) -&gt; str:\n    "doc"\n    return f"{x!r}"  # note</code></pre></div>'],
  ];
  const styled = async (startDark, showDark, spans = false) => {
    const p = await browser.newPage({ viewport: { width: 900, height: 800 } });
    collectPageErrors(p, errors);
    await p.addInitScript(s => { window.READOUT_TOKEN_SPANS = s; window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; }, spans);
    await p.goto(`${base}/reader.html`);
    await p.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
    await p.evaluate(d => window.readout.setAppearance({ dark: d, accent: '#0a84ff', fontSize: 16 }), startDark);
    await p.evaluate(x => window.readout.apply(x), patch(sample));
    await until(p, () => [...document.querySelectorAll('.code-block')].every(c => c.dataset.hl === 'done'));
    if (showDark !== startDark) await p.evaluate(d => window.readout.setAppearance({ dark: d }), showDark);
    const runs = await p.evaluate(() => [...document.querySelectorAll('.code-block pre')].map(pre => {
      const out = [], w = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
      for (let t; (t = w.nextNode());) {
        const cs = getComputedStyle(t.parentElement);
        for (const ch of t.data) out.push([ch, cs.color, cs.fontWeight, cs.fontStyle, cs.textDecorationLine].join('|'));
      }
      return out;
    }));
    await p.close();
    return runs;
  };
  const diffs = [];
  let chars = 0;
  for (const dark of [true, false]) {
    const fresh = await styled(dark, dark, true), switched = await styled(!dark, dark);
    chars += fresh.flat().length;
    fresh.forEach((block, b) => block.forEach((c, i) => { if (c !== switched[b][i] && diffs.length < 5) diffs.push({ dark, block: b, fresh: c, switched: switched[b][i] }); }));
    if (fresh.flat().length !== switched.flat().length) diffs.push({ dark, length: [fresh.flat().length, switched.flat().length] });
  }
  check('code highlighted in one theme shows, after a switch, every character as code highlighted in the other with all its spans', chars > 300 && diffs.length === 0, JSON.stringify({ chars, diffs }));
}

// 4.0 P4: readability of agent Markdown.

// P4.1 A long path or identifier breaks after a separator, never inside a
//      part and never leaving a scrap: ReadoutCore's <wbr>, and span.nb or
//      code.nb where WebKit would break after a - or ? of its own
//      (Readability40Tests). The phase-0 report's paragraph and more, as
//      ReadoutCore renders them, at every column from 244 to 844 px: in a
//      code span and in the bare path, every line break but one at a space
//      comes right after a separator, with 5 characters or more of the token
//      after it. The same paragraph as 3.9 rendered it broke inside a part,
//      or left a scrap ("1.md").
{
  const withBreaks = '<p>This is Phase 0 work item 7 (<code>docs/<wbr>superpowers/<wbr>plans/<wbr><span class="nb">2026-08-08-</span><wbr>stresseur-<wbr><span class="nb">phase0-1.md</span></code>\n§4.1.7): measure what one load worker (one CLI process, one <code>load run</code>) can actually\ngenerate, using the real <code>loadrun</code> engine (<code>apps/<wbr>cli/<wbr>internal/<wbr>loadrun</code>), not a\nreimplementation of its scheduling. See <code>org.<wbr>springframework.boot.<wbr>autoconfigure</code>, <code>std::<wbr>collections::<wbr>HashMap</code>, <code class="nb">glyphicon-X</code>, <code>release-<wbr><span class="nb">2026-08-08-</span><wbr>v1.25.10-<wbr>final</code>, <code><span class="nb">--dangerously-</span><wbr>skip-<wbr>permissions</code> and docs/<wbr>superpowers/<wbr>specs/<wbr>phase0-bench-report.md here.</p>';
  const without = withBreaks.replace(/<wbr>|<span class="nb">|<\/span>| class="nb"/g, '');
  // Each code span's (and the bare path's) text, and the places its lines break.
  const breaksOf = (pg, html) => pg.evaluate(h => {
    const host = document.getElementById('t-brk');
    host.innerHTML = h;
    const p = host.firstElementChild;
    const bare = [...p.childNodes].find(n => n.nodeType === 3 && n.data.includes(' and docs/'));
    const spans = [...p.querySelectorAll('code')];
    if (bare) {
      // The path alone, in a span of its own: from "docs/" to " here.".
      const last = [...p.childNodes].find(n => n.nodeType === 3 && n.data.includes(' here.'));
      const r = document.createRange(); r.setStart(bare, bare.data.indexOf('docs/')); r.setEnd(last, last.data.indexOf(' here.'));
      const s = document.createElement('span'); r.surroundContents(s); spans.push(s);
    }
    return spans.map(el => {
      let text = '', prevTop = null;
      const breaks = [];
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let t; (t = w.nextNode());) for (let i = 0; i < t.data.length; i++) {
        const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + 1);
        const box = [...r.getClientRects()].find(b => b.width > 0);
        if (box && !/\s/.test(t.data[i])) {
          const top = Math.round(box.top);
          if (prevTop !== null && Math.abs(top - prevTop) > 4) breaks.push(text.length);
          prevTop = top;
        }
        text += t.data[i];
      }
      return { text, breaks };
    });
  }, html);
  const SEP = /[\/\\._\-:#?&=]/;
  // A break at a space is a word break; any other must follow a separator, with 5 or more of its token after it.
  const wrong = ({ text, breaks }) => breaks.filter(i => !/\s/.test(text[i - 1]) && !/\s/.test(text[i]) &&
    (!SEP.test(text[i - 1]) || (text.slice(i).match(/^\S*/)[0].replace(/[)\],.;]+$/, '').length < 5))).map(i => `${text.slice(0, i)}|${text.slice(i)}`);
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([['paragraph', '<div id="t-brk"></div>']]));
  const found = { withBreaks: [], without: [] };
  let broken = 0;
  for (let w = 300; w <= 900; w += 10) {
    await page.setViewportSize({ width: w, height: 800 });
    for (const [k, html] of [['withBreaks', withBreaks], ['without', without]]) {
      for (const span of await breaksOf(page, html)) {
        if (k === 'withBreaks' && span.breaks.length) broken++;
        for (const x of wrong(span)) if (found[k].length < 6) found[k].push({ w, at: x });
      }
    }
  }
  check('P4.1 long paths and identifiers break only after a separator and leave no scrap, at every column from 244 to 844 px', broken > 40 && found.withBreaks.length === 0, JSON.stringify({ broken, wrong: found.withBreaks }));
  check('P4.1 as 3.9 rendered them (no break opportunities), they broke inside a part or left a scrap', found.without.length > 0, JSON.stringify(found.without));
  await page.close();
}

// P4.2 Inline code is lighter and sits in the sentence: its x-height 0.9 of
//      the text's (font-size-adjust, whatever the monospace font), a fill a
//      step fainter than 3.9's (#f5f5f7 light, #2a2a2c dark) that still shows
//      on the page and in an alert, and padding that leaves the line height
//      as it is, in Latin and Chinese text.
for (const dark of [false, true]) {
  page = await open(900, dark);
  const filler = 'An agent wrote this sentence with enough words to fill a line or two of the column';
  const zh = '在现有全局提示词存储的基础上，增加项目级别的提示词存储功能，实现团队共享和项目特定的提示词管理';
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', `<p id="c-plain">${filler}, ${filler}, ${filler}.</p>`],
    ['paragraph', `<p id="c-code">${filler.replace('agent', 'agent <code id="c-1">src/app.ts</code>').replace('words', '<code>words</code>')}, ${filler.replace('column', '<code>column</code>')}, ${filler.replace('sentence', '<code>sentence</code>')}.</p>`],
    ['paragraph', `<p id="z-plain">${zh}，${zh}。</p>`, { cjk: true }],
    ['paragraph', `<p id="z-code">${zh.replace('提示词存储', '<code id="z-1">~/.codemoss/prompt.json</code>')}，${zh.replace('团队共享', '<code>team</code>')}。</p>`, { cjk: true }],
    ['alert', '<div class="alert alert-note"><p class="alert-title">Note</p><p>In an alert: <code id="c-alert">make test</code></p></div>'],
  ]));
  const r = await page.evaluate(() => {
    const ex = el => { const s = document.createElement('span'); s.style.cssText = 'display:inline-block;width:0;height:1ex;vertical-align:baseline'; el.appendChild(s); const h = s.getBoundingClientRect().height; s.remove(); return h; };
    // "rgb(r, g, b)", "rgba(r, g, b, a)" or "color(srgb r g b / a)" (0-1), as 0-255 and alpha.
    const rgb = c => { const n = (c.match(/[\d.]+/g) || []).map(Number); return c.startsWith('color(') ? [n[0] * 255, n[1] * 255, n[2] * 255, n[3] ?? 1] : n; };
    const over = (fg, bg) => { const [r, g, b, a = 1] = rgb(fg); const [R, G, B] = rgb(bg); return [r * a + R * (1 - a), g * a + G * (1 - a), b * a + B * (1 - a)]; };
    const lum = ([r, g, b]) => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
    const page = getComputedStyle(document.documentElement).backgroundColor;
    const code = document.getElementById('c-1'), cs = getComputedStyle(code);
    const fill = over(cs.backgroundColor, page);
    const alert = document.querySelector('.alert'), alertFill = getComputedStyle(alert).backgroundColor;
    const inAlert = over(getComputedStyle(document.getElementById('c-alert')).backgroundColor, alertFill);
    const h = id => document.getElementById(id).getBoundingClientRect().height;
    // Lines: the tops of the paragraph's own text (not its code), 4 px apart or more.
    const lines = id => { const tops = []; for (const t of document.getElementById(id).childNodes) if (t.nodeType === 3) for (let i = 0; i < t.data.length; i++) { if (/\s/.test(t.data[i])) continue; const rg = document.createRange(); rg.setStart(t, i); rg.setEnd(t, i + 1); const b = rg.getClientRects()[0]; if (b && !tops.some(x => Math.abs(x - b.top) < 4)) tops.push(b.top); } return tops.length; };
    return {
      adjust: cs.fontSizeAdjust, size: parseFloat(cs.fontSize) / parseFloat(getComputedStyle(code.parentElement).fontSize),
      xLatin: ex(code) / ex(code.parentElement), xZh: ex(document.getElementById('z-1')) / ex(document.getElementById('z-1').parentElement),
      fill: contrast(fill, rgb(page)), fillInAlert: contrast(inAlert, rgb(alertFill)),
      padTop: parseFloat(cs.paddingTop) / parseFloat(cs.fontSize), padX: parseFloat(cs.paddingLeft) / parseFloat(cs.fontSize),
      latin: { plain: h('c-plain') / lines('c-plain'), code: h('c-code') / lines('c-code'), n: [lines('c-plain'), lines('c-code')] },
      zh: { plain: h('z-plain') / lines('z-plain'), code: h('z-code') / lines('z-code'), n: [lines('z-plain'), lines('z-code')] },
    };
  });
  const theme = dark ? 'dark' : 'light';
  // 3.9: #f5f5f7 on #fff is 1.09:1, #2a2a2c on #1e1e1f 1.16:1.
  const before = dark ? 1.16 : 1.09;
  check(`P4.2 inline code's x-height is 0.85-0.95 of the text's, in Latin and Chinese lines (${theme})`, /ex-height 0\.53|^0\.53$/.test(r.adjust) && r.xLatin > 0.85 && r.xLatin < 0.95 && r.xZh > 0.85 && r.xZh < 0.95, JSON.stringify(r));
  check(`P4.2 inline code's fill is fainter than 3.9's and still shows, on the page and in an alert (${theme})`, r.fill > 1.04 && r.fill < before - 0.02 && r.fillInAlert > 1.04, JSON.stringify(r));
  check(`P4.2 inline code's padding leaves the line height as it is (${theme})`, r.padTop <= 0.1 && r.padX <= 0.25 && Math.abs(r.latin.plain - r.latin.code) < 0.5 && Math.abs(r.zh.plain - r.zh.code) < 0.5 && r.latin.n[1] > 1 && r.zh.n[1] > 1, JSON.stringify(r));
  await page.close();
}

// P4.3 A paragraph ending with a colon (p.lead, ReadoutCore) and the list
//      right under it read as one unit: a gap under half a paragraph's,
//      wider than between two items; its change bar ends with it. A
//      paragraph that is no lead-in, or a lead-in before something else,
//      keeps the paragraph gap. Chinese and English, top level and in a quote.
{
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p>采用抽象基类模式，提取公共逻辑，通过继承实现全局和项目两种管理器。</p>', { cjk: true }],
    ['paragraph', '<p class="lead" id="l-zh"><strong>优势</strong>：</p>', { cjk: true }],
    ['listItem', '<ul class="li-block li-first"><li id="l-zh-1">代码复用高，消除重复</li></ul>', { cjk: true }],
    ['listItem', '<ul class="li-block li-last"><li id="l-zh-2">职责清晰，易于维护</li></ul>', { cjk: true }],
    ['paragraph', '<p class="lead" id="l-en">The plan has three steps:</p>'],
    ['listItem', '<ol class="li-block li-first"><li id="l-en-1">Write the failing test.</li></ol>'],
    ['listItem', '<ol class="li-block li-last"><li>Make it pass.</li></ol>'],
    ['paragraph', '<p id="n-en">A paragraph that is no lead-in.</p>'],
    ['listItem', '<ul class="li-block li-first li-last"><li id="n-en-1">An item after it.</li></ul>'],
    ['paragraph', '<p class="lead" id="l-code">Run:</p>'],
    ['code', '<div class="code-block" id="l-code-1"><pre><code>make test</code></pre></div>'],
    ['quote', '<blockquote><p class="lead" id="l-q">Options:</p><ul><li id="l-q-1">one</li><li>two</li></ul></blockquote>'],
  ]));
  const g = await page.evaluate(() => {
    const box = id => document.getElementById(id).getBoundingClientRect();
    const gap = (a, b) => Math.round((box(b).top - box(a).bottom) * 10) / 10;
    const blk = id => document.getElementById(id).closest('.blk');
    const bar = id => { const b = blk(id), r = b.getBoundingClientRect(); return r.bottom - parseFloat(getComputedStyle(b, '::before').bottom); };
    return { zh: gap('l-zh', 'l-zh-1'), zhItems: gap('l-zh-1', 'l-zh-2'), en: gap('l-en', 'l-en-1'), none: gap('n-en', 'n-en-1'), code: gap('l-code', 'l-code-1'), quote: gap('l-q', 'l-q-1'),
      barZh: Math.round(bar('l-zh') - box('l-zh').bottom), listTop: Math.round(box('l-zh-1').top - box('l-zh').bottom) };
  });
  check('P4.3 a lead-in and its list are one unit: under half a paragraph gap, more than between items (Chinese, English, in a quote)',
    g.zh < g.none * 0.45 && g.en < g.none * 0.45 && g.quote < g.none * 0.45 && g.zh > g.zhItems + 2 && g.en > 2 && g.quote > 2, JSON.stringify(g));
  check('P4.3 a paragraph that is no lead-in, or a lead-in before code, keeps the paragraph gap', g.none >= 16 && g.code >= 16, JSON.stringify(g));
  check('P4.3 a lead-in\'s change bar ends with its text, not in the list', g.barZh <= g.listTop, JSON.stringify(g));
  await page.close();
}

// P4.4 The column sizes itself (no setting): 35 rem at most, so ⌘+ and ⌘−
//      keep the characters per line (about 60-80 of Latin text, 35-45 of
//      Chinese); in a narrower window, the window less its gutters. An old
//      caller's width: "wide" changes nothing.
{
  const latin = 'Agents write long plans and reports, and the reader keeps them readable: a line of text that the eye can follow back to its start without losing its place, in a window of any size and at any text size the reader chooses. '.repeat(3);
  const han = '在现有全局提示词存储的基础上，增加项目级别的提示词存储功能。项目提示词存储在项目根目录的文件中，实现团队共享和项目特定的提示词管理，并保持阅读的节奏。'.repeat(3);
  const perLine = (pg, id) => pg.evaluate(id => {
    const el = document.getElementById(id), lines = new Map();
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let t; (t = w.nextNode());) for (let i = 0; i < t.data.length; i++) {
      const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + 1);
      const b = r.getClientRects()[0]; if (!b) continue;
      const k = Math.round(b.top / 4); lines.set(k, (lines.get(k) || 0) + 1);
    }
    const n = [...lines.values()]; n.pop();   // the last line is short
    return n.reduce((a, b) => a + b, 0) / n.length;
  }, id);
  page = await open(1600);
  await page.evaluate(p => window.readout.apply(p), patch([['paragraph', `<p id="m-latin">${latin}</p>`], ['paragraph', `<p id="m-han">${han}</p>`, { cjk: true }]]));
  const m = [];
  for (const fs of [13, 16, 20, 24]) {
    await page.evaluate(fs => window.readout.setAppearance({ fontSize: fs }), fs);
    m.push({ fs, col: await page.evaluate(() => document.getElementById('m-latin').getBoundingClientRect().width), latin: await perLine(page, 'm-latin'), han: await perLine(page, 'm-han') });
  }
  check('P4.4 in a wide window the column is 35 em at 13/16/20/24 px (560 px at 16)', m.every(x => Math.abs(x.col / x.fs - 35) < 0.05) && Math.abs(m[1].col - 560) < 0.5, JSON.stringify(m));
  check('P4.4 a line holds 60-80 Latin characters and 35-45 Chinese ones, at every text size', m.every(x => x.latin >= 60 && x.latin <= 80 && x.han >= 35 && x.han <= 45), JSON.stringify(m));
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 16 }));
  const sizes = [];
  for (const vw of [1600, 1000, 760, 640, 480, 360]) {
    await page.setViewportSize({ width: vw, height: 800 });
    sizes.push({ vw, col: await page.evaluate(() => document.getElementById('m-latin').getBoundingClientRect().width), sideways: await page.evaluate(() => document.scrollingElement.scrollWidth - innerWidth) });
  }
  const want = vw => Math.min(560, vw - 2 * 28);
  check('P4.4 in a narrower window the column is the window less its gutters', sizes.every(s => Math.abs(s.col - want(s.vw)) < 0.6 && s.sideways <= 0), JSON.stringify(sizes));
  await page.setViewportSize({ width: 1600, height: 800 });
  const old = await page.evaluate(() => { window.readout.setAppearance({ width: 'wide' }); return { col: document.getElementById('m-latin').getBoundingClientRect().width, attr: document.documentElement.hasAttribute('data-width') }; });
  check('P4.4 there is no width setting: width "wide" changes nothing', Math.abs(old.col - 560) < 0.5 && !old.attr, JSON.stringify(old));
  await page.close();
}


// P4.5 A part kept on one line (span.nb, code.nb) still breaks when it is
//      wider than the whole line: a narrow pane at the largest text size
//      (24 px), in an item two levels deep, never runs past the column.
{
  page = await open(360);
  await page.evaluate(() => window.readout.setAppearance({ fontSize: 24 }));
  const longs = ['<code><span class="nb">2026-10-28T12:34:56.123456789Z</span></code>', '<code class="nb">glyphicon-arrow-left</code>',
    '<code>docs/<wbr>superpowers/<wbr>plans/<wbr><span class="nb">2026-08-08-</span><wbr>stresseur-<wbr><span class="nb">phase0-1.md</span></code>'];
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', `<p id="o-p">Logged at ${longs.join(', ')} and so on.</p>`],
    ['listItem', `<ul class="li-block li-first li-last"><li>Outer<ul><li id="o-li">Inner: ${longs.join(' ')}</li></ul></li></ul>`],
  ]));
  await page.waitForTimeout(200);
  const o = await page.evaluate(() => {
    const col = document.getElementById('o-p').getBoundingClientRect();
    const codes = [...document.querySelectorAll('#o-p code, #o-li code')].map(c => { const rs = [...c.getClientRects()]; return { text: c.textContent.slice(0, 16), right: Math.max(...rs.map(r => r.right)), lines: rs.length }; });
    return { col: [col.left, col.right], sideways: document.scrollingElement.scrollWidth - innerWidth, past: codes.filter(c => c.right > col.right + 0.5), codes };
  });
  check('P4.5 at 24 px in a 360 px window, kept parts and long paths never run past the column, in text or a nested item', o.sideways <= 0 && o.past.length === 0, JSON.stringify(o));
  await page.close();
  // Kept as a unit (an inline-block), a code span's fill and its line are as tall as any code's.
  page = await open(900);
  await page.evaluate(p => window.readout.apply(p), patch([
    ['paragraph', '<p id="k-a">Plain text, no code.</p>'], ['paragraph', '<p id="k-b">With <code id="k-c1">plain</code> code.</p>'],
    ['paragraph', '<p id="k-c">With <code class="nb" id="k-c2">glyphicon-X</code> code.</p>'], ['paragraph', '<p id="k-d">With <code id="k-c3">x<span class="nb">2026-08-08-</span>y</code> code.</p>'],
    ['heading', '<h2 id="k-h1">Task 1: plain</h2>'], ['heading', '<h2 id="k-h2">Task 1: <code class="nb">wiki-init</code></h2>'],
  ]));
  const k = await page.evaluate(() => Object.fromEntries(['k-a', 'k-b', 'k-c', 'k-d', 'k-c1', 'k-c2', 'k-c3', 'k-h1', 'k-h2'].map(id => [id, Math.round(document.getElementById(id).getBoundingClientRect().height * 100) / 100])));
  check('P4.5 a kept code span\'s fill and line are as tall as other code\'s, in text and in a heading', k['k-c2'] === k['k-c1'] && k['k-c3'] === k['k-c1'] && k['k-a'] === k['k-c'] && k['k-a'] === k['k-d'] && k['k-h1'] === k['k-h2'], JSON.stringify(k));
  await page.close();
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all typography checks passed');
process.exit(failures ? 1 : 0);
