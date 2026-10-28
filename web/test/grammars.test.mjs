// The grammars the reader ships (shiki-grammars.mjs: converted to ES2018
// regexes at build time where TextMate allows it), with the engine the reader
// uses (target ES2018), highlight exactly as Shiki's own grammars and engine
// do, on every code block of the corpus and on patterns that depend on what
// converting would break (\G anchors, back-references from an end pattern).
// Usage: node test/grammars.test.mjs   (Node only, no browser)
import * as esbuild from 'esbuild';
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createHighlighterCore } from 'shiki/core';
import { createJavaScriptRegexEngine } from 'shiki/engine/javascript';
import { shikiGrammars } from '../shiki-grammars.mjs';
import { resolveLang, plainTokens, init, prepare, highlightSync, blockSteps, redone, ensureLang } from '../src/highlighter.js';

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}

// A token is left as bare text only when its span's whole style is the
// block's own colour in both themes (highlighter.js: plainTokens): a theme
// switch does not highlight again, so a token in the block's colour in one
// theme only, or with a font style, keeps its span.
{
  const pre = '<pre class="shiki" style="--shiki-light:#1f2328;--shiki-dark:#e6edf3;--shiki-light-bg:#fff;--shiki-dark-bg:#0d1117"><code><span class="line">';
  const tail = '</span></code></pre>';
  const run = spans => plainTokens(pre + spans + tail).slice(pre.length, -tail.length);
  const own = '<span style="--shiki-light:#1F2328;--shiki-dark:#E6EDF3">own</span>';
  const lightOnly = '<span style="--shiki-light:#1f2328;--shiki-dark:#FF7B72">light only</span>';
  const darkOnly = '<span style="--shiki-light:#CF222E;--shiki-dark:#e6edf3">dark only</span>';
  const italic = '<span style="--shiki-light:#1f2328;--shiki-dark:#e6edf3;--shiki-light-font-style:italic;--shiki-dark-font-style:italic">italic</span>';
  const bold = '<span style="--shiki-light:#1f2328;--shiki-dark:#e6edf3;font-weight:bold">bold</span>';
  check('a token in the block\'s own colours in both themes is its text alone', run(own) === 'own', run(own));
  for (const [name, span] of [['the block\'s colour in light only', lightOnly], ['the block\'s colour in dark only', darkOnly], ['an italic token in the block\'s colours', italic], ['a bold one', bold]]) {
    check(`${name} keeps its span`, run(span) === span, run(span));
  }
  check('a mix keeps each as it should be', run(own + lightOnly + own + italic) === 'own' + lightOnly + 'own' + italic, run(own + lightOnly + own + italic));
}

// Every grammar highlighter.js can load.
const ids = [...readFileSync('src/highlighter.js', 'utf8').matchAll(/import\('@shikijs\/langs\/([\w-]+)'\)/g)].map(m => m[1]);
const entry = ids.map((id, i) => `import g${i} from '@shikijs/langs/${id}';`).join('\n')
  + `\nexport default {${ids.map((id, i) => `${JSON.stringify(id)}: g${i}`).join(',')}};`;
const out = await esbuild.build({
  stdin: { contents: entry, resolveDir: process.cwd(), loader: 'js' },
  bundle: true, format: 'esm', platform: 'node', write: false, plugins: [shikiGrammars], logLevel: 'error',
});
mkdirSync('test/out', { recursive: true });
writeFileSync('test/out/grammars.mjs', out.outputFiles[0].text);
const shipped = (await import(pathToFileURL('test/out/grammars.mjs').href)).default;

// Most patterns arrive compiled (else the plugin is doing nothing).
let compiled = 0, source = 0;
const count = v => {
  if (v instanceof RegExp) compiled++;
  else if (Array.isArray(v)) v.forEach(count);
  else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { if (typeof x === 'string' && /^(match|begin|end|while)$/.test(k)) source++; else count(x); }
};
for (const id of ids) count(shipped[id].at(-1));
check('most grammar patterns ship converted', compiled > 4 * source, JSON.stringify({ compiled, source }));

async function highlighter(grammars, engine) {
  const h = await createHighlighterCore({ themes: [import('@shikijs/themes/github-light-default'), import('@shikijs/themes/github-dark-default')], langs: [], engine: createJavaScriptRegexEngine({ forgiving: true, ...engine }) });
  for (const id of ids) await h.loadLanguage(grammars[id]);
  return h;
}
const runtime = {};
for (const id of ids) runtime[id] = (await import(`@shikijs/langs/${id}`)).default;
const [a, b] = [await highlighter(runtime), await highlighter(shipped, { target: 'ES2018' })];

// Converted for ES2018: no pattern the reader compiles carries the v flag,
// which WebKit compiles hundreds of times slower.
const vFlag = Object.values(shipped).flat().flatMap(function walk(v) {
  if (v instanceof RegExp) return v.flags.includes('v') ? [v.source.slice(0, 40)] : [];
  if (v && typeof v === 'object') return Object.values(v).flatMap(walk);
  return [];
});
check('no shipped pattern uses the v flag', vFlag.length === 0, vFlag.slice(0, 3).join(' | '));
const html = (h, code, id) => h.codeToHtml(code, { lang: id, themes: { light: 'github-light-default', dark: 'github-dark-default' }, defaultColor: false, tokenizeTimeLimit: 0 });

// Code that converting every pattern gets wrong.
const samples = [
  ['shellscript', 'grep -n "2.2 Dropout" -A 5 README.md\ngit commit -m "content: update"'],   // \G: arguments
  ['shellscript', 'cat <<EOF > out.txt\nhello $USER\nEOF\necho done'],                         // end refers to begin
  ['python', 'def f(a: int) -> str:\n    return "x" + f"{a}"'],
  ['java', 'public class A { private int x = 1; void f() { return; } }'],
  ['markdown', '# Title\n\n```bash\nnpm test\n```\n\n- item `code`'],
  ['yaml', 'on:\n  push:\n    branches: [main]\nrun: |\n  npm ci\n  npm test'],
];
for (const [id, code] of samples) check(`${id} sample highlights as with Shiki's grammar`, html(a, code, id) === html(b, code, id), code.split('\n')[0]);

// Every fenced block of the corpus.
const FENCE = /^([ \t]*)(`{3,}|~{3,})[ \t]*([^\s`{]*)[^\n]*\n([\s\S]*?)\n\1\2/gm;
let blocks = 0, differ = [];
for (const f of readdirSync('test/corpus').filter(f => f.endsWith('.md'))) {
  for (const m of readFileSync(`test/corpus/${f}`, 'utf8').matchAll(FENCE)) {
    const id = resolveLang(m[3]);
    if (!id) continue;
    blocks++;
    if (html(a, m[4], id) !== html(b, m[4], id)) differ.push(`${f} (${id})`);
  }
}
check(`corpus code blocks highlight as with Shiki's grammars (${blocks})`, blocks > 200 && differ.length === 0, differ.slice(0, 10).join(', '));

// A long block highlighted a part at a time (highlighter.js: blockSteps, in
// the worker, so a block more urgent waits for one part at most), each part
// going on from the state the last one left, comes out exactly as
// highlighted in one go: comments, strings and templates that run across a
// part's edge included. And the lines on screen sent first (upto), and the
// parts sent after them, are those lines of it.
{
  await init();
  const samples = {
    typescript: Array.from({ length: 100 }, (_, i) => i % 17 === 5 ? '/* a comment that\n spans lines */' : i % 13 === 3 ? 'const s = `template ${i}' : i % 13 === 4 ? `goes on ${i}\`;` : `export function f${i}(a: number): string { return "x" + a; } // ${i}`).join('\n'),
    python: Array.from({ length: 100 }, (_, i) => i % 11 === 2 ? '"""a docstring' : i % 11 === 3 ? 'over lines"""' : `def f${i}(x: int) -> str:  # ${i}\n    return f"{x!r}"`).join('\n'),
    markdown: Array.from({ length: 100 }, (_, i) => i % 23 === 1 ? '```js' : i % 23 === 6 ? '```' : i % 7 === 0 ? `## Heading ${i}` : `Some *text* with \`code\` ${i}`).join('\n'),
  };
  const run = (code, id, size, upto) => {
    const r = { code, lang: id, upto }, parts = [];
    const steps = blockSteps(r, (html, lines, first) => parts.push([html, lines, first]), size);
    let x;
    do x = steps.next(); while (!x.done);
    return { html: x.value, parts };
  };
  const bad = [];
  for (const [id, code] of Object.entries(samples)) {
    await prepare(id, code);
    const whole = highlightSync(code, id);
    const lines = code.split('\n');
    // 4 lines a part, 32, and parts as long as they take (the worker's), with the screen's lines first or not.
    for (const [size, upto] of [[4, 0], [32, 0], [0, 0], [4, 37], [0, 9]]) {
      const { html, parts } = run(code, id, size, upto);
      if (!whole || html !== whole) bad.push(`${id} (${size}, ${upto})`);
      // The first: the lines up to the screen's last, as a <pre>; the parts after, put after it, the whole but for its last part.
      const sent = parts.length && `${parts[0][0].slice(0, -'</code></pre>'.length)}${parts.slice(1).map(p => '\n' + p[0]).join('')}`;
      const last = parts.at(-1)?.[1];
      if (upto && (!parts.length || !parts[0][2] || parts.slice(1).some(p => p[2]) || parts[0][1] < upto
          || parts[0][0] !== highlightSync(lines.slice(0, parts[0][1]).join('\n'), id) || sent !== highlightSync(lines.slice(0, last).join('\n'), id).slice(0, -'</code></pre>'.length))) bad.push(`${id} first ${upto} lines (${size}): ${parts.map(p => p[1])}`);
    }
  }
  check('a long block highlighted a part at a time comes out as highlighted whole, its lines on screen first as they are in it', bad.length === 0, bad.join(', '));
}

// A part highlighted with a grammar not used before that took Shiki's
// per-line limit or longer may have had a line cut short: it is highlighted
// again, once. With a grammar used before never, however long it takes; nor
// a block of a cold grammar whose parts are each quick, however long they
// add up to. (Every clock reading moves on `step` ms: each part takes that.)
{
  const real = performance.now.bind(performance);
  const timed = (step, f) => { let skew = 0; performance.now = () => (skew += step) + real(); try { return f(); } finally { performance.now = real; } };
  const go = (code, id) => { const steps = blockSteps({ code, lang: id }, () => {}, 4); let x; do x = steps.next(); while (!x.done); return x.value; };
  const lua = Array.from({ length: 40 }, (_, l) => `local x${l} = f(${l}) -- note`).join('\n');
  const perl = Array.from({ length: 40 }, (_, l) => `my $x${l} = $y + ${l};`).join('\n');
  await prepare('lua', lua);
  await prepare('perl', perl);
  const before = redone.parts;
  const cold = timed(600, () => go(lua, 'lua'));
  const coldOnce = redone.parts - before;
  const warm = timed(600, () => go(lua, 'lua'));
  const warmAgain = redone.parts - before - coldOnce;
  const quick = timed(5, () => go(perl, 'perl'));
  const quickAgain = redone.parts - before - coldOnce - warmAgain;
  check('a slow part with a cold grammar is highlighted again once; with a warm one, or quick parts adding up, never',
    coldOnce === 1 && warmAgain === 0 && quickAgain === 0 && cold === warm && cold === highlightSync(lua, 'lua') && quick === highlightSync(perl, 'perl'),
    JSON.stringify({ coldOnce, warmAgain, quickAgain }));
}

// A grammar registered between two parts of a block (another block's, in
// the worker) makes Shiki load again the grammars that embed it, and the
// state carried from the part before is no longer theirs: the block starts
// again from its first line, and comes out as highlighted whole.
{
  const md = '---\ntitle: x\n---\n# H\n\n```ts\nconst x: number = 1;\n```\n\n```python\nprint("x")\n```\n\n```bash\necho hi\n```';
  const code = md + '\n' + md;
  await prepare('markdown', code);
  const whole = highlightSync(code, 'markdown');
  const bad = [];
  for (const other of ['lua', 'rust', 'html', 'vue']) {
    const steps = blockSteps({ code, lang: 'markdown' }, () => {}, 15);
    let x = steps.next(), k = 0;
    while (!x.done) { if (k++ === 0) await ensureLang(other); x = steps.next(); }
    if (x.value !== whole) bad.push(other);
  }
  check('a grammar registered between a block\'s parts: the block comes out as highlighted whole', bad.length === 0, bad.join(', '));
}

console.log(failures ? `${failures} failure(s)` : 'all grammar checks passed');
process.exit(failures ? 1 : 0);
