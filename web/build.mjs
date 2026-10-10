// Bundles the reader into dist/ for the app and the Quick Look extension.
import * as esbuild from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';

const out = 'build/Web';
rmSync(out, { recursive: true, force: true });
mkdirSync(`${out}/vendor/katex`, { recursive: true });
mkdirSync(`${out}/vendor/mermaid`, { recursive: true });

await esbuild.build({
  entryPoints: ['src/reader.js'],
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
cpSync('node_modules/mermaid/dist/mermaid.min.js', `${out}/vendor/mermaid/mermaid.min.js`);
