// esbuild plugin: Shiki grammars with their patterns already converted to
// JavaScript regexes (used by build.mjs; checked by test/grammars.test.mjs).
//
// Converting a grammar's Oniguruma patterns to JavaScript is much of the cost
// of its first use; @shikijs/langs-precompiled ships them converted. But
// TextMate rewrites some patterns before every match, which it can only do to
// source text: \A and \G (anchored to where the last match ended), \z, and
// back-references from an end or while pattern to what its begin matched.
// Precompiled, those match differently (a shell command's arguments, a Python
// string's contents lose their colours), so they keep their source and Shiki
// converts them at runtime, as before. Every precompiled regex is compiled on
// its first match, as Shiki does with the ones it converts: WebKit parses a
// regex literal when its module loads, ~1 s for the JavaScript grammar alone.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

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

// The precompiled grammar, with the runtime grammar's source where TextMate needs it.
function mergeGrammar(rt, pc, key = '') {
  if (pc instanceof RegExp) {
    if (typeof rt !== 'string') throw new Error(`grammar shapes differ at ${key}`);
    return keepsSource(rt, key) ? rt : pc;
  }
  if (Array.isArray(pc)) return pc.map((v, i) => mergeGrammar(rt[i], v, key));
  if (pc && typeof pc === 'object') return Object.fromEntries(Object.keys(pc).map(k => [k, mergeGrammar(rt?.[k], pc[k], k)]));
  return pc;
}

function grammarSource(v) {
  if (v instanceof RegExp) {
    const { lazyCompile, ...options } = v.rawOptions || {};
    const args = [JSON.stringify(v.source)];
    if (Object.keys(options).length) args.push(JSON.stringify(v.flags), JSON.stringify(options));
    else if (v.flags !== 'dgv') args.push(JSON.stringify(v.flags));
    return `R(${args.join(',')})`;
  }
  if (Array.isArray(v)) return `[${v.map(grammarSource).join(',')}]`;
  if (v && typeof v === 'object') return `{${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}:${grammarSource(x)}`).join(',')}}`;
  return JSON.stringify(v);
}

const here = fileURLToPath(new URL('.', import.meta.url));

/** Serves every '@shikijs/langs/<id>' import as the merged grammar module. */
export const shikiGrammars = {
  name: 'shiki-grammars',
  setup(build) {
    build.onResolve({ filter: /^@shikijs\/langs\/[\w-]+$/ }, a => ({ path: a.path.split('/').pop(), namespace: 'shiki-grammar' }));
    build.onLoad({ filter: /.*/, namespace: 'shiki-grammar' }, async ({ path: id }) => {
      const rtFile = fileURLToPath(import.meta.resolve(`@shikijs/langs/${id}`));
      const [rt, pc] = [(await import(`@shikijs/langs/${id}`)).default, (await import(`@shikijs/langs-precompiled/${id}`)).default];
      // The grammars it embeds come first, in the order its module lists them.
      const text = readFileSync(rtFile, 'utf8');
      const files = Object.fromEntries([...text.matchAll(/^import (\w+) from '\.\/([\w-]+)\.mjs'/gm)].map(m => [m[1], m[2]]));
      const deps = [...text.matchAll(/^\.\.\.(\w+),?$/gm)].map(m => files[m[1]]);
      if (deps.some(d => !d) || rt.length !== pc.length) throw new Error(`unexpected module layout: @shikijs/langs/${id}`);
      const contents = [
        "import { EmulatedRegExp } from 'oniguruma-to-es';",
        ...deps.map((d, i) => `import d${i} from '@shikijs/langs/${d}';`),
        "const R = (s, f = 'dgv', o) => new EmulatedRegExp(s, f, { ...o, lazyCompile: true });",
        `const lang = Object.freeze(${grammarSource(mergeGrammar(rt.at(-1), pc.at(-1)))});`,
        `export default [${deps.map((_, i) => `...d${i},`).join('')}lang];`,
      ].join('\n');
      return { contents, resolveDir: here, loader: 'js' };
    });
  },
};
