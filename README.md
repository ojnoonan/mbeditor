# mbeditor

Mbeditor (Mini Browser Editor) is a mountable Rails engine that adds a browser-based editor UI to a Rails app.

## Features
- Two-pane tabbed editor with drag-to-move tabs
- File tree and project search
- Git panel with working tree changes, unpushed file changes, and branch commit titles
- Optional RuboCop lint and format endpoints (uses host app RuboCop)

## Security Warning
Mbeditor exposes read and write access to your Rails application directory over HTTP. It is intended only for local development.

- Never install mbeditor in production or staging.
- Never run it on infrastructure accessible to untrusted users.
- Always keep it in the development group in your Gemfile.
- The engine enforces environment restrictions at runtime, and Gemfile scoping is a second line of defense that keeps the gem out of deploy builds.

## Installation
1. Add the gem to the host app Gemfile in development only:

```ruby
gem 'mbeditor', group: :development
```

2. Install dependencies:

```bash
bundle install
```

3. Mount the engine in host app routes:

```ruby
mount Mbeditor::Engine, at: "/mbeditor"
```

4. Configure mbeditor in an initializer (for example `config/initializers/mbeditor.rb`):

```ruby
MBEditor.configure do |config|
  config.allowed_environments = [:development]
  # config.workspace_root = Rails.root
  config.excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
  config.rubocop_command = "bundle exec rubocop"
end
```

5. Boot your app and open `/mbeditor`.

## Host Requirements (Optional)
The gem keeps host/tooling responsibilities in the host app:
- `rubocop` and `rubocop-rails` gems (optional, required for lint/format endpoints)
- `git` installed in environment (for Git panel data)

Everything else is intended to be packaged in the gem.

Monaco runtime assets are served from the engine route namespace (`/mbeditor/monaco-editor/*` and `/mbeditor/monaco_worker.js`).
For local development, the controller falls back to host `public/monaco-editor` and `public/monaco_worker.js` if packaged engine assets are not present yet.
If a requested Monaco runtime file is still missing, mbeditor returns 404.

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
