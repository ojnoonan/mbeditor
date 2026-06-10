// Isolated build for Monaco only (ADR 0002).
//
// The rest of mbeditor keeps the "no frontend build step" rule from ADR 0001 —
// app code and the other vendored libraries are still edited and shipped
// directly. Monaco is the one exception: from 0.53 it deprecated the AMD build
// and broke custom AMD workers, so it must be consumed as ESM through a bundler.
//
// This script produces self-contained IIFE artifacts that are committed to
// public/monaco-editor/ and loaded with plain <script>/<link> tags — no bundler
// at runtime, no loader.js, no AMD. Re-run with `npm run build:monaco` whenever
// the monaco-editor / monaco-vim devDependencies are bumped.

import * as esbuild from 'esbuild';
import { rmSync, mkdirSync, readdirSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const outdir = resolve(root, 'public/monaco-editor');
const esm = resolve(root, 'node_modules/monaco-editor/esm/vs');

// Start from a clean output directory so stale AMD files can never linger.
rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });

const shared = {
  bundle: true,
  format: 'iife',
  minify: true,
  legalComments: 'none',
  logLevel: 'warning',
  // Monaco's CSS references the codicon font; emit it next to monaco.css so the
  // relative url() keeps resolving.
  loader: { '.ttf': 'file' },
  assetNames: '[name]',
};

// 1. Main editor bundle -> window.monaco (+ extracted monaco.css + codicon.ttf)
await esbuild.build({
  ...shared,
  entryPoints: [resolve(here, 'monaco.entry.js')],
  globalName: 'monaco',
  outfile: resolve(outdir, 'monaco.js'),
});

// 2. Web workers — each a standalone classic worker (loaded via new Worker()).
const workers = {
  'editor.worker': `${esm}/editor/editor.worker.js`,
  'json.worker': `${esm}/language/json/json.worker.js`,
  'css.worker': `${esm}/language/css/css.worker.js`,
  'html.worker': `${esm}/language/html/html.worker.js`,
  'ts.worker': `${esm}/language/typescript/ts.worker.js`,
};
for (const [name, entry] of Object.entries(workers)) {
  await esbuild.build({
    ...shared,
    entryPoints: [entry],
    outfile: resolve(outdir, `${name}.js`),
  });
}

// 3. monaco-vim — ship the prebuilt UMD as-is. Its ESM source imports Monaco
// internals (editor.api + an internal ShiftCommand), so rebuilding it from
// source would either fail to resolve those or, if we let it bundle Monaco,
// create a SECOND Monaco instance (breaking KeyCode/Range identity against the
// editor). The published UMD already inlines its private internals and reads
// the shared editor API from the `monaco` global — its browser branch is
// `factory((global.MonacoVim = {}), global.monaco)` — so it binds straight to
// the window.monaco set by bundle #1. Just copy it.
copyFileSync(
  resolve(root, 'node_modules/monaco-vim/dist/monaco-vim.umd.js'),
  resolve(outdir, 'monaco-vim.js'),
);

console.log('Built Monaco artifacts in public/monaco-editor/:');
for (const f of readdirSync(outdir).sort()) console.log('  ' + f);
