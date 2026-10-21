// esbuild plugin: Shiki grammars with their patterns already converted to
// JavaScript regexes (used by build.mjs; checked by test/grammars.test.mjs).
//
// Converting a grammar's Oniguruma patterns to JavaScript is much of the cost
// of its first use, so the build converts them, with the options Shiki's
// JavaScript engine uses, for ES2018 (the u flag; the engine in highlight.js
// converts the rest for ES2018 too): WebKit compiles regexes with the v flag
// 200-500x slower, TypeScript's whole grammar ~6 s against ~0.9 s. But
// TextMate rewrites some patterns before every match, which it can only do to
// source text: \A and \G (anchored to where the last match ended), \z, and
// back-references from an end or while pattern to what its begin matched.
// Converted, those match differently (a shell command's arguments, a Python
// string's contents lose their colours), so they keep their source and Shiki
// converts them at runtime, as before. Every converted regex is compiled on
// its first match, as Shiki does with the ones it converts: WebKit parses a
// regex literal when its module loads, ~1 s for the JavaScript grammar alone.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { toRegExpDetails } from 'oniguruma-to-es';

/** True when vscode-textmate rewrites the pattern (see above): it keeps its source. */
export function keepsSource(src, key) {
  for (let i = 0; i < src.length; i++) {
    if (src[i] === '\\' && i + 1 < src.length) {
      if ('AGz'.includes(src[i + 1])) return true;
      i++;
    }
  }
  return (key === 'end' || key === 'while') && /\\(\d+)/.test(src);
}

// Shiki's createJavaScriptRegexEngine options (lazyCompile is set in R below).
const CONVERT = { global: true, hasIndices: true, target: 'ES2018',
  rules: { allowOrphanBackrefs: true, asciiWordBoundaries: true, captureGroup: true, recursionLimit: 5, singleline: true } };

class Converted { constructor(d) { this.d = d; } }

// The grammar with its patterns converted, except where TextMate needs the
// source or the pattern cannot be converted (Shiki skips those, forgiving).
function convertGrammar(v, key = '') {
  if (typeof v === 'string') {
    if (!/^(match|begin|end|while)$/.test(key) || keepsSource(v, key)) return v;
    try { return new Converted(toRegExpDetails(v, CONVERT)); } catch { return v; }
  }
  if (Array.isArray(v)) return v.map(x => convertGrammar(x, key));
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).map(k => [k, convertGrammar(v[k], k)]));
  return v;
}

function grammarSource(v) {
  if (v instanceof Converted) {
    const { pattern, flags, options } = v.d;
    const args = [JSON.stringify(pattern)];
    if (options) args.push(JSON.stringify(flags), JSON.stringify(options));
    else if (flags !== 'dgu') args.push(JSON.stringify(flags));
    return `R(${args.join(',')})`;
  }
  if (Array.isArray(v)) return `[${v.map(grammarSource).join(',')}]`;
  if (v && typeof v === 'object') return `{${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}:${grammarSource(x)}`).join(',')}}`;
  return JSON.stringify(v);
}

const here = fileURLToPath(new URL('.', import.meta.url));

/** Serves every '@shikijs/langs/<id>' import as the converted grammar module. */
export const shikiGrammars = {
  name: 'shiki-grammars',
  setup(build) {
    build.onResolve({ filter: /^@shikijs\/langs\/[\w-]+$/ }, a => ({ path: a.path.split('/').pop(), namespace: 'shiki-grammar' }));
    build.onLoad({ filter: /.*/, namespace: 'shiki-grammar' }, async ({ path: id }) => {
      const rtFile = fileURLToPath(import.meta.resolve(`@shikijs/langs/${id}`));
      const rt = (await import(`@shikijs/langs/${id}`)).default;
      // The grammars it embeds come first, in the order its module lists them.
      const text = readFileSync(rtFile, 'utf8');
      const files = Object.fromEntries([...text.matchAll(/^import (\w+) from '\.\/([\w-]+)\.mjs'/gm)].map(m => [m[1], m[2]]));
      const deps = [...text.matchAll(/^\.\.\.(\w+),?$/gm)].map(m => files[m[1]]);
      if (deps.some(d => !d)) throw new Error(`unexpected module layout: @shikijs/langs/${id}`);
      const contents = [
        "import { EmulatedRegExp } from 'oniguruma-to-es';",
        ...deps.map((d, i) => `import d${i} from '@shikijs/langs/${d}';`),
        "const R = (s, f = 'dgu', o) => new EmulatedRegExp(s, f, { ...o, lazyCompile: true });",
        `const lang = Object.freeze(${grammarSource(convertGrammar(rt.at(-1)))});`,
        `export default [${deps.map((_, i) => `...d${i},`).join('')}lang];`,
      ].join('\n');
      return { contents, resolveDir: here, loader: 'js' };
    });
  },
};
