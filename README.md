# mbeditor

Mbeditor (Mini Browser Editor) is a mountable Rails engine that adds a browser-based editor UI to a Rails app.

## Features
- Two-pane tabbed editor with drag-to-move tabs
- File tree and project search
- Git panel with working tree changes, unpushed file changes, and branch commit titles
- Optional RuboCop lint and format endpoints (uses host app RuboCop)

## Installation
Add to the host app Gemfile:

```ruby
gem "mbeditor", path: "../mbeditor"
```

Then mount the engine in host app routes:

```ruby
mount Mbeditor::Engine, at: "/mbeditor"
```

## Host Requirements
The gem keeps host/tooling responsibilities in the host app:
- `rubocop` and `rubocop-rails` gems (optional, required for lint/format endpoints)
- `git` installed in environment (for Git panel data)
- Monaco assets served at `/monaco-editor` and `/monaco_worker.js`

## Configuration
Configure environments/workspace root in an initializer:

```ruby
Mbeditor.configure do |config|
  config.allowed_environments = [:development]
  # config.workspace_root = Rails.root
end
```

## Notes
- The engine is intended for development-time use.
- RuboCop is intentionally not a runtime dependency of the gem; it is discovered from host app environment.
