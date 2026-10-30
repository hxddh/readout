// Highlighting in the worker (highlight.js, highlighter.js, enhance.js):
// the same HTML whatever order blocks are asked for in, a jump not kept
// waiting behind a long block, find landing on its match coloured, the
// reader's selection kept as the colour comes in, a worker that never
// starts replaced by the page's own highlighter.
// Usage: node test/highlight.test.mjs  (requires web/build.mjs to have run)
import { launchBrowser } from './engine.mjs';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const BUILD = process.env.READOUT_WEB_BUILD || 'build/Web';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' };
let hangWorker = false;   // serve a worker script that never answers
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(req.url.split('?')[0]);
  const p = join(BUILD, u);
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  const h = { 'content-type': types[extname(p)] || 'application/octet-stream' };
  if (u === '/hl-worker.js') h['content-security-policy'] = "default-src 'none'; script-src 'self'";
  res.writeHead(200, h);
  res.end(hangWorker && u === '/hl-worker.js' ? 'onmessage = () => {};' : readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launchBrowser();
const errors = [];
let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}
async function open(viewport = { width: 900, height: 900 }, init) {
  const page = await browser.newPage({ viewport });
  collectPageErrors(page, errors);
  if (init) await page.addInitScript(init);
  await page.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await page.goto(`${base}/reader.html`);
  await until(page, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
  await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 }));
  return page;
}
async function until(page, fn, ms = 30000, arg) {
  for (const end = Date.now() + ms; Date.now() < end; await page.waitForTimeout(25)) if (await page.evaluate(fn, arg)) return true;
  return false;
}
const esc = c => c.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const code = (lang, text) => `<div class="code-block" data-lang="${lang}"><pre><code>${esc(text)}</code></pre></div>`;
const doc = items => ({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
  ops: items.map(([kind, html, anchor], i) => ({ op: 'insert', slot: i + 1, after: i, kind, html, ...(anchor ? { anchor } : {}) })) });

// 1. Many languages, embedded ones too (Markdown's fences, Vue's and HTML's
//    blocks), the page opened cold and walked down, and with them prepared
//    and walked up: every block comes out as the highlighter gives it whole. Registering a grammar reloads those that embed it in
//    Shiki; a block highlighted across it starts again (highlighter.js).
{
  const S = {
    bash: 'for f in "$@"; do echo "$f"; done # c', python: 'def f(x: int) -> str:\n    return f"{x!r}"  # c', go: 'package main\nfunc main() { fmt.Println("x") } // c',
    rust: 'fn main() { let x: u8 = 1; println!("{x}"); } // c', java: 'class A { public static void main(String[] a) { System.out.println("x"); } }',
    kotlin: 'fun main() { val x = "y"; println(x) }', c: '#include <stdio.h>\nint main(void) { printf("x\\n"); return 0; }', cpp: 'template<class T> T f(T x) { return x; } // c',
    csharp: 'public class A { public void F() { var x = "y"; } }', ruby: 'def f(x) = x + 1 # c\nputs "hi #{f(1)}"', php: '<?php echo "x"; $a = [1, 2]; ?>',
    sql: "SELECT id, name FROM t WHERE x = 'y'; -- c", swift: 'let x: Int = 1 // c\nfunc f() async throws -> Int { 1 }', lua: 'local x = f(1) -- c',
    html: '<!doctype html>\n<style>body { color: red; } /* c */</style>\n<script>const x = `t ${1}`; // c\n</script>\n<p class="a">x</p>',
    vue: '<template><div :a="b">{{ x }}</div></template>\n<script setup lang="ts">\nconst x: number = 1\n</script>\n<style lang="scss">\n$a: 1px; .b { c: $a; }\n</style>',
    markdown: '---\ntitle: x\n---\n# H\n\n```ts\nconst x: number = 1;\n```\n\n```python\nprint("x")\n```\n\n```bash\necho hi\n```\n\n```lua\nlocal y = 2\n```',
    yaml: 'a: 1\nb: [x, "y"] # c', toml: '[a]\nb = "c" # d', docker: 'FROM node:20\nRUN npm ci # c',
  };
  const rep = (s, n) => Array.from({ length: n }, () => s).join('\n');
  const items = Object.entries(S).flatMap(([l, s]) => [['heading', `<h2>${l}</h2>`], ['code', code(l, rep(s, l === 'markdown' || l === 'vue' || l === 'html' ? 6 : 12))]]);
  const want = {};
  const run = async up => {
    const page = await open();
    if (up) await page.evaluate(l => window.readout.prepare(l), Object.keys(S));
    await page.evaluate(p => window.readout.apply(p), doc(items));
    for (let i = 0; i < 400; i++) {
      const more = await page.evaluate(up => { const all = [...document.querySelectorAll('.code-block[data-hl="pending"]')]; const n = up ? all.at(-1) : all[0]; n?.scrollIntoView({ block: 'center' }); return !!n; }, up);
      if (!more) break;
      await page.waitForTimeout(60);
    }
    // (Both as this browser serializes them.)
    const out = await page.evaluate(want => [...document.querySelectorAll('.code-block')].map(c => {
      const t = document.createElement('template'); t.innerHTML = want[c.dataset.lang];
      const a = c.querySelector('pre').outerHTML, b = t.content.firstElementChild.outerHTML;
      return [c.dataset.lang, c.dataset.hl, a === b];
    }), want);
    await page.close();
    return out;
  };
  // The reference, in this browser (its regex engine): each block alone in a
  // fresh worker, asked twice, the second time with every grammar it needs
  // already registered; one at a time, as a line taking longer than the
  // tokenizing limit (500 ms) comes out cut short (highlighter.js).
  {
    const page = await open();
    for (const [l, c] of Object.entries(S).map(([l, s]) => [l, rep(s, l === 'markdown' || l === 'vue' || l === 'html' ? 6 : 12)])) want[l] = await page.evaluate(([l, c]) => new Promise(resolve => {
      const w = new Worker('hl-worker.js', { type: 'module' });
      w.postMessage({ op: 'init', limit: window.READOUT_TOKENIZE_LIMIT });
      w.onmessage = e => {
        const m = e.data;
        if (m.op === 'ready') w.postMessage({ op: 'hl', id: 1, code: c, lang: l, prio: 0 });
        else if (m.op === 'spare?') w.postMessage({ op: 'spare', n: m.n, ok: false });
        else if (m.op === 'done' && m.id === 1) w.postMessage({ op: 'hl', id: 2, code: c, lang: l, prio: 0 });
        else if (m.op === 'done' && m.id === 2) { w.terminate(); resolve(m.html); }
      };
    }), [l, c]);
    await page.close();
  }
  for (const [name, up] of [['cold, walked down', false], ['prepared, walked up', true]]) {
    const got = await run(up);
    const differ = got.filter(([, h, same]) => h !== 'done' || !same).map(([l, h]) => `${l}:${h}`);
    check(`many languages (${name}): every block as highlighted whole`, differ.length === 0 && got.length === Object.keys(S).length, JSON.stringify(differ));
  }
}

// 2. A jump onto a block while a long one on screen is still being
//    highlighted (heavy lines first): what the jump lands on goes first, and
//    shows coloured in its first frame, well before the hold's limit (3 s:
//    half that here, on a loaded runner).
{
  const heavy = i => '{' + Array.from({ length: 40 }, (_, k) => `"k${k}_${i}": [${k}, "v\\n${k}", true, null, ${k}.5e3]`).join(', ') + '},';
  const A = ['['].concat(Array.from({ length: 2000 }, (_, i) => heavy(i)), ['0]']).join('\n');
  const B = Array.from({ length: 200 }, (_, i) => `export function f${i}(a: number): string { return "x" + a; } // ${i}`).join('\n');
  const items = [['heading', '<h1>H</h1>'], ['code', code('json', A)], ...Array.from({ length: 100 }, (_, i) => ['paragraph', `<p>P ${i}</p>`]), ['heading', '<h2 id="t">T</h2>', 't'], ['code', code('ts', B)]];
  const page = await open();
  await page.evaluate(() => window.readout.prepare(['ts']));
  await until(page, () => performance.getEntriesByName('readout-hl-prepared').length > 0);
  await page.evaluate(p => window.readout.apply(p), doc(items));
  await page.waitForTimeout(1500);
  const r = await page.evaluate(hs => new Promise(resolve => {
    const se = document.scrollingElement, y0 = se.scrollTop, t0 = performance.now();
    window.readout.scrollToSlot(hs);
    const f = () => requestAnimationFrame(() => {
      if (Math.abs(se.scrollTop - y0) > 1) {
        const cb = document.querySelector(`.blk[data-slot="${hs + 1}"] .code-block`);
        return resolve({ ms: Math.round(performance.now() - t0), coloured: cb.querySelectorAll('.line span[style]').length > 0, longBlock: document.querySelector('.blk[data-slot="2"] .code-block').dataset.hl });
      }
      if (performance.now() - t0 > 8000) return resolve({ ms: -1 });
      f();
    });
    f();
  }), items.length - 1);
  check('a jump while a long block is highlighted: its landing first, coloured in its first frame', r.coloured && r.ms >= 0 && r.ms < 1500 && r.longBlock === 'pending', JSON.stringify(r));
  await page.close();
}

// 3. Find landing on a match far down a long block not highlighted yet:
//    the first frame showing the match's line shows it coloured, and it is
//    selected.
{
  const lines = Array.from({ length: 600 }, (_, i) => i === 360 ? 'const line360end = 360; // the match' : `export function f${i}(a: number): string { return "x" + a; } // ${i}`);
  const items = [...Array.from({ length: 200 }, (_, i) => ['paragraph', `<p>Paragraph ${i} ${'lorem ipsum '.repeat(8)}</p>`]), ['code', code('ts', lines.join('\n'))], ...Array.from({ length: 20 }, (_, i) => ['paragraph', `<p>After ${i}</p>`])];
  const page = await open();
  await page.evaluate(() => window.readout.prepare(['ts']));
  await until(page, () => performance.getEntriesByName('readout-hl-prepared').length > 0);
  await page.evaluate(p => window.readout.apply(p), doc(items));
  await page.waitForTimeout(800);
  const r = await page.evaluate(() => new Promise(resolve => {
    const t0 = performance.now();
    window.readout.find('line360end');
    // (The block is aimed at first, the match once laid out: anchor.js.)
    const f = () => requestAnimationFrame(() => {
      const line = [...document.querySelectorAll('.code-block pre .line')].find(l => l.textContent.includes('line360end'));
      const b = line?.getBoundingClientRect();
      if (b && b.top >= 0 && b.bottom <= innerHeight) {
        const ms = Math.round(performance.now() - t0), coloured = !!line.querySelector('span[style]');
        return setTimeout(() => resolve({ ms, coloured, onScreen: true, selected: getSelection().toString() }), 100);
      }
      if (performance.now() - t0 > 8000) return resolve({ ms: -1, onScreen: false });
      f();
    });
    f();
  }));
  check('find landing in a long block not coloured yet: the match\'s line coloured in the first frame it is on screen, selected', r.coloured && r.onScreen && r.selected === 'line360end', JSON.stringify(r));
  await page.close();
}

// 4. The reader's selection in code still plain when its colour comes in (a
//    long block, a part at a time, then all of it): kept, the same text.
{
  const B = i => Array.from({ length: 600 }, (_, l) => `export function f${i}_${l}(a: number): string { return "x" + a; } // ${l}`).join('\n');
  const items = Array.from({ length: 6 }, (_, i) => [['paragraph', `<p>Para ${i}</p>`], ['code', code('ts', B(i))]]).flat();
  const page = await open();
  await page.evaluate(() => window.readout.prepare(['ts']));
  await until(page, () => performance.getEntriesByName('readout-hl-prepared').length > 0);
  await page.evaluate(p => window.readout.apply(p), doc(items));
  await until(page, () => getComputedStyle(document.getElementById('ro-doc')).visibility !== 'hidden');
  const before = await page.evaluate(() => {
    const cb = document.querySelector('.blk[data-slot="2"] .code-block');
    const rest = cb.querySelector('pre code').lastChild;   // its plain lines (the first ones coloured first)
    const t = rest.nodeType === 3 && rest.length > 3000 ? rest : null;
    if (!t) return { none: cb.dataset.hl };
    const r = document.createRange(); r.setStart(t, 2000); r.setEnd(t, 2200);
    getSelection().removeAllRanges(); getSelection().addRange(r);
    return { text: getSelection().toString(), hl: cb.dataset.hl };
  });
  await until(page, () => document.querySelector('.blk[data-slot="2"] .code-block').dataset.hl === 'done');
  await page.waitForTimeout(300);
  const after = await page.evaluate(() => getSelection().toString());
  check('a selection in plain code kept as its colour comes in, part by part', !!before.text && before.text.length === 200 && after === before.text, JSON.stringify({ before: before.text?.slice(0, 40) ?? before, after: after.slice(0, 40) }));
  await page.close();
}

// 5. A worker that runs but never answers: the page highlights itself.
{
  hangWorker = true;
  const page = await open();
  await page.evaluate(p => window.readout.apply(p), doc([['code', code('json', '{ "a": [1, true, null] }')]]));
  const ok = await until(page, () => document.querySelector('.code-block').dataset.hl === 'done', 15000);
  const engine = await page.evaluate(() => window.readout.highlighter());
  check('a worker that never answers: the page highlights instead', ok && engine === 'page', JSON.stringify({ ok, engine }));
  await page.close();
  hangWorker = false;
}

// 6. N onto code not coloured yet (the worker's answers held up 2 s here):
//    the jump waits; N again meanwhile (or a rail tick, then N) drops it,
//    and the change it never landed on stays unread.
{
  const delayed = () => {
    const pm = Worker.prototype.postMessage;
    Worker.prototype.postMessage = function (m) { if (m && m.op === 'hl') setTimeout(() => pm.call(this, m), 2000); else pm.call(this, m); };
  };
  const ts = Array.from({ length: 30 }, (_, i) => `export const v${i}: number = ${i}; // ${i}`).join('\n');
  const items = [...Array.from({ length: 60 }, (_, i) => ['paragraph', `<p>Before ${i} ${'lorem ipsum '.repeat(8)}</p>`]), ['code', code('ts', ts)],
    ...Array.from({ length: 60 }, (_, i) => ['paragraph', `<p>Between ${i} ${'lorem ipsum '.repeat(8)}</p>`]), ['code', code('ts', ts + '\n// two')],
    ...Array.from({ length: 20 }, (_, i) => ['paragraph', `<p>After ${i}</p>`])];
  const first = 61, second = 122;
  const key = (page, k) => page.evaluate(k => document.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true })), k);
  const read = (page, slot) => page.evaluate(s => document.querySelector(`.blk[data-slot="${s}"]`).classList.contains('m-read'), slot);
  for (const how of ['N, then N', 'a rail tick, then N']) {
    const page = await open({ width: 900, height: 700 }, delayed);
    await page.emulateMedia({ reducedMotion: 'reduce' });   // (N jumps, not a smooth scroll: marks.js)
    await page.evaluate(() => window.readout.prepare(['ts']));
    await until(page, () => performance.getEntriesByName('readout-hl-prepared').length > 0);
    await page.evaluate(p => window.readout.apply(p), { ...doc(items), marks: [{ slot: first, kind: 'inserted' }, { slot: second, kind: 'inserted' }] });
    await page.waitForTimeout(500);
    const y0 = await page.evaluate(() => scrollY);
    if (how === 'N, then N') await key(page, 'n');
    else await page.evaluate(() => document.querySelector('#ro-rail button').click());
    await page.waitForTimeout(400);   // past the 250 ms after which leaving a visited change reads it
    const held = await page.evaluate(y0 => Math.abs(scrollY - y0) < 2, y0);
    await key(page, 'n');
    const r = { held, firstRead: await read(page, first) };
    await page.waitForTimeout(100);
    r.firstReadLater = await read(page, first);
    check(`${how} while the first jump waits for its code: the change it never landed on stays unread`, r.held && !r.firstRead && !r.firstReadLater, JSON.stringify(r));
    await page.close();
  }
}

// A first window at launch restoring a place on code, the highlighter not
// started yet (it starts with the first appearance, in the same task): the
// place shows in the document's first frame, its code plain, as a first
// paint at launch does (3.9.1: 2-7 ms), not after the code is coloured
// (640-740 ms showing the top, the place lost to a scroll meanwhile).
{
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(page, errors);
  await page.addInitScript(() => { window.__msgs = []; window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } }; });
  await page.goto(`${base}/reader.html`);
  await until(page, () => window.readout && window.__msgs.some(m => m.type === 'ready'));
  const items = [...Array.from({ length: 150 }, (_, k) => ['paragraph', `<p>Paragraph ${k} with some words to fill the line and push the code further down the page.</p>`]),
    ['code', code('typescript', Array.from({ length: 30 }, (_, i) => `export const v${i}: number = ${i} * 2; // line ${i}`).join('\n'))],
    ...Array.from({ length: 40 }, (_, k) => ['paragraph', `<p>After ${k}.</p>`])];
  const r = await page.evaluate(async d => {
    window.readout.setAppearance({ dark: false, accent: '#0a84ff', fontSize: 16 });
    const started = window.readout.highlighter?.();
    window.readout.apply(d);
    window.readout.scrollToAnchor({ slot: 151, offset: 0, ratio: 0 });
    const t0 = performance.now(), el = document.querySelector('.blk[data-slot="151"]'), doc = document.getElementById('ro-doc');
    let elsewhere = 0, landed = -1;
    while (performance.now() - t0 < 4000) {
      await new Promise(r => requestAnimationFrame(() => setTimeout(r, 0)));
      if (doc.classList.contains('hold') || getComputedStyle(doc).visibility === 'hidden') continue;
      if (Math.abs(el.getBoundingClientRect().top) <= 2) { landed = performance.now() - t0; break; }
      elsewhere++;
    }
    return { started, landed: Math.round(landed), elsewhere };
  }, doc(items));
  check('a first window at launch restoring a place on code lands in its first frame, without waiting for the highlighter',
    r.started === 'starting' && r.landed >= 0 && r.landed < 300 && r.elsewhere === 0, JSON.stringify(r));
  await page.close();
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));
await browser.close();
server.close();
console.log(failures ? `${failures} failure(s)` : 'all highlight checks passed');
process.exit(failures ? 1 : 0);
