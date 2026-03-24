# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
