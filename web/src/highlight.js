// Syntax highlighting with Shiki (JavaScript regex engine, no WASM).
// Grammars are loaded on demand; common ones are preloaded during warm-up.
import { createHighlighterCore } from 'shiki/core';
import { createJavaScriptRegexEngine } from 'shiki/engine/javascript';

const LANGS = {
  shellscript: () => import('@shikijs/langs/shellscript'),
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
  sh: 'shellscript', bash: 'shellscript', zsh: 'shellscript', shell: 'shellscript', console: 'shellscript',
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

export function init() {
  if (ready) return ready;
  ready = (async () => {
    highlighter = await createHighlighterCore({
      themes: [import('@shikijs/themes/github-light-default'), import('@shikijs/themes/github-dark-default')],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    });
    for (const id of PRELOAD) await ensureLang(id);
    initialized = true;
  })();
  return ready;
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
