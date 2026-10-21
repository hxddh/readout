// Syntax highlighting with Shiki (JavaScript regex engine, no WASM).
// Grammars are loaded on demand; the three agent output uses most are
// preloaded (not in Quick Look, which loads only what the preview shows).
// Shiki itself is loaded on first use.
//
// The grammars come mostly converted: the build (shiki-grammars.mjs) serves
// each '@shikijs/langs/<id>' import with its patterns already converted to
// ES2018 JavaScript regexes, except the few TextMate rewrites before
// matching, which stay Oniguruma source and are converted here, for ES2018
// too. The highlighting is Shiki's (test/grammars.test.mjs); a grammar's first
// use is faster.

const LANGS = {
  shellscript: () => import('@shikijs/langs/shellscript'),
  shellsession: () => import('@shikijs/langs/shellsession'),
  javascript: () => import('@shikijs/langs/javascript'),
  typescript: () => import('@shikijs/langs/typescript'),
  tsx: () => import('@shikijs/langs/tsx'),
  jsx: () => import('@shikijs/langs/jsx'),
  json: () => import('@shikijs/langs/json'),
  jsonc: () => import('@shikijs/langs/jsonc'),
  jsonl: () => import('@shikijs/langs/jsonl'),
  yaml: () => import('@shikijs/langs/yaml'),
  toml: () => import('@shikijs/langs/toml'),
  swift: () => import('@shikijs/langs/swift'),
  python: () => import('@shikijs/langs/python'),
  go: () => import('@shikijs/langs/go'),
  rust: () => import('@shikijs/langs/rust'),
  java: () => import('@shikijs/langs/java'),
  kotlin: () => import('@shikijs/langs/kotlin'),
  c: () => import('@shikijs/langs/c'),
  cpp: () => import('@shikijs/langs/cpp'),
  csharp: () => import('@shikijs/langs/csharp'),
  'objective-c': () => import('@shikijs/langs/objective-c'),
  ruby: () => import('@shikijs/langs/ruby'),
  php: () => import('@shikijs/langs/php'),
  sql: () => import('@shikijs/langs/sql'),
  html: () => import('@shikijs/langs/html'),
  css: () => import('@shikijs/langs/css'),
  scss: () => import('@shikijs/langs/scss'),
  markdown: () => import('@shikijs/langs/markdown'),
  diff: () => import('@shikijs/langs/diff'),
  docker: () => import('@shikijs/langs/docker'),
  makefile: () => import('@shikijs/langs/makefile'),
  graphql: () => import('@shikijs/langs/graphql'),
  xml: () => import('@shikijs/langs/xml'),
  lua: () => import('@shikijs/langs/lua'),
  r: () => import('@shikijs/langs/r'),
  scala: () => import('@shikijs/langs/scala'),
  powershell: () => import('@shikijs/langs/powershell'),
  ini: () => import('@shikijs/langs/ini'),
  proto: () => import('@shikijs/langs/proto'),
  hcl: () => import('@shikijs/langs/hcl'),
  terraform: () => import('@shikijs/langs/terraform'),
  nginx: () => import('@shikijs/langs/nginx'),
  vue: () => import('@shikijs/langs/vue'),
  svelte: () => import('@shikijs/langs/svelte'),
  zig: () => import('@shikijs/langs/zig'),
  elixir: () => import('@shikijs/langs/elixir'),
  haskell: () => import('@shikijs/langs/haskell'),
  dart: () => import('@shikijs/langs/dart'),
  perl: () => import('@shikijs/langs/perl'),
};

const ALIASES = {
  sh: 'shellscript', bash: 'shellscript', zsh: 'shellscript', shell: 'shellscript',
  // A terminal transcript: prompts, commands and their output.
  console: 'shellsession', 'shell-session': 'shellsession', terminal: 'shellsession',
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', ts: 'typescript', mts: 'typescript',
  py: 'python', python3: 'python', rs: 'rust', golang: 'go', kt: 'kotlin', 'c++': 'cpp', h: 'c', hpp: 'cpp',
  cs: 'csharp', 'c#': 'csharp', objc: 'objective-c', rb: 'ruby', yml: 'yaml', md: 'markdown',
  dockerfile: 'docker', make: 'makefile', gql: 'graphql', svg: 'xml', ps1: 'powershell', pwsh: 'powershell',
  tf: 'terraform', ex: 'elixir', exs: 'elixir', hs: 'haskell', patch: 'diff', htm: 'html', cfg: 'ini',
  conf: 'ini', env: 'shellscript', ndjson: 'jsonl', protobuf: 'proto',
};

// Each preloaded grammar costs every tab its memory (12 of them: ~40 MB of
// a warmed page's private memory); the rest load on first use, which ES2018
// patterns keep to tens or hundreds of milliseconds.
const PRELOAD = ['shellscript', 'json', 'typescript'];

let highlighter = null;
let ready = null;
let preload = true;        // Quick Look turns it off: it loads only the grammars a preview needs
let initialized = false;   // the preloaded grammars are all registered
const loading = new Map();
const failed = new Set();  // grammars that could not be loaded (never waited for again)
const lazyOf = new Map();  // grammar id -> languages it embeds only when they are loaded
const grammarsOf = new Map();  // preloaded grammar id -> its grammar modules (for the warm-up)

export function resolveLang(lang) {
  if (!lang) return null;
  const l = lang.toLowerCase();
  const id = ALIASES[l] || l;
  return LANGS[id] ? id : null;
}

/** Quick Look: no grammars are loaded ahead of need (call before init). */
export function noPreload() { preload = false; }

// A terminal transcript's output is secondary text, not the link blue the
// GitHub themes give it (#0550ae / #79c0ff, the colour of constants): a grey
// for that scope alone, so the options and numbers in its commands keep theirs.
async function quietOutput(theme, color) {
  const t = (await theme).default;
  return { ...t, tokenColors: [...t.tokenColors, { scope: 'meta.output.shell-session', settings: { foreground: color } }] };
}

export function init() {
  if (ready) return ready;
  ready = (async () => {
    window.__boot?.push(['hl_init', Date.now() / 1000]);
    const [{ createHighlighterCore }, { createJavaScriptRegexEngine }] =
      await Promise.all([import('shiki/core'), import('shiki/engine/javascript')]);
    highlighter = await createHighlighterCore({
      themes: [
        quietOutput(import('@shikijs/themes/github-light-default'), '#5f5f66'),
        quietOutput(import('@shikijs/themes/github-dark-default'), '#a8a8ae'),
      ],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true, target: 'ES2018' }),
    });
    window.__boot?.push(['hl_created', Date.now() / 1000]);
    // Fetch every preloaded grammar at once; ensureLang registers them one
    // at a time, in this order.
    if (preload) await Promise.all(PRELOAD.map(id => ensureLang(id)));
    initialized = true;
    window.__boot?.push(['hl_initialized', Date.now() / 1000]);
  })();
  return ready;
}

// Loading a grammar does not compile its patterns: the first block it
// highlights does, which cost the first code block of a warm open 170-220 ms
// inside the page's first apply (TypeScript's patterns alone take WebKit
// hundreds of milliseconds). So the app's spare page (warm), once the
// preloaded grammars are in and it has then sat unused for a while (a spare
// page usually waits minutes for its window), compiles each grammar's
// patterns one at a time and runs a few lines of each language through it,
// in slices of a few milliseconds, one per task: a window taking the page
// meanwhile waits for one slice at most (one pattern: TypeScript's largest
// is the longest step), and nothing more is done once it shows a document
// (stopWarmUp, enhance.js). Only on the spare page: a page being read should
// not spend its main thread on languages it may not show. Never in Quick
// Look, which preloads nothing. Marks 'readout-hl-warm' when done (perf.test.mjs).
let warming = false;
let warmStopped = false;
export function warm() {
  return init().then(() => {
    if (!preload || warming || warmStopped) return;
    warming = true;
    setTimeout(warmUp, WARM_DELAY_MS);
  });
}

/** The page shows a document: no more warming up. */
export function stopWarmUp() { warmStopped = true; }

const TS_SAMPLE = [
  'import { readFile } from "node:fs/promises";',
  'import type { Plan } from "./plan.js";',
  '/** A doc comment. */',
  'export interface Item<T = unknown> { id: number; name?: string; tags: readonly string[]; value: T | null }',
  'type Kind = "a" | "b";',
  'enum Mode { On = 1, Off }',
  'export class Store<T> extends Base implements Iterable<T> {',
  '  private readonly items = new Map<string, T>();',
  '  constructor(public path: string, opts: { strict?: boolean } = {}) { super(); }',
  '  async load(): Promise<number> {',
  '    try {',
  '      const text = await readFile(this.path, "utf8");',
  '      for (const [i, line] of text.split("\\n").entries()) {',
  '        if (!line.trim() || line.startsWith("#")) continue;',
  '        const m = /^- \\[( |x)\\] (.+)$/i.exec(line);',
  "        this.items.set(`${i}:${m?.[2] ?? ''}`, JSON.parse(line) as T);",
  '      }',
  '    } catch (err) {',
  '      throw new Error(`cannot read ${this.path}: ${String(err)}`);',
  '    }',
  '    return this.items.size;',
  '  }',
  '}',
  'export const total = (xs: number[]): number => xs.filter(x => x > 0).reduce((a, b) => a + b, 0) * 1.5e3; // done',
  'switch (mode) { case Mode.On: break; default: console.log(null, undefined, true); }',
].join('\n');
const SAMPLES = {
  shellscript: [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'for f in "$@"; do',
    '  if [[ -n "${f:-}" && -f "$f" ]]; then echo "ok: $(basename "$f")" | tee -a out.log; fi',
    'done',
    'export PATH="$HOME/bin:$PATH"  # comment',
    'case "$1" in start) npm run build --silent 2>&1 ;; *) exit 1 ;; esac',
  ].join('\n'),
  json: '{\n  "name": "x",\n  "n": 1.5e3,\n  "ok": true,\n  "list": [null, {"a": "b\\n"}]\n}',
  typescript: TS_SAMPLE,
};
const WARM_DELAY_MS = 5000;
const WARM_ORDER = ['typescript', 'shellscript', 'json'];   // the slowest first
// The regexes of a grammar, as the build precompiled them: WebKit compiles
// each on its first use, which is what makes a grammar's first block slow.
function regexesOf(id) {
  const out = new Set(), seen = new Set();
  const walk = v => {
    if (v instanceof RegExp) { out.add(v); return; }
    if (!v || typeof v !== 'object' || seen.has(v)) return;
    seen.add(v);
    for (const k in v) walk(v[k]);
  };
  walk(grammarsOf.get(id));
  return [...out];
}

const SLICE_MS = 8;
function warmUp() {
  const ids = WARM_ORDER.filter(id => SAMPLES[id] && highlighter.getLoadedLanguages().includes(id));
  const work = [];
  for (const id of ids) {
    for (const r of regexesOf(id)) work.push(() => { try { r.lastIndex = 0; r.exec(''); } catch { /* not ours to fix */ } });
    // Then its sample, a line per step (carrying the grammar's state), so
    // the rules it reaches are set up as they are for a block.
    let state;
    for (const line of SAMPLES[id].split('\n')) {
      work.push(() => {
        try {
          const tokens = highlighter.codeToTokensBase(line, { lang: id, theme: 'github-light-default', ...(state ? { grammarState: state } : {}) });
          state = highlighter.getLastGrammarState(tokens);
        } catch { state = undefined; }
      });
    }
  }
  // And the whole path once, as a block is highlighted (both themes, HTML).
  work.push(() => highlightSync('x', 'json'));
  const next = () => {
    if (warmStopped) return;
    const t0 = performance.now();
    do {
      const step = work.shift();
      if (!step) { performance.mark('readout-hl-warm'); return; }
      step();
    } while (performance.now() - t0 < SLICE_MS);
    setTimeout(next, 0);
  };
  next();
}

// Grammars are registered one at a time, in request order. Several modules
// carry their own copies of embedded grammars (markdown embeds shell, for
// one), so concurrent loads registered them in whatever order the imports
// resolved and the same block could highlight differently between loads.
let registry = Promise.resolve();

export function ensureLang(id) {
  if (!highlighter) return init().then(() => ensureLang(id));
  if (highlighter.getLoadedLanguages().includes(id)) return Promise.resolve();
  if (!loading.has(id)) {
    const load = LANGS[id]();   // fetch in parallel, register in order
    const done = registry.then(() => load).then(m => {
      const main = m.default.find(g => g.name === id) || m.default[m.default.length - 1];
      lazyOf.set(id, main?.embeddedLangsLazy || []);
      if (preload) grammarsOf.set(id, m.default);
      window.__boot?.push(['hl_fetched_' + id, Date.now() / 1000]);
      const r = highlighter.loadLanguage(m.default);
      window.__boot?.push(['hl_registered_' + id, Date.now() / 1000]);
      return r;
    }).catch(() => { failed.add(id); });
    registry = done;
    loading.set(id, done);
  }
  return loading.get(id);
}

// Some grammars color embedded code only in languages that happen to be
// loaded (markdown's fenced code, Vue's <style lang>). So that a block
// comes out the same whenever it is highlighted, everything it could
// embed is loaded first: for markdown, the languages its fences name and
// YAML for front matter (a block starting with ---); for the others, every
// language they embed lazily.
const FENCE = /^[ \t]*(?:`{3,}|~{3,})[ \t]*([^\s`{]+)/gm;

function embedded(id, code) {
  const out = new Set();
  const names = id === 'markdown'
    ? [...code.matchAll(FENCE)].map(m => m[1]).concat(/^-{3,}/.test(code) ? ['yaml'] : [])
    : (lazyOf.get(id) || []);
  for (const name of names) {
    const d = resolveLang(name);
    if (d && d !== id) out.add(d);
  }
  return [...out];
}

function loaded(id) { return failed.has(id) || highlighter.getLoadedLanguages().includes(id); }

/** Loads what highlighting `code` as `id` needs; resolves when it is all registered. */
export async function prepare(id, code) {
  await init();
  await ensureLang(id);
  for (const d of embedded(id, code)) {
    await ensureLang(d);
    for (const dd of embedded(d, '')) await ensureLang(dd);
  }
}

/**
 * Returns highlighted inner HTML for a <pre>, or null until everything it
 * needs is loaded (then `prepare` and try again).
 */
export function highlightSync(code, id) {
  if (!initialized || !id || !loaded(id)) return null;
  for (const d of embedded(id, code)) {
    if (!loaded(d) || embedded(d, '').some(dd => !loaded(dd))) return null;
  }
  try {
    const html = highlighter.codeToHtml(code, {
      lang: id,
      themes: { light: 'github-light-default', dark: 'github-dark-default' },
      defaultColor: false,
      // github-light's comment grey is 4.2:1 on the code block fill; this is 4.9:1 (WCAG AA).
      colorReplacements: { 'github-light-default': { '#6e7781': '#636c76' } },
      // Shiki's per-line guard. The rendering-baseline tests raise it
      // (READOUT_TOKENIZE_LIMIT) so a starved CI machine cannot cut lines
      // short and make the same page render differently between runs.
      tokenizeTimeLimit: globalThis.READOUT_TOKENIZE_LIMIT ?? 500,
    });
    return html;
  } catch {
    return null;
  }
}
