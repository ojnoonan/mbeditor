# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mbeditor (Mini Browser Editor) is a **mountable Rails engine** gem that provides a browser-based code editor UI for Rails apps. It is development-time only.

## Key Commands

```bash
# Install dependencies
bundle install

# Lint Ruby code
bundle exec rubocop

# Run the dummy app for development/testing
cd test/dummy && rails server
# Then visit http://localhost:3000/mbeditor
```

## Architecture

### Backend (Rails Engine)

- **`lib/mbeditor.rb`** — Main module entry point with `configure` DSL
- **`lib/mbeditor/engine.rb`** — Rails Engine definition, asset precompilation setup
- **`lib/mbeditor/configuration.rb`** — Config class (allowed_environments, workspace_root, excluded_paths, rubocop_command)
- **`app/controllers/mbeditor/editors_controller.rb`** — Core controller with 15 endpoints handling file I/O, git commands, search, RuboCop lint/format, workspace state, and Monaco asset serving
- **`config/routes.rb`** — All engine routes

Path security: `resolve_path()` validates all file paths stay within `workspace_root`. File size capped at 5MB. Environment gating via `ensure_allowed_environment!`.

Git/RuboCop use `Open3.capture2/3` for subprocess execution. Search tries `rg` first, falls back to `grep`.

### Frontend (React + Monaco)

All frontend code is in `app/assets/javascripts/mbeditor/`. Uses Rails asset pipeline (Sprockets) with Babel transpiler — no webpack/npm.

- **`components/MbeditorApp.js.jsx`** — Main React component: state management, pane layout, keyboard shortcuts (Ctrl+P, Ctrl+S)
- **`components/EditorPanel.js.jsx`** — Monaco editor wrapper with Ruby syntax helpers
- **`components/FileTree.js.jsx`** — Recursive file browser with git status badges
- **`components/TabBar.js.jsx`** — Draggable tab UI
- **`components/GitPanel.js.jsx`** — Git branch/status display
- **`components/QuickOpenDialog.js.jsx`** — Cmd+P file finder

Service modules:
- **`editor_store.js`** — Flux-style centralized state
- **`file_service.js`** — Axios HTTP client for file operations
- **`git_service.js`** — Git status/info API client
- **`search_service.js`** — Client-side full-text search via MiniSearch
- **`tab_manager.js`** — Tab/pane/preview lifecycle management (largest JS file)

### Vendored Libraries

All third-party JS/CSS is vendored in `vendor/assets/` — React 16, Axios, Lodash, Prettier, marked.js, MiniSearch, FontAwesome. Monaco Editor is in `public/monaco-editor/`.

### Test/Dummy App

`test/dummy/` contains a minimal Rails app for development and testing. It mounts the engine at `/mbeditor` and includes Monaco asset redirect routes.

### Dependencies

- Ruby >= 3.0, Rails >= 7.0 < 9.0
- `sprockets-rails >= 3.4`, `babel-transpiler ~> 0.7`
- Dev: `rubocop ~> 1.80`, `rubocop-rails ~> 2.33`
