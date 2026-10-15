// Bundles the reader into dist/ for the app and the Quick Look extension.
import * as esbuild from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';
import { shikiGrammars } from './shiki-grammars.mjs';

const out = 'build/Web';
rmSync(out, { recursive: true, force: true });
mkdirSync(`${out}/vendor/katex`, { recursive: true });
mkdirSync(`${out}/vendor/mermaid`, { recursive: true });

await esbuild.build({
  entryPoints: ['src/reader.js'],
  plugins: [shikiGrammars],
  bundle: true,
  splitting: true,
  format: 'esm',
  target: 'safari18',
  minify: true,
  outdir: out,
  chunkNames: 'chunks/[name]-[hash]',
  legalComments: 'none',
  logLevel: 'info',
});

await esbuild.build({
  entryPoints: ['src/reader.css'],
  bundle: true,
  minify: true,
  outfile: `${out}/reader.css`,
  logLevel: 'info',
});

cpSync('src/reader.html', `${out}/reader.html`);
cpSync('node_modules/katex/dist/katex.min.js', `${out}/vendor/katex/katex.min.js`);
cpSync('node_modules/katex/dist/katex.min.css', `${out}/vendor/katex/katex.min.css`);
cpSync('node_modules/katex/dist/fonts', `${out}/vendor/katex/fonts`, { recursive: true });
// Mermaid's ESM build: a small entry, shared chunks and one chunk per kind of
// diagram, each loaded when first needed (the classic mermaid.min.js is all
// 5.5 MB at once). Everything ships in the app; the source maps do not.
cpSync('node_modules/mermaid/dist/mermaid.esm.min.mjs', `${out}/vendor/mermaid/mermaid.esm.min.mjs`);
cpSync('node_modules/mermaid/dist/chunks/mermaid.esm.min', `${out}/vendor/mermaid/chunks/mermaid.esm.min`,
  { recursive: true, filter: src => !src.endsWith('.map') });
