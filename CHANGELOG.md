# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.1] - 2026-07-27

### Removed
- **The `listen`-based file watcher, and with it `config.watch_files`.**
  0.10.0 enabled a workspace watcher by default. On Linux each watched
  directory costs an inotify watch from `fs.inotify.max_user_watches`, a
  *per-user* budget shared with everything else watching files — including the
  host app's own code reloader and any other gem using `listen`. Exhausting it
  raises `iNotify max watches exceeded`, and because `listen` reports some of
  those failures from its own background thread, mbeditor could not even
  rescue them. Claiming a share of a scarce OS resource by default was the
  wrong trade for a development tool, and raising the limit needs root, which
  a developer may not have.

  Nothing is lost: external changes are picked up by polling, which is how the
  editor already tracked git state. If you set `config.watch_files`, remove it
  — it is now ignored.

### Fixed
- **The file tree never refreshed for changes made outside the editor.** Its
  10-second poll returned early whenever the Action Cable socket was connected,
  on the reasoning that the push covered it — but the server only broadcasts
  from mbeditor's own mutation endpoints. With a socket connected, which is the
  normal case, an external `git checkout` or generator run was never picked up.
  The poll now always runs; the push remains the instant path for our own
  writes. This is the bug the 0.10.0 watcher was compensating for.
- **Git line-number tinting went stale for external changes**, for the same
  reason, and its refresh timer was being cleared and recreated on every
  re-render so it never survived long enough to fire. It now polls on its own
  timer and on window focus, matching the file tree.
- **Watched paths were dropped when the workspace was reached through a
  symlink** (macOS `/var` → `/private/var`, or a symlinked checkout), because
  reported paths resolve to the real path and no longer matched the configured
  root.

---

## [0.10.0] - 2026-07-27

### Added
- **Git-status line numbers** — line numbers are tinted by what git thinks of
  the line: green for added, orange for modified, red on the line a deleted
  block sat after. Backed by a new `GET /mbeditor/git/line_diff` endpoint over
  `git diff -U0`, and never a reason to fail a file load: a missing HEAD or a
  non-repo simply leaves the numbers plain.
- **Problems panel** — error and warning counts in the status bar open a
  drawer listing every diagnostic across the open files, grouped by file with
  the offending source line and click-to-navigate. Counts cover the open tabs,
  which is where Monaco's markers live; RuboCop, ruby-lsp and the TypeScript
  worker all feed it through one subscription.
- **Outline for JS, JSX and TypeScript** — the Methods/Outline button now
  works in those files, translating the TypeScript worker's own navigation
  tree rather than adding a second lexer. Arrow functions and function
  expressions assigned to variables are listed; data constants, object-literal
  keys and anonymous callbacks are not.
- **Colour-coded Rails log** — the log drawer distinguishes request
  boundaries, controller dispatch, SQL, renders, redirects and failures, with
  `Completed` lines coloured by status code.
- **Optional workspace file watching** — with the host's
  [`listen`](https://github.com/guard/listen) gem, changes made outside the
  editor (a terminal `git checkout`, a generator, another editor) refresh the
  file tree and git decorations instead of going stale. Absent the gem,
  behaviour is unchanged. Configurable via `config.watch_files`.

### Fixed
- **ruby-lsp hover showed a dead link.** ruby-lsp renders its "Definitions"
  line as VS Code `file://` links, which Monaco draws as links but nothing in
  the browser can open, so clicking did nothing. In-workspace links are now
  rewritten to a Monaco command that opens the file at the line; gem and
  stdlib links, which the editor cannot open at all, degrade to plain code
  spans. The `/module_members` breakdown is also restored beneath a constant
  hover — ruby-lsp's constant hover never lists what the class or module
  defines, so taking its output wholesale had dropped it.
- **False-positive type errors in plain JS/JSX.** The editor kept a denylist
  of TypeScript diagnostic codes to suppress; it had grown to eight and still
  leaked (TS2322 on a spread carrying an extra prop). Untyped JS gives
  TypeScript nothing to check against, and which way it guesses is arbitrary —
  state seeded with `useState({})` errors on every key while the same object
  from `JSON.parse` stays silent. JS/JSX now keeps only the checks that are
  sound without annotations: syntax errors, `Cannot find name`, and unused
  locals. `.ts`/`.tsx` keeps full checking, where the types are hand-written.

### Changed
- The **Logs** button moved from the top toolbar to the status bar.
- **Quick-open ranks recently opened files** above the static file-type tier,
  so a file you were just in outranks a never-opened controller. Match quality
  still comes first, so a worse match cannot jump the queue.
- The title-bar search field now fills 75% of the space between the title and
  the toolbar buttons instead of a fixed 340px.
- Test-suite compatibility fixes carried over from the unreleased 0.9.1/0.9.2
  work: MiniRacer-dependent parser suites skip in minimal bundles, and the
  Outline system tests exercise navigation through click semantics.

---

## [0.9.0] - 2026-07-23

### Added
- **Test-aware Ruby Outline** — the editor now recognises Minitest and RSpec
  suites, tests, and helper methods in `_test.rb` and `_spec.rb` files. It
  reads the unsaved Monaco buffer, preserves nested suite depth and method
  visibility, supports keyboard navigation, and safely reports truncation or
  parser failures without disrupting the editor.
- **Ruby test-DSL highlighting** — Minitest/RSpec declarations, hooks, and
  helpers now receive structural Monaco tokens while Ruby files retain the
  existing `ruby` language identity and integrations.

### Security
- **Dangling symlink containment** — every editor and Git path check now
  rejects dangling symlinks that resolve outside the workspace or repository,
  closing a write-through escape for create, save, rename, and directory
  operations.
- **Filesystem-aware exclusions** — exclusion matching now normalizes Unicode
  spellings and folds case only on case-insensitive filesystems, preventing
  case or normalization variants from reaching excluded directories such as
  `.git`.

### Changed
- Generated `graphify-out/` artifacts are ignored by Git.

---

## [0.8.1] - 2026-07-22

### Fixed
- **ruby-lsp features never started on Ruby 3.0 and 3.1.** The client waited
  for responses with `Queue#pop(timeout:)`, which only accepts that keyword
  from Ruby 3.2 — so the initialize handshake raised on older rubies and every
  ruby-lsp request fell back to the built-in services. The gemspec supports
  Ruby >= 3.0; the wait now uses a portable path there. Both branches are
  covered by tests regardless of which Ruby runs the suite.
- The gem's own `mini_racer`/`ruby-lsp` development dependencies are gated on
  Ruby >= 3.2 — mini_racer's native extension fails to build on 3.0/3.1, which
  broke `bundle install` for contributors on those versions. Neither gem is
  needed by the suite.

---

## [0.8.0] - 2026-07-22

### Added
- **Ruby language-server integration (optional)** — when the host app has
  [ruby-lsp](https://github.com/Shopify/ruby-lsp) installed, go-to-definition,
  hover, completion, and diagnostics for Ruby are answered by a persistent
  ruby-lsp process (unsaved buffer contents included), with automatic fallback
  to the built-in grep/Ripper services on timeout, crash, or absence — hosts
  without ruby-lsp see no change. Adding `ruby-lsp-rails` alongside it needs no
  mbeditor configuration. New config: `ruby_lsp` (`:auto`/`false`),
  `ruby_lsp_command`, `ruby_lsp_timeout`.
- **Ruby diagnostics from ruby-lsp** — Ruby files are checked by the language
  server instead of booting RuboCop over HTTP on every debounce, adding Prism
  syntax errors and warnings alongside RuboCop offenses. Quick-fix lightbulbs
  still work for correctable cops; non-RuboCop diagnostics correctly get none.
- **Run the test under the cursor** — `Ctrl/Cmd+Shift+T`, or *Run Test at
  Cursor* in the editor context menu, runs only the enclosing test. The filter
  follows the detected framework (`path:line` for RSpec and `bin/rails test`, a
  `-n` name filter for the plain Minitest runner), so it works with a custom
  `test_command` too, and falls back to the whole file when the cursor isn't
  inside a test.
- **Ruby intellisense inside ERB** — hover, completion, go-to-definition, and
  auto-`end` now work inside `<% %>` tags in `.html.erb` views and stay inert in
  the surrounding HTML. ERB uses the built-in workspace services (ruby-lsp
  cannot parse ERB), and Rails view helpers are filtered out.
- **Workspace-wide JS ambient globals** (`GET /js_globals`) — every top-level
  `var`/`let`/`const`/`function`/`class` declaration and `window.X =` assignment
  across the workspace's JS-family files (incl. `.js.jsx`, `.js.erb`) is
  declared to Monaco's TypeScript worker in one shot, so cross-file component
  references in Sprockets/react-rails apps no longer show "Cannot find name" —
  no imports needed. Refreshes automatically on file changes. New
  `config.js_global_identifiers` declares runtime-only globals (e.g.
  `%w[Routes I18n]`).
- **Save-time babel syntax check for JS/JSX** — when the host app has
  `mini_racer` and a babel-standalone asset (the react-rails no-node setup),
  saving a `.js`/`.jsx` file runs the same babel transform the asset pipeline
  will, surfacing pipeline-breaking parse errors as editor markers.
  Auto-detected; `config.js_syntax_check = false` disables,
  `config.babel_standalone_path` overrides asset lookup.
- **Format on save** — new editor setting (off by default): saving runs RuboCop
  `-A` for Ruby or Prettier for JS/JSX/JSON/CSS/SCSS/HTML/Markdown before
  writing, and never blocks the save if the formatter fails.
- **RuboCop server mode** — lint/quick-fix/format use `rubocop --server` when
  the workspace's rubocop supports it (>= 1.31), cutting per-lint latency from
  seconds (cold boot per request) to ~100 ms. `config.rubocop_server = false`
  restores `--no-server`.
- **`git grep` search tier** — project search picks rg > `git grep`
  (multithreaded) > plain grep, so hosts without ripgrep get fast search instead
  of the slow grep fallback.
- **Live search results** — saving a file through mbeditor re-scans just that
  file and updates its rows in the open search panel in place.
- **`config.search_respect_gitignore`** (default `false`) — when enabled,
  project search and definition lookups skip `.gitignore`d files.
- **Inline color swatches + picker (all file types)** — color literals
  (`#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()`) show a
  clickable color square, opening Monaco's native color picker; choosing a color
  rewrites the literal in its original notation. The CSS family (css/scss/less)
  keeps Monaco's own built-in provider.
- **Title-bar search box** — a "Search files…" box opens quick-open (same as
  `Ctrl/Cmd+P`); its empty state lists recently opened files before Favourites
  and Recent Searches.
- **Tab context menu** — right-clicking an editor tab offers Close, Close
  Others, Close Saved, and Close All (alongside File History / Find in
  Explorer).
- **New-file button in the tab bar** — a `+` button after the last tab creates a
  new file in the active file's directory via the file-tree inline-create flow.
- **Rails log viewer** — a drag-resizable bottom-drawer panel (toggle via the
  status bar or `Ctrl+Shift+L`) that streams the active environment's
  `log/<env>.log` in real time over ActionCable, with an HTTP polling fallback.
  Includes a substring filter; height persists across sessions. Read-only.

### Changed
- **Search executes one subprocess per query** (previously two — the second, a
  full-workspace count scan, could not terminate early). The capped full result
  set is cached ~30 s, so pagination and total counts are served from memory; a
  new query kills the previous still-running search. New `config.search_timeout`
  (default 15 s) bounds every search subprocess. Case-insensitive grep runs
  under `LC_ALL=C` (10–50× faster on BSD grep; non-ASCII case folding is not
  attempted on the grep tier).
- **`config.git_timeout` now defaults to 10 seconds** (was unbounded). All git
  subprocesses in the info fan-out are individually bounded; a timed-out call
  blanks its own field instead of failing the payload. Set
  `config.git_timeout = nil` to restore unbounded behavior.
- **Git polling is two-tier** — the 5 s background poll hits the cheap
  `/git_status` (2 subprocesses) and only runs the full `/git_info` fan-out
  (~10 subprocesses) when the branch or working tree actually changed.
  `GitInfoService` gained single-flight computation and stale-while-error.
- **`formatOnType` is now off by default** — on-type formatting added
  per-keystroke latency on slower machines; enable it in editor settings.
  Format-on-paste and the explicit Format action are unchanged.
- **The Ruby definition cache is now bounded.** Entries carry each file's full
  source, and the whole cache was rewritten on every change, so a large
  workspace grew to tens of megabytes. Entries are LRU-ordered and trimmed to
  2000 before each persist.
- Default `excluded_paths` also covers `public/assets` and `storage`.
- Unavailable lint tools are re-probed every 60 s, so installing rubocop or
  ripgrep while the server is running is picked up without a restart.

### Fixed
- **ruby-lsp answered from stale buffers.** ruby-lsp supports only incremental
  document sync, so mbeditor's full-text change notification raised inside the
  server and left it holding the content from the first open — every hover,
  definition, and completion on an edited buffer used out-of-date text. Changed
  buffers are now re-opened, which is correct without computing incremental
  ranges.
- **JS go-to-definition picked nested functions over globals** — with two
  same-named functions (one top-level, one inside an IIFE/object), Ctrl+click
  navigated to whichever grep match came first. Top-level declarations
  (column 0, `window.X =`, `export`) now rank first, and clicking
  `SomeParent.myFunction` or a name in `const { myFunction } = SomeParent`
  resolves the parent's member definition directly. Hover follows the same
  rules, and nested matches no longer pollute the ambient-globals list.
- **JS definition lookups were silently broken on rg-less machines in git
  workspaces** — the search patterns used `(?:`, `\b`, and `\s`, which
  `git grep`'s POSIX ERE engine rejects or treats as literals, so the git-grep
  tier returned nothing. All patterns are now pure POSIX ERE.
- **Project search and definition lookups disagreed about `.gitignore`** —
  search ignored it while definition lookups honoured it. Both now follow
  `config.search_respect_gitignore`.
- **Ruby auto-`end` failed in the most common case** — typing a new
  `def`/`class`/`if` *above* an existing sibling block: the sibling's `end`
  (same indentation) was mistaken for the new block's, so Enter inserted no
  `end`. Same-indent code lines now correctly terminate the scan
  (`else`/`elsif`/`when`/`rescue`/`ensure` still continue it).
- Ruby auto-`end` could insert a tab into a spaces-indented file when Monaco's
  indentation auto-detection misreported the file; the opener line's own
  indentation style now wins.
- Search crashed with `ArgumentError: invalid byte sequence in UTF-8` when a
  match line contained invalid UTF-8 (subprocess output is now scrubbed).
- Search pagination's virtual-scroll loader called an undefined `basePath()`
  (latent `ReferenceError`) (#69).
- The CSRF Referer check used `URI#origin`, raising a 500 on Ruby 3.0.
- Corrupt branch-state JSON was discarded silently; `prune_branch_states` now
  logs it (#68), and `EditorChannel#save_branch_state` logs rejected invalid
  branch names (#74).
- `EditorChannel` spawned a `git rev-parse` subprocess on every WebSocket action
  (including every auto-save); the workspace root is now resolved once per
  process and shared with the controllers.
- The first go-to-definition after boot no longer blocks the request on a full
  workspace Ripper scan — the definition cache warms in a background thread on
  the first `/workspace` call.
- JS definition lookups' grep fallback scanned `node_modules` and vendor trees
  with no exclusions and no timeout.
- **Optional React props flagged as required** — Monaco's JS type-checking
  (`checkJs`) inferred every referenced prop of a plain-JS component as required
  and flagged call sites that omitted it (TS 2741/2739). Those false positives
  are now suppressed while genuinely useful checks remain.
- Tab bar's `+` (new file) button had a full-height, over-wide hover box; now a
  centred 24 px square matching other icon buttons.
- Title-bar "Search files…" box is now pill-shaped.
- Source-control panel buttons (`git-header-btn`, `git-action-btn`,
  `git-section-action-btn` — the latter two previously unstyled) now share the
  explorer panel's button geometry, radius, and hover treatment.

### Security
- **Origin/Referer validation for non-GET requests** (#75) — mutating requests
  are now checked against the request's own origin, closing the last gap left
  by the `X-Mbeditor-Client` header guard alone.
- **Symlink escape hardening** — the file tree no longer recurses into
  symlinked directories (#65), and `GitService.resolve_path` resolves symlinks
  before its containment check (#66), matching the guarantee `resolve_path`
  already made elsewhere.
- Bumped the bundled `form-data` dev dependency to 4.0.6 to clear a HIGH npm
  advisory.
- The log viewer displays log contents **verbatim**, which may include request
  params, tokens, or SQL values. It is read-only and gated by the host app's
  auth like every other editor route, but operators should be aware that logs
  can contain secrets.

---

## [0.7.5] - 2026-06-03

### Fixed
- **What's New tab restored blank** — `isChangelog` was stripped during periodic tab persistence (`MbeditorApp.js:1540`), so the changelog tab was restored without the flag on page reload. The pane rendered it as a normal file tab (Monaco) instead of `ChangelogView`. Added `isChangelog` to the serialized tab properties and patched `openChangelogTab` to set the flag on any restored tabs that lack it.

---

## [0.7.4] - 2026-06-03

### Fixed
- **Custom path reverse lookup (frontend)** — the v0.7.3 backend fix was complete, but the frontend's `resourceLabelFromPath` still returned `null` for paths under `app/` that weren't `controllers|models|views|helpers`, so custom paths like `app/assets/javascripts/…` were never recognized. Moved the custom-path check to the top of the function, matching the backend approach.

---

## [0.7.3] - 2026-06-03

### Fixed
- **Custom path reverse lookup (backend)** — moved the custom-path check in `extract_resource_names` before the `case` statement so paths under `app/assets/`, `app/javascript/`, etc. are handled. Stripped `_controller`/`_model`/`_helper`/`_service` suffixes from custom-path filenames for consistent label/grouping.
- **Schema modal `self.table_name` support** — reads `self.table_name` from the model file before falling back to `ActiveSupport::Inflector.tableize`, enabling custom table names.
- **Structure.sql broader schema-prefix regex** — handles quoted schemas, non-public schemas, and no prefix.
- **PostgreSQL type coverage** — expanded `sql_type_to_rails` with full PostgreSQL type coverage (timestamptz, double precision, citext, hstore, geometric types, etc.).
- **Schema read error handling** — broadened rescue in `try_schema_rb`/`try_structure_sql` to catch encoding errors.

---

## [0.7.2] - 2026-06-03

### Changed
- **Changelog entries backfilled** — added full release notes for 0.7.1 (persistent undo history, `db/structure.sql` schema support, Rails panel fixes) so the What's New panel shows accurate content on upgrade.
- **Release workflow documented** — `CLAUDE.md` now describes the release process so future releases can be triggered with a single instruction.

---

## [0.7.1] - 2026-06-03

### Added
- **Persistent undo history** — edit operations are captured in the browser and flushed to the server on save and tab close, then replayed the next time the file is opened. Undo/redo now reaches back further than the current session. Stale history is pruned automatically when old branches are cleaned up.
- **`db/structure.sql` schema support** — the model schema modal now reads `db/structure.sql` when `db/schema.rb` is absent (SQL-format migrations).

### Fixed
- **Rails panel long filenames** — long filenames in the Rails panel are now truncated correctly and custom-path entries populate reliably.
- **Schema lookup error logging** — failures to parse the schema file now emit a diagnostic log entry to aid debugging.

---

## [0.7.0] - 2026-05-21

### Added
- **Model schema modal** — click the table icon next to any resource in the Rails panel to view its database columns, types, constraints, and indexes parsed from `db/schema.rb`.
- **Changelog tab** — click the version number in the status bar to open a formatted changelog tab. Upgrades automatically open "What's New" on first boot after a version bump.
- **Rails panel: concerns** — model and controller concerns appear as a dedicated group in the Rails panel.
- **Rails panel: file kind labels** — each entry shows a dim label (Controller, Model, View, Test, Concern, Helper) on the right so you can distinguish files with similar names at a glance.
- **Rails panel: custom-path awareness** — files living outside the standard `app/` tree (configured via `related_files_custom_paths`) now show related files in the panel.
- **SQL/HTML heredoc highlighting** — Ruby heredocs with `<<~SQL`, `<<~HTML`, etc. tokenize their body with SQL/HTML keyword colours in the Monaco Monarch tokenizer.
- **Rake file syntax** — `.rake` files now use Ruby syntax highlighting.
- **Middle-click to close tab** — scroll-wheel click on any tab closes it (matching browser and VS Code behaviour).

### Fixed
- **Format button on Ruby files** — the Format button now correctly converts space-indented buffers to tabs before sending to RuboCop, so `Layout/IndentationStyle` offenses are fixed rather than silently ignored.
- **Hover highlight position** — hovering a JS/JSX global or component name now highlights the exact word under the cursor instead of text on a different line. The hover cache now stores only the popup contents and rebuilds the Monaco `Range` fresh per hover call so the same symbol on different lines highlights correctly.
- **`<MyComponent/>` hover** — components defined as `const MyComponent = () => {}` resolve correctly on hover; the JsDefinitionService grep pattern no longer uses `\s` inside character classes, which was silently failing under macOS BSD grep.
- **"Edited externally" false positives** — a `recentSavesRef` map suppresses external-edit warnings for 3 s after a successful save, preventing the warning triggered by the WebSocket `files_changed` broadcast that follows every save.
- **Branch detection race during save** — saving a file no longer triggers a false branch-switch (which was closing all tabs) by guarding the branch-change subscriber with `isSavingRef`.
- **File creation performance** — `GitInfoService.invalidate` is now called in a background thread so create-file and create-directory requests respond immediately.
- **Explorer type-ahead jump during rename/create** — global key-down handler returns early while a rename or create input is active.
- **Authlogic SHA512 console spam** — optional `authentication_cache_ttl` config (default 0 = disabled) caches successful authentication results in the session, reducing per-request auth lambda calls to at most once per TTL window.
- **Unused-method false positives in test files** — the unused-methods overlay is suppressed when the active file lives under `test/` or `spec/`.
- **JSX "defined twice" errors** — TS2300/TS2451 diagnostics are filtered out; they are structural false positives caused by Monaco treating all open JS files as a shared global script context.

### Changed
- **Dirty marker in Rails panel** now uses the same orange (`#e5c07b`) as the tab bar dirty dot.
- **Rails panel branch-switch UX** — tabs stay visible (read-only) during a branch switch instead of disappearing immediately; a `branch_state_restore` setting (default `true`) controls whether tab state is saved/restored across branch switches.

## Internal refactor (2026-05-23)

### Changed (no user-visible behavior change)
- **`AvailabilityProbe` extracted** — tool-availability checks (`rg`, `rubocop`, `haml_lint`, `git`, etc.) pulled out of `EditorsController` into `AvailabilityProbe`. Closes #22, #23, #24.
- **`FileTreeService` extracted** — directory-tree construction pulled out of `EditorsController` into `FileTreeService`. Closes #22, #23, #24.
- **`SearchReplaceService` extracted** — `rg`/`grep` detection, flag building, ReDoS guards, per-file timeout (`5 s`), size cap, encoding handling, and replace-in-files all unified in one service. `stream_search_results`, `count_search_results`, `RG_AVAILABLE`, and the inline 95-line `replace_in_files` action removed from the controller; replaced by thin delegators. Closes #25, #26, #27, #28.
- **`EditorStateService` extracted** — JSON state persistence (file locking, size limits, error handling) was duplicated between `EditorsController` and `EditorChannel`. Both protocol layers now delegate to `EditorStateService`; fixing a locking bug requires editing one file. Closes #29, #30, #31, #32.
- **`RubyDefinitionService` cache encapsulated** — `load_disk_cache_once`, `persist_cache`, `scan`, `file_cache`, and `mutex` removed from the public interface. `defs_in_file` and `includes_in_file` self-warm on cache miss; callers no longer need to manage lifecycle. Warmup hack in `UnusedMethodsService` removed. Closes #33, #34, #35, #36.
- **`GitCommitDetailService` and `GitCombinedDiffService` extracted** — the two `GitController` actions that contained raw `Open3.capture3` calls (`commit_detail`, `combined_diff`) are now thin delegators. No `EditorsController` action contains subprocess logic. Closes #37, #38, #41.

### Tests
- 92 new tests and 256 new assertions across 6 new service test files; suite now at 495 tests / 1681 assertions (up from 403 / 1425).

---

## Internal refactor (2026-05-17)

### Changed (no user-visible behavior change)
- **`GitInfoService` extracted** — the 139-line concurrent wave-orchestration block in `EditorsController#git_info` is now `GitInfoService.call(repo_path)` with a 5 s TTL cache and `invalidate` hook. Controller action is a single `render json:` call. `parse_porcelain_status` and `parse_name_status` promoted to `GitService` module functions. Closes #4, #5, #6.
- **`CodeSearchService` extracted** — `rg`/`grep` subprocess execution, fallback, ReDoS guards, and result parsing unified in one place. `JsDefinitionService` and `JsMembersService` are now thin wrappers. Closes #7, #8, #9, #10.
- **`ExclusionMatcher` extracted** — four diverged implementations of "should this path be excluded?" replaced by `ExclusionMatcher.new(config.excluded_paths).excluded?(path)`. `EditorsController`, `RubyDefinitionService`, and `UnusedMethodsService` all delegate to it. Closes #11, #12, #13, #14.
- **`FileOperationService` extracted** — ~200 LOC of inline file-CRUD logic in `EditorsController` moved to `FileOperationService` (save, create_file, create_dir, rename, destroy_path). Each controller action is now: resolve path → block-check → call service → broadcast → render. Closes #15, #16, #17.
- **`ProcessRunner` extracted** — three copies of "Open3 + timeout thread + SIGKILL" unified in `ProcessRunner.call(cmd, timeout:, env: {}, stdin_data: nil, chdir: nil)`. `GitService`, `TestRunnerService`, and the `EditorsController` lint path all delegate to it. Fixes the latent popen deadlock in `TestRunnerService`. Closes #18, #19, #20, #21.

### Tests
- 271 new tests and 845 new assertions across 10 new service test files; suite now at 403 tests / 1425 assertions (up from 132 / 580).

---

## [0.6.0] - 2026-05-11

### Added
- **Virtual scrolling in FileTree** — only visible rows are rendered, dramatically improving performance with large file trees.
- **Multi-resource Rails panel** — the sidebar Rails panel now shows related files for up to 10 open Rails resources simultaneously, grouped by resource name with a dirty-file dot indicator.
- **Vim `:split` / `:vsplit` commands** — split the current file into the other pane using standard Vim command-line syntax.
- **Format changed-line highlighting** — after running Format Document, changed lines are highlighted with a green background for 3 seconds.
- **Sidebar panel titles** — "Explorer", "Search", and "Rails" labels now appear at the top of each sidebar panel.
- **Dirty-file indicators in Rails panel** — a small dot appears next to related files with unsaved changes.

### Changed
- Rails activity bar icon updated from text "R" to a Font Awesome gem icon.
- Monaco model cache size raised from 15 to 25 (`MAX_MODELS`).
- `wordBasedSuggestions` default changed to `'currentDocument'`; `linkedEditing` now respects user preferences.
- Git file comparison uses a lightweight signature function instead of `JSON.stringify`.
- Window-globals detection improved: symbols found on `window` at runtime are declared as globals to suppress TS2304 errors.

### Removed
- JSON auto-pretty-print on file open (files now display raw content).

## [0.5.1] - 2026-04-30

### Added
- **Large file pagination** — files over 5 MB now open in read-only paginated mode (500 lines per page) instead of showing an error. A bar below the toolbar shows the current line range, total line count, and file size, with Prev/Next navigation. The backend streams only the requested line slice via `File.foreach` so arbitrarily large files never load fully into memory.
- **JSON auto pretty-print** — `.json` files are automatically formatted with 2-space indentation when opened. Invalid JSON falls back to raw display with Monaco's built-in error markers. The formatted content is set as the editor baseline so the file does not appear dirty after opening.

## [0.5.0] - 2026-04-30

### Added
- **Zen / focus mode** — `Cmd+Shift+Z` hides the sidebar and git panel for a distraction-free editing experience.
- **Bulk find-and-replace** — search and replace across all workspace files in one operation.
- **File content prefetch on hover** — opening a file from the tree is now instant; content is fetched while hovering the row.
- **Client-side search cache** — search results are cached client-side for 30 s and invalidated automatically on save.
- **Monaco model cache with LRU eviction** — in-memory Monaco models are capped at 15 and evicted in LRU order to keep memory use bounded.

### Changed
- **Faster initial render** — Monaco startup is now decoupled from the React mount lifecycle, cutting time-to-first-edit.
- **Robust dirty-state tracking** — dirty state is now driven by Monaco's `alternativeVersionId`; `cleanVersionId` is reset correctly on save-on-close so re-opened tabs start clean.

### Fixed
- ActionCable reconnect logic hardened; regression tests added to confirm websocket lifecycle log filtering still works after reconnect.
- Bulk replace: fixed a security issue and a correctness bug in the replacement pipeline; added covering tests.

## [0.4.5] - 2026-04-23

### Fixed
- Suppressed Action Cable websocket request lifecycle noise (`Started/Finished "/cable" [WebSocket] ...`) in development logs via `CableLogFilter`.
- Added regression coverage to ensure websocket lifecycle request logs stay filtered while regular Action Cable logs continue to pass through.

## [0.4.4] - 2026-04-23

### Fixed
- `CableLogFilter` now preserves Action Cable and Action Pack tagged-logger compatibility by supporting formatter-level `current_tags` access and no-op tag operations for untagged or nil formatters.
- Added regression coverage for formatter-tag compatibility paths to prevent `current_tags` runtime errors.
- System test Cuprite driver configuration now applies explicit startup timeout options through `driven_by` to avoid intermittent Ferrum browser bootstrap timeouts in CI.

## [0.4.3] - 2026-04-22

### Added
- Documented optional Action Cable host-app setup and fallback behavior for realtime editor updates.

### Changed
- `bundle exec rake test` now includes `test/lib/**/*_test.rb` so release validation covers library-level regression tests.

### Fixed
- Action Cable availability detection now respects whether `/cable` is actually mounted, and websocket handshake failures fall back to polling without noisy console errors.
- Circular loading indicators keep animating even when global reduced-motion styles are active in production.
- `CableLogFilter` now remains compatible with untagged logger stacks used outside full Action Cable setups.

## [0.4.2] - 2026-04-22

### Fixed
- Updated sidebar search system test selectors to match the current UI loading and clear controls, resolving CI matrix failures in GitHub Actions.

## [0.4.1] - 2026-04-22

### Added
- Real-time file update integration via Action Cable to improve collaborative and live-refresh editing workflows.

### Changed
- Search functionality enhancements for improved result handling and responsiveness.

## [0.4.0] - 2026-04-22

### Added
- **Draft auto-save and restore** — unsaved edits are written to `localStorage` every 500 ms per file. On reconnect after a server outage, a dialog offers to restore any drafts that diverged from the in-memory tab content.
- **Tab bar layout setting** — new "Tab bar layout" preference (Scroll / Wrap multi-row) stored in editor prefs; `TabBar` receives a `tabDisplayMode` prop and applies the appropriate CSS class; horizontal wheel scroll is disabled in wrap mode.

### Fixed
- **Drag-to-split** — pane 2 drop zone is now only shown when the cursor actively hovers over the right-half content area, preventing the tab bar from collapsing during a drag. Dropping onto a tab bar element is no longer intercepted by the cross-pane drop handler, preserving same-pane reordering.
- **Quick Open sorting** — files consistently rank above directories; within the same priority tier results are sorted by match relevance (exact basename > prefix match > substring > other).
- **Search total count** — the count thread is joined with a 100 ms timeout; `total_count` is omitted from the response when the thread has not finished, so the first page is never blocked by the counting subprocess.
- **Status bar message colour** — removed `color-mix` transparency that was dimming the accent-text colour.

## [0.3.9] - 2026-04-21

### Added
- Search responses now include a total result count; background counting runs for the first page to populate it without blocking.
- Editor preferences expanded with line height, letter spacing, cursor style, and auto-closing bracket/quote settings.

### Fixed
- Multi-line tab indentation corrected; added regression test to prevent recurrence.
- 8 correctness, security, and reliability fixes surfaced by ultrareview.

## [0.3.8] - 2026-04-16

### Fixed
- Prevented Emmet's custom Tab action from intercepting selected text, so multi-line selections are no longer replaced when pressing Tab/Shift+Tab in markup editors.

### Added
- Added a system regression test to ensure multi-line selections in JSX are not collapsed by the Emmet Tab integration.

## [0.3.7] - 2026-04-16

### Fixed
- Corrected the `destroy_path` missing-path controller test to expect `200 OK` for idempotent DELETE behavior, which unblocks the tag-based publish workflow for this release.

## [0.3.6] - 2026-04-15

### Fixed
- Multi-file/folder delete now deduplicates child paths covered by a selected ancestor directory, preventing redundant requests and Rails 404 console errors.
- Switched multi-delete from `Promise.all` to `Promise.allSettled` so all deletions complete before checking for failures rather than bailing on the first rejection.
- `destroy_path` controller action is now idempotent — returns 200 when the path is already gone, matching correct REST DELETE semantics.

## [0.2.8] - 2026-04-15

### Changed
- Refactor code structure for improved readability and maintainability.

## [0.2.4] - 2026-04-02

### Added
- **Global service exposure** — `SearchService` and `GitService` are now attached to the `window` object so host-app scripts can call them directly.
- **Loading indicator** — editor now shows a loading state while assets initialise.

### Changed
- **Service worker** — simplified to a minimal implementation; removed the caching layer that was causing stale-asset issues.
- **Monaco Handlebars language** — updated language definition for improved syntax coverage and structure.

### Fixed
- Test suite clean-up following recent service and SW changes.

## [0.2.3] - 2026-04-02

### Changed
- Released the current mainline commit as the latest tagged version.

## [0.2.1] - 2026-04-01

### Fixed
- **Missing files in restored tabs** — file loads can now opt into a structured missing-file response so restored editor tabs stay stable instead of erroring when a file has been deleted.
- **Markdown preview restore** — markdown preview tabs are only recreated after a real file load, which avoids blank preview panes for missing files.
- **Fallback search exclusions** — the non-ripgrep search path now excludes configured nested directories without accidentally excluding unrelated sibling directories with the same basename.
- **Branch combined diff baseline** — branch-wide combined diffs now prefer the same merge-base style baseline used elsewhere in the git panel instead of relying only on the upstream ref.
- **PWA assets** — the web manifest is emitted with explicit manifest content, and the service worker now uses install and activate handlers instead of a no-op fetch listener.

## [0.1.9] - 2026-03-27

### Added
- **Authentication hook** — new `authenticate_with` configuration option accepts a proc/lambda that runs as a `before_action` in all engine controllers. Use it to plug in the host app's auth system (e.g. Authlogic's `UserSession.find`, Devise's `authenticate_user!`). The proc executes via `instance_exec` so `session`, `cookies`, `redirect_to`, and auth library class methods are all accessible. Default: `nil` (no auth, existing behaviour preserved).

### Fixed
- **HTTP status code** — all 422 responses now use `:unprocessable_content` (the correct Rails symbol for HTTP 422 since RFC 9110) instead of the deprecated `:unprocessable_entity`.
- **Search exclusion** — search command construction refactored for clearer exclusion handling.

## [0.1.8] - 2026-03-27

### Fixed
- **Stray engine config** — removed `config/environments/development.rb` from the engine root; environment configs belong only in the dummy app.
- **CI workflow** — corrected ref format in the GitHub Actions checkout step.
- **Test reliability** — refactored HTTP stubbing in `RedmineServiceTest` for improved clarity.

## [0.1.7] - 2026-03-26

### Added
- **Test results panel** — a dedicated panel shows pass/fail counts, per-test status icons, and error messages after a test run. Inline failure markers overlay the Monaco editor and can be toggled independently of RuboCop markers.
- **File history context menu** — the tab bar context menu now includes a file history option that opens the per-file commit log.

## [0.1.6] - 2026-03-25

### Added
- **Editor preferences** — added a settings tab for theme, font size, font family, tab size, and insert-spaces preferences.

### Changed
- **Theme support** — Monaco now initializes with the saved editor theme and other user preferences.
- **Language tooling** — JavaScript and TypeScript use the dedicated worker setup for better editor support.

### Fixed
- **Search results** — capped workspace search results now surface the cap state in the UI.
- **File size validation** — the 5 MB file-size limit now applies on write as well as read.
- **System test teardown** — Cuprite sessions now reset before deleting temporary workspaces, preventing background git requests from hitting removed paths in CI.

## [0.1.5] - 2026-03-24

### Added
- **Shared file icons** — explorer, git panel, tabs, and quick-open now use the same icon mapping.
- **Quick-open polish** — Ctrl+P shows file icons beside each result and includes a clear button.

### Changed
- **Search UX** — the sidebar search now shows a loading spinner while the backend search request is in flight, and it includes a clear button.
- **Git refresh UX** — the git panel refresh button now spins while refresh data is loading.

## [0.1.4] - 2026-03-24

### Fixed
- **Blame workspace root** — git blame now resolves paths through the shared workspace-root helper, which keeps dummy-app and auto-detected repo roots consistent.
- **Heartbeat log noise** — `/ping` requests are silenced at the middleware layer before Rails request logging runs.
- **Blame presentation** — blame is rendered as grouped headers showing author and commit message above contiguous code blocks.

## [0.1.3] - 2026-03-24

### Performance
- **Heartbeat log spam** — `ping` action now uses `Rails.logger.silence`; the frontend switches to a self-rescheduling `setTimeout` (30 s online / 5 s offline) and skips polls entirely while the browser tab is hidden (`document.hidden`).
- **FileTree re-renders** — `FileTree` is now wrapped in `React.memo` with a data-only comparator. Event handler references (which are re-created on every `MbeditorApp` render) are intentionally ignored, preventing the entire O(n) tree traversal on every keypress, git poll, or status-bar update.
- **Search index blocking** — `SearchService.buildIndex` is now deferred to idle time via `requestIdleCallback` (with a 50 ms `setTimeout` fallback for Safari). The main thread is no longer blocked during the synchronous MiniSearch rebuild that runs after every project-tree refresh.
- **Blame decoration churn** — removed `tab.content` from the blame-decoration `useEffect` dependency array in `EditorPanel`. Decorations are derived from `blameData` (fetched once on toggle); re-applying the same decorations via `deltaDecorations` on every keystroke was unnecessary.
- **EditorStore slice subscriptions** — added `EditorStore.subscribeToSlice(keys, fn)` so future sub-components can subscribe only to the store keys they care about, avoiding re-renders for unrelated state changes.

## [0.1.2] - 2026-03-24

### Fixed
- **Webfonts 404** — Font Awesome CSS used relative `../webfonts/` paths that resolved to `/webfonts/fa-*` at the host-app root, where no route existed. The vendor stylesheet is now processed by Sprockets ERB so font URLs are rendered as fingerprint-correct `asset_path` calls, and `.ttf` fallback references (which were never bundled) have been removed.
- **Git compatibility** — `git branch --show-current` is only available in Git ≥ 2.22. All three call sites have been replaced with `git rev-parse --abbrev-ref HEAD` (works on any modern Git), centralised in `GitService.current_branch`. The git panel no longer reports an error on older Git installations.
- **Slow initial load** — `workspace_root` (when not explicitly configured) now caches the `git rev-parse --show-toplevel` subprocess result at the class level so the subprocess runs at most once per process. `rubocop_available?`, `haml_lint_available?`, and `git_available?` are similarly cached, keyed by their respective configuration values so tests and reconfiguration still get fresh results.

## [0.1.1] - 2026-03-24

### Changed
- Bumped the release to avoid republishing the already-pushed 0.1.0 gem and to include the latest GitHub Actions publish workflow updates

## [0.1.0] - 2026-03-20

### Added
- Mountable Rails engine providing a browser-based code editor (Monaco Editor)
- File explorer with recursive tree, git status badges, inline create/rename/delete
- Split-pane editor layout with draggable tabs
- Ctrl+P quick-open file finder (MiniSearch)
- Full-text workspace search (`rg` with `grep` fallback)
- Ctrl+S save with dirty-state tracking
- RuboCop lint and auto-format for Ruby files
- Haml-Lint support for `.haml` files
- Prettier auto-format for JS, JSX, JSON, CSS, SCSS, HTML, and Markdown
- Markdown live preview
- Git branch/status panel with ahead/behind counts
- Real-time collaborative editing via Action Cable + Y.js CRDT
- Remote cursor and selection display during collaboration
- Configurable `workspace_root`, `allowed_environments`, `excluded_paths`, and `rubocop_command`
- Path traversal protection — all file access validated within `workspace_root`
- File size cap (5 MB) on read
- CSRF guard on all write endpoints via `X-Mbeditor-Client` request header
- MIT licence
