// Syntax highlighting with Shiki (JavaScript regex engine, no WASM).
// Grammars are loaded on demand; the three agent output uses most are
// preloaded (not in Quick Look, which loads only what the preview shows), the
// spare page loads nine more, and the languages a document's fences name are
// loaded while it parses (prepareLangs). Shiki itself is loaded on first use.
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

// Each preloaded grammar costs a tab its memory (12 of them: ~36 MB of a
// warmed page's private memory); the rest load on first use, which ES2018
// patterns keep to tens or hundreds of milliseconds, or while the document
// naming them parses (prepareLangs). Every page loads the three agent output
// uses most. The spare page (warm), which a window opens on, also loads the
// rest of 3.8.0's twelve, so their blocks are coloured in a warm
// open's first paint as in 3.8 (its memory about 3.8's by design); pages
// not warmed (the first window at launch, background tabs) keep 3.9's three.
const PRELOAD = ['shellscript', 'json', 'typescript'];
const SPARE_PRELOAD = ['javascript', 'python', 'swift', 'go', 'rust', 'yaml', 'diff', 'markdown', 'sql'];

let highlighter = null;
let hastToHtml = null;
let ready = null;
let preload = true;        // Quick Look turns it off: it loads only the grammars a preview needs
let initialized = false;   // the preloaded grammars are all registered
const loading = new Map();
const failed = new Set();  // grammars that could not be loaded (never waited for again)
const lazyOf = new Map();  // grammar id -> languages it embeds only when they are loaded
const grammarsOf = new Map();  // grammar id -> its grammar modules (for the warm-up)

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
    const [{ createHighlighterCore, hastToHtml: toHtml }, { createJavaScriptRegexEngine }] =
      await Promise.all([import('shiki/core'), import('shiki/engine/javascript')]);
    hastToHtml = toHtml;
    highlighter = await createHighlighterCore({
      themes: [
        quietOutput(import('@shikijs/themes/github-light-default'), '#5f5f66'),
        quietOutput(import('@shikijs/themes/github-dark-default'), '#a8a8ae'),
      ],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true, target: 'ES2018' }),
    });
    // Fetch every preloaded grammar at once; ensureLang registers them one
    // at a time, in this order.
    if (preload) await Promise.all(PRELOAD.map(id => ensureLang(id)));
    initialized = true;
  })();
  return ready;
}

// Loading a grammar does not compile its patterns: the first block it
// highlights does, which cost the first code block of a warm open 170-220 ms
// inside the page's first apply (TypeScript's patterns alone take WebKit
// hundreds of milliseconds). So grammars are loaded and compiled ahead of
// need through one queue of jobs, run in slices of a few milliseconds, one
// per task (a window taking the page waits for one slice at most):
// - spare jobs: the app's spare page (warm) loads its grammars one at a
//   time, then, once it has sat unused for a while (a spare page usually
//   waits minutes for its window), compiles each grammar's patterns and runs
//   a few lines of its language through it. Marks 'readout-hl-warm' when
//   all are done, with its time, longest slice and grammars (perf.test.mjs).
// - requested jobs: the languages a document being opened names
//   (prepareLangs), loaded and compiled at the front of the queue.
// The page showing a document (stopWarmUp, enhance.js) drops the spare jobs
// (a page being read should not spend its main thread on languages it may
// not show) and keeps the requested ones. Never spare jobs in Quick Look,
// which preloads nothing.
let warming = false;
let shown = false;           // the page shows a document
const jobs = [];             // { id, requested, steps } in order; steps: an iterator, made when the job starts
let working = false;
let longestSlice = 0;        // the longest a window taking the page could wait (perf.test.mjs)

export function warm() {
  return init().then(() => {
    if (!preload || warming || shown) return;
    warming = true;
    let start;
    // Each grammar loaded, one at a time; then the idle delay; then each compiled; then done.
    for (const id of SPARE_PRELOAD) jobs.push({ id, steps: loadSteps(id, true) });
    jobs.push({ steps: (function* () { yield new Promise(r => setTimeout(r, WARM_DELAY_MS)); start = performance.now(); })() });
    for (const id of WARM_ORDER) jobs.push({ id, steps: null });
    // The whole path once, as a block is highlighted (both themes, HTML);
    // marked done after its slice is counted.
    jobs.push({ steps: (function* () { highlightSync('x', 'json'); })(), after: () => {
      const grammars = WARM_ORDER.filter(id => !failed.has(id));
      performance.mark('readout-hl-warm', { detail: { ms: performance.now() - start, longestSlice, grammars } });
    } });
    runJobs();
  });
}

/** The page shows a document: its spare jobs are dropped, requested ones go on. */
export function stopWarmUp() {
  shown = true;
  for (let i = jobs.length - 1; i >= 0; i--) if (!jobs[i].requested) jobs.splice(i, 1);
}

/**
 * The app has read a document and is parsing it: the grammars its code
 * fences name (info strings, as written) are loaded and compiled now, at the
 * front of the queue (a job for one already queued moves there), so its
 * first paint finds them ready.
 */
export function prepareLangs(names) {
  if (shown || !Array.isArray(names)) return;
  // A Markdown block may start with front matter, which is YAML (embedded):
  // what such a block needs is not known before its code is.
  const ids = names.slice(0, 16).map(n => resolveLang(String(n))).filter(Boolean);
  if (ids.includes('markdown')) ids.push('yaml');
  const front = [];
  for (const id of new Set(ids)) {
    needed.add(id);
    if (jobs.some(j => j.id === id && j.requested)) continue;
    for (let i = jobs.length - 1; i >= 0; i--) if (jobs[i].id === id) jobs.splice(i, 1);
    front.push({ id, requested: true, steps: null });
  }
  jobs.unshift(...front);
  init().then(runJobs);   // a page not set up yet: once the highlighter is
}

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
  python: [
    'from dataclasses import dataclass',
    '',
    '@dataclass',
    'class Item(Base):',
    '    """A docstring."""',
    '    def load(self, path: str = "x", *args, **kw) -> list[int]:',
    '        with open(path) as f:  # comment',
    '            return [int(x) for x in f if x.strip() and not x.startswith("#")]',
    '',
    'async def main() -> None:',
    '    try:',
    '        await run(f"{path!r} {1 + 2:.2f}", r"\\d+", b"x")',
    '    except (OSError, ValueError) as e:',
    '        raise SystemExit(1) from e',
    '    finally:',
    '        print(lambda x: x ** 2, None, True)',
  ].join('\n'),
  rust: [
    'use std::collections::HashMap;',
    '',
    '/// A doc comment.',
    '#[derive(Debug, Clone)]',
    "pub struct Store<'a, T: Clone> {",
    '    items: HashMap<String, T>,',
    "    path: &'a str,",
    '}',
    '',
    "impl<'a, T: Clone> Store<'a, T> {",
    '    pub async fn load(&mut self) -> Result<usize, Box<dyn std::error::Error>> {',
    '        for (i, line) in self.path.lines().enumerate() {',
    '            if line.is_empty() { continue; }',
    '            let key = format!("{i}:{}", line.trim());',
    '            match self.items.get(&key) { Some(_) => {}, None => return Err("x".into()) }',
    '        }',
    '        Ok(self.items.len()) // comment',
    '    }',
    '}',
  ].join('\n'),
  yaml: [
    '# comment',
    'name: "value"',
    'on:',
    '  push:',
    '    branches: [main]',
    'jobs:',
    '  test:',
    '    runs-on: ubuntu-latest',
    '    steps:',
    '      - uses: actions/checkout@v4',
    '      - run: |',
    '          npm ci',
    '        env: { CI: true, N: 1.5 }',
  ].join('\n'),
  diff: 'diff --git a/x.js b/x.js\nindex 1111111..2222222 100644\n--- a/x.js\n+++ b/x.js\n@@ -1,3 +1,3 @@ function f\n-const a = 1;\n+const a = 2;\n context',
  javascript: TS_SAMPLE,
  swift: [
    'import Foundation',
    '',
    '/// A doc comment.',
    '@MainActor final class Store<T: Codable>: ObservableObject {',
    '    @Published private(set) var items: [String: T] = [:]',
    '    init(path: URL, strict: Bool = false) throws { self.path = path }',
    '    func load() async throws -> Int {',
    '        guard let data = try? Data(contentsOf: path) else { return 0 }',
    '        for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\\n").enumerated() where !line.isEmpty {',
    '            items["\\(i)"] = try JSONDecoder().decode(T.self, from: Data(line.utf8))',
    '        }',
    '        return items.count  // comment',
    '    }',
    '}',
    'enum Mode { case on, off }',
    'let total = [1, 2].map { $0 * 2 }.reduce(0, +) * 1.5',
  ].join('\n'),
  go: [
    'package main',
    '',
    'import (',
    '\t"context"',
    '\t"fmt"',
    ')',
    '',
    '// Store is a store.',
    'type Store[T any] struct {',
    '\tItems map[string]T `json:"items"`',
    '}',
    '',
    'func (s *Store[T]) Load(ctx context.Context, path string) (int, error) {',
    '\tfor i, line := range strings.Split(path, "\\n") {',
    '\t\tif line == "" {',
    '\t\t\tcontinue',
    '\t\t}',
    '\t\ts.Items[fmt.Sprintf("%d", i)] = *new(T)',
    '\t}',
    '\tgo func() { defer close(ch); ch <- 1 }()',
    '\treturn len(s.Items), nil',
    '}',
  ].join('\n'),
  markdown: [
    '# Title',
    '',
    'Some *text*, **bold** and `code`, a [link](https://example.com "t") and ![image](a.png).',
    '',
    '> A quote',
    '',
    '1. One',
    '- [ ] Task',
    '',
    '| a | b |',
    '| - | - |',
    '| 1 | 2 |',
  ].join('\n'),
  sql: [
    "WITH t AS (SELECT id, name FROM users WHERE created_at > NOW() - INTERVAL '7 days')",
    'SELECT a.id, COUNT(*) AS n, SUM(b.x) / 1.5 FROM t a',
    'LEFT JOIN orders b ON b.user_id = a.id',
    "WHERE a.name LIKE '%x%' AND b.status IN ('open', 'done')",
    'GROUP BY a.id HAVING COUNT(*) > 1 ORDER BY n DESC LIMIT 10; -- comment',
    'CREATE TABLE IF NOT EXISTS x (id INTEGER PRIMARY KEY, v TEXT NOT NULL);',
    "INSERT INTO x VALUES (1, 'a');",
  ].join('\n'),
};
// Any other language a document names: a few lines most grammars have rules for.
const GENERIC_SAMPLE = 'import x from "y"; // comment\n# comment\n/* comment */ if (a == 1.5) { return [true, null, \'s\', `t`]; }\nfunc(a, b) -> c:';
const WARM_DELAY_MS = 5000;
const WARM_ORDER = ['typescript', 'shellscript', 'python', 'json', 'javascript', 'go', 'swift', 'rust', 'yaml', 'markdown', 'sql', 'diff'];   // 3.8's order
// A job's steps, one per next(): a promise yielded is waited for (the slice
// ends there). Loading: the grammar's import and registration.
function* loadSteps(id, spare) {
  if (!loaded(id)) yield ensureLang(id, spare);
}
// Then compiling, sliced and measured like the rest (the walk too): each of
// its regexes (as the build precompiled them; WebKit compiles each on its
// first use, which is what makes a grammar's first block slow) run once,
// then its sample (or a generic one) a line per step, carrying the
// grammar's state, so the rules it reaches are set up as they are for a block.
function* grammarSteps(id, spare) {
  yield* loadSteps(id, spare);
  if (failed.has(id) || !highlighter.getLoadedLanguages().includes(id)) return;
  const seen = new Set(), stack = [grammarsOf.get(id)];
  while (stack.length) {
    const v = stack.pop();
    if (v instanceof RegExp) {
      try { v.lastIndex = 0; v.exec(''); } catch { /* not ours to fix */ }
      yield;
      continue;
    }
    if (!v || typeof v !== 'object' || seen.has(v)) continue;
    seen.add(v);
    for (const k in v) stack.push(v[k]);
  }
  let state;
  for (const line of (SAMPLES[id] || GENERIC_SAMPLE).split('\n')) {
    try {
      const tokens = highlighter.codeToTokensBase(line, { lang: id, theme: 'github-light-default', ...(state ? { grammarState: state } : {}) });
      state = highlighter.getLastGrammarState(tokens);
    } catch { state = undefined; }
    yield;
  }
}

const SLICE_MS = 8;
function runJobs() {
  if (working) return;
  working = true;
  const next = () => {
    const t0 = performance.now(), after = [];
    // The first job runs until it waits (a load, the idle delay): requested
    // jobs, put in front of it, go meanwhile; the jobs behind it wait.
    while (jobs.length && !jobs[0].waiting && performance.now() - t0 < SLICE_MS) {
      const job = jobs[0];
      job.steps ||= grammarSteps(job.id, !job.requested);
      const r = job.steps.next();
      if (r.done) {
        jobs.splice(jobs.indexOf(job), 1);
        if (job.after) after.push(job.after);
        if (job.requested) performance.mark('readout-hl-prepared');   // for the tests
      } else if (r.value instanceof Promise) {
        job.waiting = r.value.then(() => { job.waiting = null; runJobs(); });
      }
    }
    longestSlice = Math.max(longestSlice, performance.now() - t0);
    for (const f of after) f();
    if (jobs.length && !jobs[0].waiting) setTimeout(next, 0);
    else working = false;
  };
  next();
}

// Grammars are registered one at a time, in request order. Several modules
// carry their own copies of embedded grammars (markdown embeds shell, for
// one), so concurrent loads registered them in whatever order the imports
// resolved and the same block could highlight differently between loads.
let registry = Promise.resolve();

const needed = new Set();   // grammars a page asked for, not only the spare's warm-up

/** `spare`: for the spare page's warm-up only, which a window taking the page stops. */
export function ensureLang(id, spare = false) {
  if (!spare) needed.add(id);
  if (!highlighter) return init().then(() => ensureLang(id, spare));
  if (highlighter.getLoadedLanguages().includes(id)) return Promise.resolve();
  if (!loading.has(id)) {
    const load = LANGS[id]();   // fetch in parallel, register in order
    const done = registry.then(() => load).then(m => {
      // The page was taken meanwhile and nothing it shows asked for it: not registered.
      if (shown && !needed.has(id)) { loading.delete(id); return; }
      const main = m.default.find(g => g.name === id) || m.default[m.default.length - 1];
      lazyOf.set(id, main?.embeddedLangsLazy || []);
      grammarsOf.set(id, m.default);
      return highlighter.loadLanguage(m.default);
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
 * A token in the block's own colours (both themes') is its text alone: it
 * shows the same, inheriting them from the <pre>, and is an element fewer.
 * A highlighted block keeps its spans, and a theme switch restyles every
 * one of them, wherever it is in the page.
 */
export function plainTokens(html) {
  const m = /^<pre\b[^>]*\bstyle="([^"]*)"/.exec(html);
  const light = m && /--shiki-light:(#[0-9a-fA-F]+)/.exec(m[1])?.[1];
  const dark = m && /--shiki-dark:(#[0-9a-fA-F]+)/.exec(m[1])?.[1];
  if (!light || !dark) return html;
  return html.replace(new RegExp(`<span style="--shiki-light:${light};--shiki-dark:${dark}">([^<]*)</span>`, 'gi'), '$1');
}

/**
 * Returns highlighted inner HTML for a <pre>, or null until everything it
 * needs is loaded (then `prepare` and try again).
 */
export function highlightSync(code, id) {
  return highlightPart(code, id)?.html ?? null;
}

/** Whether `code` can be highlighted now: its grammar and those of the code embedded in it loaded. */
export function canHighlight(code, id) {
  if (!initialized || !id || !loaded(id)) return false;
  return embedded(id, code).every(d => loaded(d) && embedded(d, '').every(dd => loaded(dd)));
}

/**
 * Like highlightSync, for code that goes on from `state` (what highlighting
 * the lines before it left): its HTML and the state it leaves, so a long
 * block can be highlighted a part at a time (enhance.js), each part a short
 * task. null until everything it needs is loaded.
 */
export function highlightPart(code, id, state) {
  if (!initialized || !id || !loaded(id)) return null;
  for (const d of embedded(id, code)) {
    if (!loaded(d) || embedded(d, '').some(dd => !loaded(dd))) return null;
  }
  try {
    const hast = highlighter.codeToHast(code, {
      lang: id,
      ...(state ? { grammarState: state } : {}),
      themes: { light: 'github-light-default', dark: 'github-dark-default' },
      defaultColor: false,
      // github-light's comment grey is 4.2:1 on the code block fill; this is 4.9:1 (WCAG AA).
      colorReplacements: { 'github-light-default': { '#6e7781': '#636c76' } },
      // Shiki's per-line guard. The rendering-baseline tests raise it
      // (READOUT_TOKENIZE_LIMIT) so a starved CI machine cannot cut lines
      // short and make the same page render differently between runs.
      tokenizeTimeLimit: globalThis.READOUT_TOKENIZE_LIMIT ?? 500,
    });
    const html = hastToHtml(hast);
    // (The typography tests compare it with every token in its span: READOUT_TOKEN_SPANS.)
    return { html: globalThis.READOUT_TOKEN_SPANS ? html : plainTokens(html), state: highlighter.getLastGrammarState(hast) };
  } catch {
    return null;
  }
}
