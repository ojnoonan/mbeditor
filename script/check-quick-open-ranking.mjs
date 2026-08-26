#!/usr/bin/env node
// Runnable check for quick-open matching and ranking.
//
//   node script/check-quick-open-ranking.mjs
//
// Loads the real vendored MiniSearch, the real search_service.js index config
// and the real QuickOpenDialog.rankResults in a vm context — no framework, no
// fixtures, no build step. Fails loudly if fuzzy matching stops finding a
// typo'd filename, if an exact match stops ranking first, or if folders climb
// back above files.

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

// --- Minimal browser-ish context -------------------------------------------
const ctx = { console, setTimeout, clearTimeout, Promise };
ctx.window = ctx;
ctx.globalThis = ctx;
ctx.module = { exports: {} };
ctx.exports = ctx.module.exports;
// QuickOpenDialog destructures these at load time; nothing here renders.
ctx.React = { useState() {}, useEffect() {}, useRef() {}, Fragment: {}, createElement() {} };
vm.createContext(ctx);

vm.runInContext(read('vendor/assets/javascripts/minisearch.min.js'), ctx);
ctx.MiniSearch = ctx.module.exports;
vm.runInContext(read('app/assets/javascripts/mbeditor/search_service.js'), ctx);
vm.runInContext(read('app/assets/javascripts/mbeditor/components/QuickOpenDialog.js'), ctx);

const { SearchService, QuickOpenDialog } = ctx;

// --- Fixture tree -----------------------------------------------------------
const dir = (name, p, children) => ({ type: 'folder', name, path: p, children });
const file = (name, p) => ({ type: 'file', name, path: p });

const tree = [
  dir('app', 'app', [
    dir('controllers', 'app/controllers', [
      file('projects_controller.rb', 'app/controllers/projects_controller.rb'),
      file('users_controller.rb', 'app/controllers/users_controller.rb')
    ]),
    dir('models', 'app/models', [
      file('user.rb', 'app/models/user.rb'),
      file('project.rb', 'app/models/project.rb')
    ]),
    dir('projects', 'app/views/projects', [
      file('index.html.erb', 'app/views/projects/index.html.erb')
    ])
  ]),
  file('README.md', 'README.md')
];

SearchService.buildIndex(tree);

const rank = (q, showFolders) =>
  QuickOpenDialog.rankResults(SearchService.searchFiles(q), q, !!showFolders);

// buildIndex defers to requestIdleCallback / setTimeout(50).
await new Promise((r) => setTimeout(r, 200));

let checks = 0;
function check(label, fn) {
  fn();
  checks++;
  console.log('  ok  ' + label);
}

check('typo\'d query still finds the file (fuzzy)', () => {
  const paths = rank('projcts_controler').map((r) => r.path);
  assert.ok(
    paths.includes('app/controllers/projects_controller.rb'),
    'expected projects_controller.rb for "projcts_controler", got ' + JSON.stringify(paths)
  );
});

check('transposed characters still match', () => {
  const paths = rank('conrtoller').map((r) => r.path);
  assert.ok(paths.length > 0, 'expected fuzzy hits for "conrtoller"');
});

check('a 3-char query is not fuzzed into noise', () => {
  // fuzzy is off below 4 chars; "usr" must not drag in every short token.
  const paths = rank('usr').map((r) => r.path);
  assert.equal(paths.length, 0, 'expected no hits for "usr", got ' + JSON.stringify(paths));
});

check('exact basename still ranks first', () => {
  const paths = rank('user.rb').map((r) => r.path);
  assert.equal(paths[0], 'app/models/user.rb', 'got ' + JSON.stringify(paths));
});

check('exact match outranks a fuzzy near-miss', () => {
  const paths = rank('project.rb').map((r) => r.path);
  assert.equal(paths[0], 'app/models/project.rb', 'got ' + JSON.stringify(paths));
});

check('folders sort after every file', () => {
  const results = rank('projects', true);
  const dirs = results.filter((r) => r.type === 'dir');
  assert.ok(dirs.length > 0, 'fixture should produce at least one folder hit');
  const firstDir = results.findIndex((r) => r.type === 'dir');
  const lastFile = results.map((r) => r.type).lastIndexOf('file');
  assert.ok(
    lastFile < firstDir,
    'folders must follow files, got ' + JSON.stringify(results.map((r) => r.type + ':' + r.path))
  );
});

check('folders are dropped entirely when showFolders is off', () => {
  assert.ok(rank('projects', false).every((r) => r.type !== 'dir'));
});

console.log('\n' + checks + ' checks passed.');
