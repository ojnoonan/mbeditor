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
gem "mbeditor", group: :development
```

If you prefer tracking the GitHub repo directly before a RubyGems release:

```ruby
gem "mbeditor", git: "https://github.com/ojnoonan/mbeditor.git", group: :development
```

Then mount the engine in host app routes:

```ruby
mount Mbeditor::Engine, at: "/mbeditor"

# Monaco asset redirects (required for the editor worker)
get "monaco_worker.js",   to: redirect("/mbeditor/monaco_worker.js")
get "monaco-editor/*asset_path", to: redirect("/mbeditor/monaco-editor/%{asset_path}"), format: false
```

## Host Requirements
The gem keeps host/tooling responsibilities in the host app:
- `rubocop` and `rubocop-rails` gems (optional, required for lint/format endpoints)
- `git` installed in environment (for Git panel data)

Everything else is intended to be packaged in the gem.

Monaco runtime assets are served from the engine route namespace (`/mbeditor/monaco-editor/*` and `/mbeditor/monaco_worker.js`).
For local development, the controller falls back to host `public/monaco-editor` and `public/monaco_worker.js` if packaged engine assets are not present yet.
If a requested Monaco runtime file is still missing, mbeditor can redirect to the configured Monaco CDN base.

## Configuration
Configure environments/workspace root in an initializer:

```ruby
MBEditor.configure do |config|
  config.allowed_environments = [:development]
  # config.workspace_root = Rails.root

  # Paths to exclude from the file browser (default shown below)
  config.excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]

  # RuboCop command used for inline linting (default: "rubocop")
  # Use "bundle exec rubocop" if RuboCop is managed via Bundler
  config.rubocop_command = "bundle exec rubocop"

  # Optional Monaco CDN fallback for missing local runtime files
  # Set to nil to disable fallback
  # config.monaco_cdn_base = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2"
end
```

## Development

A minimal dummy Rails app is included for local development and testing:

```bash
cd test/dummy && rails server
```

Then visit http://localhost:3000/mbeditor.

## Notes
- The engine is intended for development-time use.
- RuboCop is intentionally not a runtime dependency of the gem; it is discovered from host app environment.
