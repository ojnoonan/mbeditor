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

4. Create `config/initializers/mbeditor.rb` using the configuration options below.

5. Boot your app and open `/mbeditor`.

## Configuration

Use a single initializer to set the engine options you need:

```ruby
MBEditor.configure do |config|
  config.allowed_environments = [:development]
  # config.workspace_root = Rails.root
  config.excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
  config.rubocop_command = "bundle exec rubocop"

  # Optional Redmine integration
  # config.redmine_enabled = true
  # config.redmine_url = "https://redmine.example.com/"
  # config.redmine_api_key = "optional_api_key_override"
end
```

Available options:

- `allowed_environments` controls which Rails environments can access the engine. Default: `[:development]`.
- `workspace_root` sets the root directory exposed by Mbeditor. Default: `Rails.root` from the host app.
- `excluded_paths` hides files and directories from the tree and path-based operations. Entries without `/` match names anywhere in the workspace path; entries with `/` match relative paths and their descendants. Default: `%w[.git tmp log node_modules .bundle coverage vendor/bundle]`.
- `rubocop_command` sets the command used for inline Ruby linting and formatting. Default: `"rubocop"`.
- `redmine_enabled` enables issue lookup integration. Default: `false`.
- `redmine_url` sets the Redmine base URL. Required when `redmine_enabled` is `true`.
- `redmine_api_key` sets the Redmine API key. Required when `redmine_enabled` is `true`.

## Host Requirements (Optional)
The gem keeps host/tooling responsibilities in the host app:
- `rubocop` and `rubocop-rails` gems (optional, required for Ruby lint/format endpoints)
- `haml_lint` gem (optional, required for HAML lint — add to your app's Gemfile if needed)
- `git` installed in environment (for Git panel data)

All lint tools are auto-detected at startup. The engine gracefully disables lint features if the tools are not available. Neither `rubocop` nor `haml_lint` are runtime dependencies of the gem itself — they are discovered from the host app's environment.

### Syntax Highlighting Support
Monaco runtime assets are served from the engine route namespace (`/mbeditor/monaco-editor/*` and `/mbeditor/monaco_worker.js`).
The gem includes syntax highlighting for common Rails and React development file types:

**Web & Template Languages:**
- **Ruby** (.rb, Gemfile, gemspec, Rakefile)
- **HTML** 
- **ERB** (.html.erb, .erb) — Handlebars-based template syntax
- **HAML** (.haml) — plaintext syntax highlighting (no dedicated HAML grammar in Monaco; haml-lint provides inline error markers when available)
- **CSS** and **SCSS** stylesheets

**JavaScript & React:**
- **JavaScript** (.js, .jsx)
- **TypeScript** for JSX with full language server support

**Configuration & Documentation:**
- **YAML** (.yml, .yaml)
- **Markdown** (.md)

These language modules are packaged locally with the gem for true offline operation. No network fallback is needed—all highlighting works without internet connectivity.

## Development

A minimal dummy Rails app is included for local development and testing:

```bash
cd test/dummy && rails server
```

Then visit http://localhost:3000/mbeditor.

## Testing

The test suite uses Minitest via the dummy Rails app. Run all tests from the project root:

```bash
bundle exec rake test
```

Run a single test file:

```bash
bundle exec ruby -Itest test/controllers/mbeditor/editors_controller_test.rb
```

Run a single test by name:

```bash
bundle exec ruby -Itest test/controllers/mbeditor/editors_controller_test.rb -n test_ping_returns_ok
```
