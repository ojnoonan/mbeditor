# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mbeditor (Mini Browser Editor) is a **mountable Rails engine** gem that provides a browser-based code editor UI for Rails apps. It is development-time only.

## Key Commands

```bash
# Install dependencies
bundle install

# Run tests
bundle exec rake test

# Lint Ruby code
bundle exec rubocop

# Run the dummy app for development/testing
cd test/dummy && rails server
# Then visit http://localhost:3000/mbeditor

# Recompile JSX source to plain JS (requires Node >= 18)
node build_js.js
```

## Architecture

### Backend (Rails Engine)

- **`lib/mbeditor.rb`** — Main module entry point with `configure` DSL
- **`lib/mbeditor/engine.rb`** — Rails Engine definition, asset precompilation setup, and JSX staleness check on boot
- **`lib/mbeditor/configuration.rb`** — Config class (allowed_environments, workspace_root, excluded_paths, rubocop_command)
- **`app/controllers/mbeditor/editors_controller.rb`** — Core controller with endpoints handling file I/O, git commands, search, RuboCop lint/format, workspace state, and Monaco asset serving
- **`config/routes.rb`** — All engine routes

Path security: `resolve_path()` validates all file paths stay within `workspace_root`. File size capped at 5MB. Environment gating via `ensure_allowed_environment!`.

Git/RuboCop use `Open3.capture2/3` for subprocess execution. Search tries `rg` first, falls back to `grep`. RuboCop lint uses `Open3.popen3` with a 15-second timeout thread.

### Frontend (React + Monaco)

The frontend is pre-compiled — JSX source lives in `src/` and is compiled to a single plain JS file. Do not edit the compiled output directly.

**Compiled output (do not edit directly):**
- **`app/assets/javascripts/mbeditor/mbeditor_components.js`** — All React components compiled from JSX

**JSX source (edit these, then run `node build_js.js`):**
- **`src/javascripts/mbeditor/components/MbeditorApp.js.jsx`** — Main React component: state management, pane layout, keyboard shortcuts (Ctrl+P, Ctrl+S)
- **`src/javascripts/mbeditor/components/EditorPanel.js.jsx`** — Monaco editor wrapper with Ruby syntax helpers
- **`src/javascripts/mbeditor/components/FileTree.js.jsx`** — Recursive file browser with git status badges, inline create/rename
- **`src/javascripts/mbeditor/components/TabBar.js.jsx`** — Draggable tab UI
- **`src/javascripts/mbeditor/components/GitPanel.js.jsx`** — Git branch/status display
- **`src/javascripts/mbeditor/components/QuickOpenDialog.js.jsx`** — Ctrl+P file finder
- **`src/javascripts/mbeditor/components/CollapsibleSection.js.jsx`** — Collapsible sidebar section

**Plain JS service modules (edit directly, no compilation needed):**
- **`app/assets/javascripts/mbeditor/editor_store.js`** — Flux-style centralized state
- **`app/assets/javascripts/mbeditor/file_service.js`** — Axios HTTP client for file operations
- **`app/assets/javascripts/mbeditor/git_service.js`** — Git status/info API client
- **`app/assets/javascripts/mbeditor/search_service.js`** — Client-side full-text search via MiniSearch
- **`app/assets/javascripts/mbeditor/tab_manager.js`** — Tab/pane/preview lifecycle management

The engine's `mbeditor.jsx.rebuild` initializer automatically detects stale JSX (by comparing mtimes) and re-runs `node build_js.js` on server boot when working from a development checkout.

### Vendored Libraries

All third-party JS/CSS is vendored in `vendor/assets/` — React 16, Axios, Lodash, Prettier, marked.js, MiniSearch, FontAwesome. Monaco Editor is in `public/monaco-editor/`.

### Test/Dummy App

`test/dummy/` contains a minimal Rails app for development and testing. It mounts the engine at `/mbeditor` and includes Monaco asset redirect routes.

Tests live in `test/controllers/mbeditor/editors_controller_test.rb` and run against a temporary workspace directory (via `Dir.mktmpdir`). Run with `bundle exec rake test`.

### CI / Workflows

- **`.github/workflows/test.yml`** — runs `bundle exec rake test` on push/PR to main
- **`.github/workflows/publish.yml`** — runs tests, builds gem, creates GitHub Release on tag push or manual dispatch

### Dependencies

- Ruby >= 3.0, Rails >= 7.1, < 9.0
- `sprockets-rails >= 3.4`
- Dev: `rubocop ~> 1.80`, `rubocop-rails ~> 2.33`, `minitest-reporters`
- Build tooling (not a gem dependency): Node >= 18 for recompiling JSX via `build_js.js`
