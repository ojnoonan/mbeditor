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

# Run the dummy app for development/testing
cd test/dummy && rails server
# Then visit http://localhost:3000/mbeditor

```

## Architecture

### Backend (Rails Engine)

- **`lib/mbeditor.rb`** — Main module entry point with `configure` DSL
- **`lib/mbeditor/engine.rb`** — Rails Engine definition and asset precompilation setup
- **`lib/mbeditor/configuration.rb`** — Config class (allowed_environments, workspace_root, excluded_paths, rubocop_command)
- **`app/controllers/mbeditor/editors_controller.rb`** — Core controller with endpoints handling file I/O, git commands, search, RuboCop lint/format, workspace state, and Monaco asset serving
- **`config/routes.rb`** — All engine routes

Path security: `resolve_path()` validates all file paths stay within `workspace_root`. File size capped at 5MB. Environment gating via `ensure_allowed_environment!`.

Git/RuboCop use `Open3.capture2/3` for subprocess execution. Search tries `rg` first (checked once at startup via `RG_AVAILABLE` constant), falls back to `grep -F`. RuboCop lint uses `Open3.popen3` with a 15-second timeout thread.

### Frontend (React + Monaco)

All frontend code is plain JS — edit the files directly, no compilation step required.

**React components (`app/assets/javascripts/mbeditor/components/`):**
- **`MbeditorApp.js`** — Main React component: state management, pane layout, keyboard shortcuts (Ctrl+P, Ctrl+S), server heartbeat
- **`EditorPanel.js`** — Monaco editor wrapper with Ruby syntax helpers
- **`FileTree.js`** — Recursive file browser with git status badges, inline create/rename
- **`TabBar.js`** — Draggable tab UI
- **`GitPanel.js`** — Git branch/status display
- **`QuickOpenDialog.js`** — Ctrl+P file finder
- **`CollapsibleSection.js`** — Collapsible sidebar section

**Service modules (`app/assets/javascripts/mbeditor/`):**
- **`editor_store.js`** — Flux-style centralized state
- **`file_service.js`** — Axios HTTP client for file operations (includes `ping` for heartbeat)
- **`git_service.js`** — Git status/info API client
- **`search_service.js`** — Client-side full-text search via MiniSearch
- **`tab_manager.js`** — Tab/pane/preview lifecycle management

Components are loaded individually via `application.js` Sprockets directives. `build_js.js` at the project root is retained as a utility for experimenting with JSX syntax but is not part of the normal build.

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
- Dev: `minitest-reporters`
