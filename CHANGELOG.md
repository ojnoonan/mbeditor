# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Inline color swatches + picker (all file types)** — color literals
  (`#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()`) now show a
  clickable color square before them in any language, opening Monaco's native
  color picker; choosing a color rewrites the literal in its original notation.
  The CSS family (css/scss/less) keeps Monaco's own built-in provider.
- **Title-bar search box** — a "Search files…" box in the title bar opens
  quick-open (same as `Ctrl/Cmd+P`); its empty state now lists recently opened
  files before Favourites and Recent Searches.
- **Tab context menu** — right-clicking an editor tab now offers Close, Close
  Others, Close Saved, and Close All (alongside File History / Find in Explorer).
- **New-file button in the tab bar** — a `+` button after the last tab creates a
  new file in the active file's directory via the file-tree inline-create flow.
- **Rails log viewer** — a drag-resizable bottom-drawer panel (toggle via the
  status bar or `Ctrl+Shift+L`) that streams the active environment's
  `log/<env>.log` in real time over ActionCable, with an HTTP polling fallback.
  Includes a substring filter; height persists across sessions. Read-only.

### Fixed
- **Optional React props flagged as required** — Monaco's JS type-checking
  (`checkJs`) inferred every referenced prop of a plain-JS component as required
  and flagged call sites that omitted it (TS 2741/2739). Those false positives
  are now suppressed while genuinely useful checks remain.

### Security
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

## [Unreleased] — internal refactor (2026-05-23)

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

## [Unreleased] — internal refactor (2026-05-17)

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
