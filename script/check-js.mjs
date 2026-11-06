// check-js.mjs — MAINTAINER-ONLY static check for the app JS.
//
// Consumers run no JS tooling (ADR-0001); this is a maintainer/CI check, like
// build-yjs-bundle.mjs:
//
//     npm install
//     npm run lint:js        # === node script/check-js.mjs
//
// What it checks, and why it needs a bundle:
//
// Sprockets concatenates every file listed in
// app/assets/javascripts/mbeditor/application.js into one script, wrapped in
// an IIFE that opens in application_iife_head.js and closes in
// application_iife_tail.js. Neither half parses on its own, and a file's
// top-level declarations are function-scoped inside that IIFE, not global. So
// the files are concatenated in manifest order — the same text the browser
// runs — and the TypeScript compiler (JS mode, no types) checks that bundle
// for:
//
//   - syntax errors                      (TS1xxx)
//   - declarations never read            (TS6133, 6196, 6198, 6199)
//   - unreachable code                   (TS7027)
//
// Type errors are ignored: there are no React/Monaco typings, so they are
// noise. A parameter that must stay for position — `function (m, i)` where
// only `i` is read — is exempt when named with a leading underscore (`_m`).
//
// It also fails on any .js file under app/assets/javascripts/mbeditor that
// the manifest does not load: such a file never reaches the browser.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const JS_ROOT = path.join(ROOT, "app/assets/javascripts");
const MANIFEST = path.join(JS_ROOT, "mbeditor/application.js");

const REPORTED = new Set([6133, 6196, 6198, 6199, 7027]);
const isSyntax = (code) => code >= 1000 && code < 2000;

const rel = (p) => path.relative(ROOT, p);

// ── Build the bundle, remembering which lines came from which file ──────────
const required = [...fs.readFileSync(MANIFEST, "utf8").matchAll(/^\/\/= require (\S+)/gm)]
  .map((m) => path.join(JS_ROOT, `${m[1]}.js`));

const segments = []; // { start, end, file } — 1-based, inclusive bundle lines
let text = "";
let line = 1;
for (const file of required) {
  let src = fs.readFileSync(file, "utf8");
  if (!src.endsWith("\n")) src += "\n";
  const lines = src.split("\n").length - 1;
  segments.push({ start: line, end: line + lines - 1, file });
  text += src;
  line += lines;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mbeditor-check-js-"));
const bundle = path.join(tmp, "bundle.js");
fs.writeFileSync(bundle, text);

// ── Compile ─────────────────────────────────────────────────────────────────
const program = ts.createProgram([bundle], {
  allowJs: true,
  checkJs: true,
  noEmit: true,
  target: ts.ScriptTarget.ES2020,
  lib: ["lib.es2020.d.ts", "lib.dom.d.ts", "lib.dom.iterable.d.ts"],
  types: [],
  skipLibCheck: true,
  noUnusedLocals: true,
  noUnusedParameters: true,
  allowUnreachableCode: false,
});

const problems = [];
for (const d of ts.getPreEmitDiagnostics(program)) {
  if (!d.file || path.resolve(d.file.fileName) !== bundle) continue;
  if (!REPORTED.has(d.code) && !isSyntax(d.code)) continue;
  const { line: l0, character } = d.file.getLineAndCharacterOfPosition(d.start);
  const bundleLine = l0 + 1;
  const seg = segments.find((s) => bundleLine >= s.start && bundleLine <= s.end);
  const where = seg ? `${rel(seg.file)}:${bundleLine - seg.start + 1}:${character + 1}` : `bundle:${bundleLine}`;
  problems.push(`${where}  TS${d.code}  ${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`);
}

// ── Files the manifest never loads ──────────────────────────────────────────
const loaded = new Set([MANIFEST, ...required].map((f) => path.resolve(f)));
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const p = path.join(dir, e.name);
  return e.isDirectory() ? walk(p) : (e.name.endsWith(".js") ? [p] : []);
});
for (const f of walk(path.join(JS_ROOT, "mbeditor"))) {
  if (!loaded.has(path.resolve(f))) problems.push(`${rel(f)}  not loaded by ${rel(MANIFEST)}`);
}

fs.rmSync(tmp, { recursive: true, force: true });

if (problems.length) {
  console.error(problems.join("\n"));
  console.error(`\n${problems.length} problem(s) in ${required.length} files.`);
  process.exit(1);
}
console.log(`check-js: ${required.length} files, no problems.`);
