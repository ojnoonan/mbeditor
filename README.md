# mbeditor

[![Gem Version](https://badge.fury.io/rb/mbeditor.svg)](https://rubygems.org/gems/mbeditor)
[![Test](https://github.com/ojnoonan/mbeditor/actions/workflows/test.yml/badge.svg)](https://github.com/ojnoonan/mbeditor/actions/workflows/test.yml)

Mbeditor (Mini Browser Editor) is a mountable Rails engine that adds a browser-based editor UI to a Rails app.

## Features
- Two-pane tabbed editor with drag-to-move tabs
- File tree and project search
- Git panel with working tree changes, unpushed file changes, and branch commit titles
- Line numbers tinted by git status — green for added lines, orange for modified, red where lines were removed
- Problems panel with error/warning counts in the status bar, listing every diagnostic across the open files
- Outline dropdown for Ruby (methods, and test/spec structure in test files) and for JS/JSX/TS
- Colour-coded Rails log drawer
- Optional RuboCop lint and format endpoints (uses host app RuboCop)
- Optional Ruby language-server integration (definitions, hover, completion, diagnostics)
- Optional test runner with inline failure markers and a dedicated results panel (Minitest and RSpec)

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
Mbeditor.configure do |config|
  config.allowed_environments = [:development]
  # config.workspace_root = Rails.root
  config.excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
  config.rubocop_command = "bundle exec rubocop"

  # Optional authentication (runs as a before_action in the engine controllers)
  # config.authenticate_with = proc { redirect_to login_path unless UserSession.find }

  # Optional test runner (Minitest or RSpec)
  # config.test_framework = :minitest   # :minitest or :rspec — auto-detected when nil
  # config.test_command   = "bundle exec rails test"  # defaults to bin/rails test or bundle exec ruby -Itest
  # config.test_timeout   = 60

  # Optional Redmine integration
  # config.redmine_enabled = true
  # config.redmine_url = "https://redmine.example.com/"
  # config.redmine_api_key = "optional_api_key_override"
  # config.redmine_ticket_source = :commit  # :commit (scan recent commit messages for #123) or :branch (leading digits of branch name)

  # Optional Ruby/Rails side panel tuning
  # config.ruby_def_include_dirs = %w[app/models app/controllers app/helpers app/concerns]
  # config.related_files_custom_paths = %w[app/assets/javascripts/app app/policies]

  # Resilient routing (see the "Resilient Routing" section below)
  # config.mount_path = "/mbeditor"   # explicit prefix override; auto-detected when nil
  # config.resilient_routing = false  # escape hatch; true keeps the editor up when host routes break
end
```

### Core

| Option | Default | Description |
|--------|---------|-------------|
| `allowed_environments` | `[:development]` | Rails environments allowed to access the engine. |
| `workspace_root` | `Rails.root` | Root directory exposed by Mbeditor. |
| `excluded_paths` | `%w[.git tmp log node_modules .bundle coverage vendor/bundle public/assets storage]` | Files/directories hidden from the tree and path operations. Entries without `/` match a name anywhere in the path; entries with `/` match relative paths and their descendants. |
| `rubocop_command` | `"rubocop"` | Command used for inline Ruby linting and formatting. |
| `git_timeout` | `10` | Seconds each git subprocess may run; a timed-out call degrades its own field of the git panel instead of failing the request. `nil` disables the bound. |
| `search_timeout` | `15` | Wall-clock bound on project-search subprocesses; a tripped deadline returns the partial results collected so far. `nil` disables. |
| `search_respect_gitignore` | `false` | When `true`, project search and definition lookups skip files ignored by `.gitignore`. The default searches them, matching the editor's "show me everything on disk" behaviour. |
| `js_global_identifiers` | `[]` | Extra JS names declared as ambient globals in the editor — for runtime-only globals the static workspace scan can't see (e.g. `%w[Routes I18n]`). |
| `js_syntax_check` | `:auto` | Save-time babel parse check for JS/JSX using the host's `mini_racer` + babel-standalone (auto-detected; no-op when either is absent). `false` disables. |
| `babel_standalone_path` | `nil` | Explicit path to the babel-standalone bundle for the syntax check; `nil` looks up `babel.min.js`/`babel.js` in the host's asset pipeline. |
| `ruby_lsp` | `:auto` | Use the host's [ruby-lsp](https://github.com/Shopify/ruby-lsp) for Ruby go-to-definition, hover, completion, and diagnostics when it's installed (a persistent process is managed per workspace). `false` disables. Without ruby-lsp everything degrades to the built-in grep/Ripper services — no behavior change. |
| `ruby_lsp_command` | `nil` | Override the ruby-lsp launch command (String or Array). `nil` auto-resolves `bin/ruby-lsp` → installed gem → `bundle exec ruby-lsp`. |
| `ruby_lsp_timeout` | `3` | Seconds per LSP request; on timeout (e.g. during initial indexing) the editor falls back to the built-in services for that request. |

### Authentication

| Option | Default | Description |
|--------|---------|-------------|
| `authenticate_with` | `nil` | Proc run as a `before_action` in all engine controllers. Executed via `instance_exec` inside the controller, so it has access to `session`, `cookies`, `redirect_to`, and auth-library class methods (e.g. Authlogic's `UserSession.find`) — but not helper methods from the host's `ApplicationController`. |
| `authentication_cache_ttl` | `0` | Seconds to cache the auth result in the session (`0` = no caching). Set e.g. `300` to avoid calling `authenticate_with` on every request when the proc is expensive. Trade-off: after host logout, mbeditor stays accessible for up to TTL seconds. |

### Test runner

| Option | Default | Description |
|--------|---------|-------------|
| `test_framework` | `nil` | `:minitest` or `:rspec`. Auto-detected from file suffix, `.rspec`, or `test`/`spec` directory when `nil`. |
| `test_command` | `nil` | Full command used to run a test file. When `nil`, picks `bin/rails test` (Minitest) or `bin/rspec` / `bundle exec rspec` (RSpec). |
| `test_timeout` | `60` | Maximum seconds a test run may take before being killed. |

### Redmine

| Option | Default | Description |
|--------|---------|-------------|
| `redmine_enabled` | `false` | Enables issue-lookup integration. |
| `redmine_url` | — | Redmine base URL. Required when `redmine_enabled` is `true`. |
| `redmine_api_key` | — | Redmine API key. Required when `redmine_enabled` is `true`. |
| `redmine_ticket_source` | `:commit` | How the current ticket is identified. `:commit` scans the 100 most recent branch commits for a `#123` reference; `:branch` reads leading digits from the branch name (e.g. `123-my-feature` → ticket 123). |

### Ruby/Rails side panel

| Option | Default | Description |
|--------|---------|-------------|
| `ruby_def_include_dirs` | `%w[app/models app/controllers app/helpers app/concerns]` | Workspace-relative directories searched when resolving Ruby go-to-definition jumps. Add any extra dirs holding Ruby source you want indexed. |
| `related_files_custom_paths` | `[]` | Extra base directories for the Rails related-files side panel. For each entry the panel looks for a subdirectory named after the current resource (plural or singular). E.g. `"app/assets/javascripts/app"` surfaces `app/assets/javascripts/app/users/` when editing a `users` resource. |

### Resilient routing

See [Resilient Routing](#resilient-routing) for details.

| Option | Default | Description |
|--------|---------|-------------|
| `mount_path` | `nil` | Explicit URL prefix to serve resilient routing from. When `nil`, auto-detected from your `mount Mbeditor::Engine, at: "..."` line on every healthy boot. Set only to override detection. |
| `resilient_routing` | `true` | Keeps mbeditor reachable when the host's `config/routes.rb` is broken, by serving its traffic from middleware that dispatches to a private route set. Set to `false` as an escape hatch: no middleware is inserted and the private set is never built. |

## Test Runner

The Test button appears in the editor toolbar for any `.rb` file when a `test/` or `spec/` directory exists in the workspace root. Clicking it:

1. Resolves the active source file to its matching test file using standard Rails conventions (`app/models/user.rb` → `test/models/user_test.rb`). If the open file is already a test file, it runs that file directly.
2. Runs the test file using the configured command in a subprocess with a timeout.
3. Shows a **Test Results** panel with pass/fail counts, per-test status icons, and error messages.
4. Optionally overlays inline failure markers in the Monaco editor (separate from RuboCop markers — the two never interfere). Use the marker icon in the panel header to toggle them.

**Running a single test.** With a test file open, `Ctrl+Shift+T` (or *Run Test
at Cursor* in the editor context menu) runs only the test enclosing the cursor.
The filter syntax follows the detected framework — `path:line` for RSpec and
`bin/rails test`, a `-n` name filter for the plain Minitest runner — so it works
with a custom `test_command` too. If the cursor isn't inside a test, or the open
file is a source file rather than its test, the whole file runs as usual.

**Framework auto-detection order:**
1. File suffix: `_spec.rb` → RSpec, `_test.rb` → Minitest
2. `.rspec` file present → RSpec
3. `spec/` directory present → RSpec
4. `test/` directory present → Minitest

**Default commands** (when `test_command` is not set):
- Minitest: `bin/rails test <file>` if `bin/rails` exists, otherwise `bundle exec ruby -Itest <file>`
- RSpec: `bin/rspec <file>` if `bin/rspec` exists, otherwise `bundle exec rspec --format json <file>`

## Resilient Routing

A broken `config/routes.rb` normally takes down the whole app — every request, including the one you'd use to fix it, raises while Rails tries to reload the route table. Mbeditor stays reachable anyway: it serves its own traffic from middleware that dispatches to a **private route set** built at boot and never registered with Rails' route reloader. When a bad route draw wipes the host route table, that private set survives the wipe, so `/mbeditor` keeps working while the rest of the app is down. This is on by default (`resilient_routing = true`); you don't need to configure anything.

**Custom mount paths work with zero configuration.** On every healthy boot, mbeditor detects the prefix from your `mount Mbeditor::Engine, at: "..."` line and remembers it. If the route table later breaks, the remembered prefix is used — so resilient routing serves from your custom mount, not just `/mbeditor`. Detection only ever updates from a *healthy* load, so a broken reload can never overwrite a good prefix. Set `config.mount_path` only if you want to override detection explicitly.

**What it cannot recover from: a host app that fails to *boot*.** Resilient routing relies on mbeditor's engine initializers running — that's when the middleware is inserted and the private route set is built. If the app can't boot at all, those initializers never run and there is nothing to fall back to. This includes:

- a syntax error or raised exception in `config/application.rb` or other engine/initializer code,
- a broken initializer in `config/initializers/`,
- a bad or incompatible gem that fails to load.

A *broken route* is recoverable in the browser; a *failed boot* is not. If the app won't boot, fix it from a terminal — mbeditor can't help until the app can start.

**Turning it off.** Set `config.resilient_routing = false` as an escape hatch (e.g. to debug a middleware-ordering conflict). With the flag off, no mbeditor middleware is inserted and the private route set is never built; mbeditor is then served only through the normal mount and shares the fate of a broken `config/routes.rb`.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+P` | Quick-open file by name |
| `Ctrl+S` | Save the active file |
| `Ctrl+Shift+S` | Save all dirty files |
| `Alt+Shift+F` | Format the active file |
| `Ctrl+Shift+G` | Toggle the git panel |
| `Ctrl+Shift+T` | Run only the test under the cursor |
| `Ctrl+Z` / `Ctrl+Y` | Undo / Redo (Monaco built-in) |

## Host Requirements (Optional)
The gem keeps host/tooling responsibilities in the host app:
- `rubocop` and `rubocop-rails` gems (optional, required for Ruby lint/format endpoints)
- `haml_lint` gem (optional, required for HAML lint — add to your app's Gemfile if needed)
- `git` installed in environment (for Git panel data)
- `minitest` or `rspec` in the host app's bundle (required for the test runner)
- `actioncable` framework/gem (optional, required only for realtime file-change push + websocket state saves)
- `ruby-lsp` gem (optional — see below)

All lint and test tools are auto-detected at runtime. The engine gracefully disables features if the tools are not available. Neither `rubocop`, `haml_lint`, nor any test framework are runtime dependencies of the gem itself — they are discovered from the host app's environment.


## Asset Pipeline

Mbeditor requires **Sprockets** (`sprockets-rails >= 3.4`). Host apps using **Propshaft** as their asset pipeline are not supported — the engine depends on Sprockets directives to load its JavaScript and CSS assets.

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
