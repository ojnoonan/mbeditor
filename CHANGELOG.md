# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
