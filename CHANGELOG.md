# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
