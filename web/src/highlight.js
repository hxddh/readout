// Syntax highlighting with Shiki (JavaScript regex engine, no WASM).
// Grammars are loaded on demand; common ones are preloaded during warm-up
// (not in Quick Look, which loads only what the preview shows). Shiki itself
// is loaded on first use.
//
// The grammars come mostly precompiled: the build (shiki-grammars.mjs) serves
// each '@shikijs/langs/<id>' import with its patterns already converted to
// JavaScript regexes, except the few TextMate rewrites before matching, which
// stay Oniguruma source and are converted here, as before. The highlighting
// is the same (test/grammars.test.mjs); a grammar's first use is faster.

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

const PRELOAD = ['shellscript', 'json', 'typescript', 'javascript', 'python', 'swift', 'go', 'rust', 'yaml', 'diff', 'markdown', 'sql'];

let highlighter = null;
let ready = null;
let preload = true;        // Quick Look turns it off: it loads only the grammars a preview needs
let initialized = false;   // the preloaded grammars are all registered
const loading = new Map();
const failed = new Set();  // grammars that could not be loaded (never waited for again)
const lazyOf = new Map();  // grammar id -> languages it embeds only when they are loaded

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
    const [{ createHighlighterCore }, { createJavaScriptRegexEngine }] =
      await Promise.all([import('shiki/core'), import('shiki/engine/javascript')]);
    highlighter = await createHighlighterCore({
      themes: [
        quietOutput(import('@shikijs/themes/github-light-default'), '#5f5f66'),
        quietOutput(import('@shikijs/themes/github-dark-default'), '#a8a8ae'),
      ],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
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
// inside the page's first apply. So the app's spare page (warm) also, once
// the preloaded grammars are in, highlights a few lines of the common
// constructs of each language, the way a block is highlighted: right away,
// most used (and costliest) first, one language per task, so that it is
// done before a window takes the page, and a document arriving meanwhile
// waits for one language at most. Only there: compiling a large grammar (TypeScript's) takes a
// moment of the main thread, which a page being read should not pay for a
// language it may not show. Never in Quick Look, which preloads nothing.
// It stops as soon as the page shows a document (stopWarmUp, enhance.js):
// a spare page taken for a window before it is done leaves the rest to the
// blocks that need it. Marks 'readout-hl-warm' when done (perf.test.mjs).
let warming = false;
let warmStopped = false;
export function warm() {
  return init().then(() => {
    if (!preload || warming || warmStopped) return;
    warming = true;
    warmUp();
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
  javascript: TS_SAMPLE,
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
const WARM_ORDER = ['typescript', 'shellscript', 'python', 'json', 'javascript', 'go', 'swift', 'rust', 'yaml', 'markdown', 'sql', 'diff'];
function warmUp() {
  const ids = WARM_ORDER.filter(id => SAMPLES[id] && highlighter.getLoadedLanguages().includes(id));
  const next = () => {
    if (warmStopped) return;
    const id = ids.shift();
    if (!id) { performance.mark('readout-hl-warm'); return; }
    highlightSync(SAMPLES[id], id);   // only a head start: its result, or failure, is not used
    setTimeout(next, 0);
  };
  setTimeout(next, 0);
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
// embed is loaded first: for markdown, the languages its fences name; for
// the others, every language they embed lazily.
const FENCE = /^[ \t]*(?:`{3,}|~{3,})[ \t]*([^\s`{]+)/gm;

function embedded(id, code) {
  const out = new Set();
  const names = id === 'markdown' ? [...code.matchAll(FENCE)].map(m => m[1]) : (lazyOf.get(id) || []);
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
