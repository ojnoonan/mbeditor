# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mbeditor (Mini Browser Editor) is a **mountable Rails engine** gem that provides a browser-based code editor UI for Rails apps. It is development-time only.

## Key Commands

```bash
# Install dependencies
bundle install

# Run all tests
bundle exec rake test

# Run the dummy app for development/testing
cd test/dummy && rails server
# Then visit http://localhost:3000/mbeditor
```

## Architecture

### Backend (Rails Engine)

- **`lib/mbeditor.rb`** — Main module entry point with `configure` DSL
- **`lib/mbeditor/engine.rb`** — Rails Engine definition and asset precompilation setup
- **`lib/mbeditor/configuration.rb`** — Config class: `allowed_environments`, `workspace_root`, `excluded_paths`, `rubocop_command`, `redmine_enabled`, `redmine_url`, `redmine_api_key`
- **`lib/mbeditor/rack/silence_ping_request.rb`** — Rack middleware that silences Rails request logs for all `/mbeditor/` traffic (keeps dev logs readable); the initial `GET /mbeditor` is left visible
- **`app/controllers/mbeditor/editors_controller.rb`** — Core controller: file I/O, git status/info, search, RuboCop lint/format, workspace state, Monaco asset serving
- **`app/controllers/mbeditor/git_controller.rb`** — Git feature endpoints: diff, blame, file history, commit graph, commit detail, combined diff, Redmine issue lookup
- **`config/routes.rb`** — All engine routes

**Service objects (`app/services/mbeditor/`):**
- **`git_service.rb`** — Shared module: `run_git`, `upstream_branch`, `ahead_behind`, `parse_git_log`, `parse_git_log_with_parents`, `resolve_path`. Defines `SAFE_GIT_REF` pattern used to validate upstream branch names before interpolation.
- **`git_diff_service.rb`** — Working-tree vs HEAD diff, or between two commit SHAs
- **`git_blame_service.rb`** — Per-line blame via `git blame --porcelain`
- **`git_file_history_service.rb`** — Per-file commit history via `git log --follow`
- **`git_commit_graph_service.rb`** — Full commit graph (max 150 commits) with `isLocal` flag
- **`redmine_service.rb`** — Fetches a Redmine issue via the REST API (optional integration)

**Path security:** `resolve_path()` in `EditorsController` validates all file paths stay within `workspace_root`. For existing paths it calls `File.realpath` on both the path and the root to resolve symlinks, preventing symlink escape. New paths (create, save) use `File.expand_path` only. File size capped at 5 MB on read. Environment gating via `ensure_allowed_environment!`. All non-GET/HEAD requests require the `X-Mbeditor-Client: 1` header (`verify_mbeditor_client`).

**Git/RuboCop:** Use `Open3.capture2/3` for subprocess execution. Search tries `rg` first (checked once at startup via `RG_AVAILABLE` constant), falls back to `grep -F`. Search queries capped at 500 characters. RuboCop lint uses `Open3.popen3` with a 15-second timeout thread that kills the entire process group (`pgroup: true`, `Process.kill('-KILL', ...)`). Upstream branch names are validated against `SAFE_GIT_REF = %r{\A[\w./-]+\z}` before use in git revision range strings.

### Frontend (React + Monaco)

All frontend code is plain JS — edit the files directly, no compilation step required.

**React components (`app/assets/javascripts/mbeditor/components/`):**
- **`MbeditorApp.js`** — Main React component: state management, pane layout, keyboard shortcuts, server heartbeat
- **`EditorPanel.js`** — Monaco editor wrapper with Ruby syntax helpers; handles diff tabs via `DiffViewer.js` and `CombinedDiffViewer.js`
- **`FileTree.js`** — Recursive file browser with git status badges, inline create/rename
- **`TabBar.js`** — Draggable tab UI
- **`GitPanel.js`** — Git branch/status/commit display
- **`QuickOpenDialog.js`** — `Ctrl+P` file finder
- **`CollapsibleSection.js`** — Collapsible sidebar section
- **`DiffViewer.js`** — Monaco diff editor wrapper for per-file diffs
- **`CombinedDiffViewer.js`** — Unified diff viewer for combined (all-files) diffs

**Keyboard shortcuts (registered in `MbeditorApp.js` `onKeyDown`):**
- `Ctrl+P` — Quick-open file
- `Ctrl+S` — Save active file
- `Ctrl+Shift+S` — Save all dirty files
- `Alt+Shift+F` — Format active file
- `Ctrl+Shift+G` — Toggle git panel
- `Escape` — Close dialogs/context menus

**Service modules (`app/assets/javascripts/mbeditor/`):**
- **`editor_store.js`** — Flux-style centralized state
- **`file_service.js`** — Axios HTTP client; sets `X-Mbeditor-Client: 1` header globally on all requests
- **`git_service.js`** — Git status/info/diff/blame API client
- **`search_service.js`** — Client-side full-text search via MiniSearch
- **`tab_manager.js`** — Tab/pane/preview lifecycle management

Components are loaded individually via `application.js` Sprockets directives (services before components). `build_js.js` at the project root is a utility for experimenting with JSX syntax — not part of the normal build.

### Vendored Libraries

All third-party JS/CSS is vendored in `vendor/assets/` — React 16, Axios, Lodash, Prettier, marked.js, MiniSearch, FontAwesome. Monaco Editor is in `public/monaco-editor/`.

### Test Structure

Tests use Minitest via the dummy Rails app. Run with `bundle exec rake test` from the project root (currently 132 tests, 580 assertions).

```
test/
  test_helper.rb               # loads WebMock (disable_net_connect! active globally)
  controllers/mbeditor/
    editors_controller_test.rb   # integration tests against a Dir.mktmpdir workspace
    git_controller_test.rb       # integration tests against the project repo itself
  services/mbeditor/
    git_service_test.rb
    git_diff_service_test.rb
    git_blame_service_test.rb
    git_file_history_service_test.rb
    git_commit_graph_service_test.rb
    redmine_service_test.rb      # config-guard tests via call; HTTP tests via fetch_issue + WebMock
```

Controller tests for `editors_controller` use `Dir.mktmpdir` as a temporary workspace. Controller tests for `git_controller` and all service tests use the project repo root as the git repo (real git commands). `REPO_PATH` in service tests resolves via `File.expand_path('../../..', __dir__)` (3 levels up from `test/services/mbeditor/`).

**Redmine service tests:** The dummy app initializer (`test/dummy/config/initializers/mbeditor.rb`) prepends `RedmineService#call` with fixture data so the config-guard tests work through `call`. HTTP-level tests call the private `fetch_issue` method directly via `send` to bypass the prepend — WebMock stubs the network at the socket level.

**WebMock:** `WebMock.disable_net_connect!` is active for all tests. Rails integration tests are unaffected (they use the Rack stack directly, not real sockets). Any test that needs HTTP must register a `stub_request`.

### CI / Workflows

- **`.github/workflows/test.yml`** — runs `bundle exec rake test` on push/PR to main; matrix covers default `Gemfile` and `gemfiles/rails71.gemfile`
- **`.github/workflows/publish.yml`** — runs tests, builds gem, creates GitHub Release and pushes to RubyGems.org on tag push or manual dispatch

All matrix gemfiles (`Gemfile`, `gemfiles/rails71.gemfile`) include `webmock` so `test_helper.rb` loads correctly on every CI matrix entry.

### Dependencies

- Ruby >= 3.0, Rails >= 7.1, < 9.0
- `sprockets-rails >= 3.4`
- Dev: `minitest-reporters`, `webmock`
- Host app optional: `rubocop`, `rubocop-rails` (Ruby lint/format), `haml_lint` (HAML lint), `git` (git panel)
