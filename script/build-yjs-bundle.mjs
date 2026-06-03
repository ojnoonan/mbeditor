// build-yjs-bundle.mjs — MAINTAINER-ONLY build step.
//
// Produces the single prebuilt collaborative-editing bundle committed at
// vendor/assets/javascripts/yjs-collab.js. Consumers of the mbeditor gem run
// ZERO JS tooling: they `bundle install` and Sprockets serves the committed
// file as-is, exactly like the other vendored libs (lodash, react, …). Only a
// maintainer regenerating the bundle runs this script. This reaffirms ADR-0001
// (docs/adr/0001-no-frontend-build-step.md): no build step at the consumer.
//
// Rebuild step:
//
//     npm install            # installs yjs / y-monaco / y-protocols + esbuild
//     npm run build:yjs      # === node script/build-yjs-bundle.mjs
//
// then commit the regenerated vendor/assets/javascripts/yjs-collab.js.
//
// Global surface exposed to the page (bound against by the frontend collab
// slices), matching the upstream npm import names:
//
//     window.Y                 // * as Y from 'yjs'   (Doc, UndoManager, encode…)
//     window.MonacoBinding     // { MonacoBinding } from 'y-monaco'
//     window.awarenessProtocol // * as awarenessProtocol from 'y-protocols/awareness'
//
// Monaco itself is NOT bundled here — it is already served by the engine's
// Monaco loader as the runtime global `window.monaco`. y-monaco's references to
// `monaco-editor` are remapped (see monacoGlobalPlugin) to a thin lazy shim
// that forwards to `window.monaco` at call time, so this bundle stays small and
// shares the one Monaco instance on the page.

import esbuild from "esbuild";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUTFILE = join(ROOT, "vendor", "assets", "javascripts", "yjs-collab.js");

const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const version = (name) => pkg.dependencies[name];

// Entry stub: pull the three libraries in and publish the global contract.
const entry = `
import * as Y from "yjs";
import { MonacoBinding } from "y-monaco";
import * as awarenessProtocol from "y-protocols/awareness";

globalThis.Y = Y;
globalThis.MonacoBinding = MonacoBinding;
globalThis.awarenessProtocol = awarenessProtocol;
`;

// y-monaco needs only Range / Selection / SelectionDirection from monaco at
// runtime, and only inside its methods (never at module load). This shim
// exports each as a lazy proxy onto the page's `window.monaco`, so importing
// the bundle before Monaco has finished loading is safe; access only resolves
// when the binding is actually constructed/used. It is an ESM module, so
// y-monaco's CJS _interopNamespace short-circuits on __esModule and never
// eagerly enumerates these exports.
const monacoShim = `
const live = (member) => {
  const m = globalThis.monaco;
  if (!m) {
    throw new Error(
      "[mbeditor] window.monaco is not loaded yet — the Yjs/Monaco binding " +
      "requires Monaco to be available on the page first."
    );
  }
  return m[member];
};

const callableProxy = (member) =>
  new Proxy(function () {}, {
    construct: (_t, args) => Reflect.construct(live(member), args),
    apply: (_t, _thisArg, args) => live(member)(...args),
    get: (_t, prop) => live(member)[prop],
  });

const namespaceProxy = (member) =>
  new Proxy({}, { get: (_t, prop) => live(member)[prop] });

export const Range = callableProxy("Range");
export const Selection = callableProxy("Selection");
export const SelectionDirection = namespaceProxy("SelectionDirection");
export const editor = namespaceProxy("editor");
`;

const monacoGlobalPlugin = {
  name: "mbeditor-monaco-global",
  setup(build) {
    build.onResolve({ filter: /^monaco-editor(\/|$)/ }, () => ({
      path: "monaco-editor",
      namespace: "mbeditor-monaco-global",
    }));
    build.onLoad(
      { filter: /.*/, namespace: "mbeditor-monaco-global" },
      () => ({ contents: monacoShim, loader: "js", resolveDir: ROOT })
    );
  },
};

const banner = [
  "/*!",
  " * mbeditor collaborative-editing bundle — GENERATED, DO NOT EDIT BY HAND.",
  " * Rebuild: npm install && npm run build:yjs  (maintainer-only; consumers run zero JS tooling — ADR-0001).",
  ` * Bundled: yjs@${version("yjs")}, y-monaco@${version("y-monaco")}, y-protocols@${version("y-protocols")}.`,
  " * Exposes globals: window.Y, window.MonacoBinding, window.awarenessProtocol.",
  " * Monaco is NOT bundled; y-monaco binds to the page's runtime window.monaco.",
  " */",
].join("\n");

await esbuild.build({
  stdin: {
    contents: entry,
    resolveDir: ROOT,
    sourcefile: "mbeditor-yjs-entry.js",
    loader: "js",
  },
  bundle: true,
  format: "iife",
  minify: true,
  target: ["es2019"],
  legalComments: "none",
  banner: { js: banner },
  plugins: [monacoGlobalPlugin],
  outfile: OUTFILE,
});

console.log(`Wrote ${OUTFILE}`);
