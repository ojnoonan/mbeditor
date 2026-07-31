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

> **Pairing crosses the localhost-only boundary by design.** Realtime collaborative
> editing (see [Collaborative pairing](#collaborative-pairing-optional)) is meant to
> be reached by a second person, so it necessarily exposes the editor beyond your own
> machine. Treat that as an explicit, deliberate exception to the rules above — confine
> exposure to a trusted tunnel or LAN, set an authentication hook, and tear it down when
> you finish pairing. It does not change the core rule: mbeditor is development-only and
> must never be reachable by untrusted users.

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

  # JavaScript intelligence (see the "JavaScript intelligence" section below)
  # config.js_program = false                                        # disable the source program entirely
  # config.js_program_exclude = %w[vendor app/assets/javascripts/react]  # third-party/generated JS

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
| `search_respect_gitignore` | `true` | Project search and definition lookups skip files ignored by `.gitignore`, matching VS Code and ripgrep. Set to `false` to search ignored files too — expect it to be slow without ripgrep installed, since git then has to walk `node_modules`, `public/packs`, build output and caches. |
| `ripgrep_command` | `nil` | Path to the `rg` binary. `nil` auto-resolves: `PATH` first, then the usual install prefixes (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, linuxbrew, cargo). Set this if ripgrep lives somewhere unusual. See [Search performance](#search-performance). |
| `js_global_identifiers` | `[]` | Extra JS names declared as ambient globals in the editor — for runtime-only globals the static workspace scan can't see (e.g. `%w[Routes I18n]`). |
| `js_program` | `true` | Load the workspace's own JS source into Monaco's TypeScript program, so cross-file references get real inferred types instead of ambient `any`. See [JavaScript intelligence](#javascript-intelligence). `false` falls back to ambient declarations alone. |
| `js_program_exclude` | `%w[vendor]` | Directories excluded from that program, on top of `excluded_paths`. Point this at any third-party or generated JS — vendored libraries are UMD-wrapped, so their source costs parse time and contributes no globals. |
| `js_syntax_check` | `:auto` | Save-time babel parse check for JS/JSX using the host's `mini_racer` + babel-standalone (auto-detected; no-op when either is absent). `false` disables. |
| `babel_standalone_path` | `nil` | Explicit path to the babel-standalone bundle for the syntax check; `nil` looks up `babel.min.js`/`babel.js` in the host's asset pipeline. |
| `ruby_lsp` | `:auto` | Use the host's [ruby-lsp](https://github.com/Shopify/ruby-lsp) for Ruby go-to-definition (with peek), find-references, hover, completion, diagnostics, document symbols, folding, formatting, signature help, smart-select, and constant rename when it's installed (a persistent process is managed per workspace). `false` disables. Without ruby-lsp everything degrades to the built-in grep/Ripper services — no behavior change. Adding `ruby-lsp-rails` to your Gemfile needs no configuration here: ruby-lsp loads it as an addon and its Rails-aware results come through automatically. |
| `ruby_lsp_command` | `nil` | Override the ruby-lsp launch command (String or Array). `nil` auto-resolves `bin/ruby-lsp` → installed gem → `bundle exec ruby-lsp`. |
| `ruby_lsp_timeout` | `3` | Seconds per LSP request; on timeout (e.g. during initial indexing) the editor falls back to the built-in services for that request. |
| `model_graph` | *(no setting)* | The Models sidebar tab draws an entity diagram of your ActiveRecord models and their associations, read by reflection when the tab is opened. Pan by dragging, zoom by scrolling, click a model for its schema. Also writes `tmp/mbeditor_model_graph.mmd`, a Mermaid ER diagram that GitHub and VS Code render natively. Needs no configuration; apps without ActiveRecord simply see a message. |
| `exception_capture` | `:auto` | Record exceptions raised by your controllers and list them in the Problems panel, with clickable backtrace frames. Development only; backtraces are trimmed to frames inside the workspace. `false` disables. Note exception messages can include request params — the same exposure the log panel already has. |

### Authentication

| Option | Default | Description |
|--------|---------|-------------|
| `authenticate_with` | `nil` | Proc run as a `before_action` in all engine controllers. Executed via `instance_exec` inside the controller, so it has access to `session`, `cookies`, `redirect_to`, and auth-library class methods (e.g. Authlogic's `UserSession.find`) — but not helper methods from the host's `ApplicationController`. The same hook is also evaluated when the collaboration / editor **WebSocket** subscribes (see [Collaborative pairing](#collaborative-pairing-optional)); if it halts or raises, that subscription is rejected (fail-closed). Over the cable the proc runs against a request-derived probe, so request-scoped state may be narrower than over HTTP. |
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

### Collaboration

| Option | Default | Description |
|--------|---------|-------------|
| `user_name_callback` | `nil` | Proc resolving the display name shown on your caret during realtime collaboration. Executed via `instance_exec` inside the controller (like `authenticate_with`), so it can read `session`, `cookies`, `current_user`, etc. — e.g. `proc { current_user&.name }`. When `nil` or it returns a blank value, each browser falls back to a generated, locally-persisted, user-editable name. Collaboration activates once another participant actually connects, not merely when Action Cable is up (see [Collaborative pairing](#collaborative-pairing-optional)). |

## JavaScript intelligence

Under Sprockets every JS file shares one global scope, with no imports. The
editor models that in two layers.

**1. The source program.** Your workspace's own JS is loaded into Monaco's
TypeScript program. A JS file with no `import`/`export` is a TypeScript
*script*, so its top-level declarations land in the global scope — which is
exactly the Sprockets model. You get real inferred types across files:

```jsx
// app/assets/javascripts/ux/Card.jsx
var Card = function (props) { return <div>{props.title}</div>; };
function formatCents(value) { return "$" + (value / 100).toFixed(2); }
```

```jsx
// somewhere else — no import needed
var c = <Card title="x" />;      // Card: (props: any) => JSX.Element
var s = formatCents(500);        // formatCents(value: any): string
var t = formatCents(1, 2);       // Expected 0-1 arguments, but got 2
```

Unknown names still report `Cannot find name` — this adds type information, it
doesn't silence errors.

**2. Ambient declarations**, for names the program can't supply.

Both layers are needed, because TypeScript only sees *lexical* declarations:

- `window.Foo = ...` is a runtime global TypeScript does not treat as a
  declaration at all.
- UMD-wrapped libraries — React, lodash, axios — assign their global inside a
  closure, `factory(global.React = {})`, which TypeScript cannot follow
  statically. **Loading their source gets you nothing**, which is why
  `js_program_exclude` defaults to `vendor` and why React is typed by a
  bundled stub instead.

So point `js_program_exclude` at directories of third-party or generated JS,
and leave your own application code in:

```ruby
config.js_program_exclude = %w[vendor app/assets/javascripts/react]
```

### Cost

Measured against the Monaco TypeScript worker:

| program size | build | per file opened after |
|---|---|---|
| 1 MB | 210 ms | 9 ms |
| 3 MB | 378 ms | 11 ms |
| 5.5 MB | 443 ms | 23 ms |
| 9.4 MB | 872 ms | 32 ms |

Roughly 93 ms/MB, paid once per session. JS gzips about 4.5:1, so a 10 MB tree
is ~2.2 MB over the wire — worth knowing if your app runs on a remote host.
After the initial load only changed files are re-sent, never the whole tree.

Nothing is truncated silently: the browser console logs the file count, total
size, and every skipped file with a reason (minified, oversized, unreadable).
Minified bundles are skipped by filename and by shape, since they cost parse
time and declare only one-letter names inside a closure.

Set `config.js_program = false` to disable the layer entirely.

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

### Realtime via Action Cable (Optional)

Mbeditor works without Action Cable. If Action Cable is unavailable, unreachable, or returns transient errors, the editor automatically falls back to polling.

To enable realtime features in a host app:

1. Ensure Action Cable is enabled in the host app (for apps that do not load it by default, add the framework/gem explicitly).
2. Mount cable in host routes:

```ruby
mount ActionCable.server => '/cable'
```

3. Make Action Cable JavaScript available to the page (for asset-pipeline apps, `actioncable.js` is typically sufficient).

If any of these are missing, mbeditor still runs in polling mode.

### Collaborative pairing (Optional)

When Action Cable is available, mbeditor supports **realtime collaborative editing** —
live cursors and content sync over a WebSocket, so a second person can join the same
files. This is the one feature intended to be reached from another machine, so exposing
it is a **deliberate exception** to the localhost-only [Security Warning](#security-warning)
above. Expose it narrowly and only while you are actively pairing.

Collaboration activates only once **another participant is actually connected**, not
merely because Action Cable is up. On your own the editor behaves exactly as it does
without cable — persistent undo history and external-change detection stay in force,
both of which defer to the shared document while a session is live.

**1. Restrict the network exposure to a trusted path.**
Put the editor behind a **trusted tunnel** (e.g. an authenticated `ngrok`/Tailscale/
Cloudflare tunnel, or SSH port-forward) or keep it on a **trusted LAN**. Never bind it to
a public interface or an untrusted network. The person you pair with is the only one who
should be able to reach the port.

**2. Set an authentication hook — it runs on the WebSocket handshake.**
Configure `authenticate_with` (see the [Authentication](#authentication) options).
The same hook that gates the HTTP editor is now also evaluated when the collaboration /
editor WebSocket subscribes: if it halts (e.g. `redirect_to`/`render`/`head`) — or raises —
the socket subscription is **rejected (fail-closed)**, so pairing cannot bypass your auth.

```ruby
Mbeditor.configure do |c|
  # Runs as a controller before_action AND on the cable subscribe.
  c.authenticate_with = proc { head :forbidden unless UserSession.find }
end
```

Because the cable mount can bypass parts of the host middleware stack, a hook that leans on
request-scoped state (full `session`, encrypted `cookies`) may see less over the WebSocket
than it does over HTTP. For defence in depth, also authenticate at your host app's
`ApplicationCable::Connection` (the standard `identified_by` / `reject_unauthorized_connection`
pattern) — mbeditor's hook is an additional gate, not a replacement for securing the cable
connection itself.

**3. Configure Action Cable allowed request origins.**
Action Cable rejects cross-origin WebSocket connections. When you reach the editor through a
tunnel or LAN host, that origin must be allowed, or the socket silently fails and pairing
falls back to single-user mode. Allow exactly the origin(s) you pair through — never `/.*/`:

```ruby
# config/environments/development.rb
config.action_cable.allowed_request_origins = [
  "https://your-pairing-tunnel.example.com",
  %r{https://.*\.trusted-lan\.local}
]
```

When you finish pairing, close the tunnel / stop the forward so the editor is local-only again.

**4. Run a single web process.**
The shared document buffer is held in process memory and relayed over Action Cable's
default in-process (`async`) adapter, so collaboration state is **per-process**. If your
server runs multiple workers (e.g. Puma with `workers > 0` / `WEB_CONCURRENCY`), two
browsers can land on different workers and each see an empty or stale document — the most
common cause of *"the other person's edits never show up."* For pairing, run a single
worker (`WEB_CONCURRENCY=0`, or `bundle exec rails server` which is single-process by
default). A multi-worker setup would additionally need a cross-process cable adapter, but
the in-memory buffer still would not be shared — single-process is the supported mode.
## Search performance

Project search and JS definition lookups pick a backend per call:
**ripgrep → `git grep` → `grep`**. ripgrep is 10–30× faster than the fallbacks,
so installing it is the single biggest thing you can do for search speed:

```bash
brew install ripgrep      # macOS
apt install ripgrep       # Debian/Ubuntu
```

`GET /mbeditor/workspace` reports `searchBackend` (`"rg"`, `"git"` or `"grep"`)
so you can check which tier is actually in use. Two things commonly make it
`"git"` when you expected `"rg"`:

- **ripgrep isn't on the server process's `PATH`.** A Rails server started from
  launchd, systemd, foreman or an IDE inherits a stripped `PATH` that often
  omits `/opt/homebrew/bin`. Mbeditor probes the usual install prefixes as well
  as `PATH`; if yours is elsewhere, set `config.ripgrep_command`.
- **ripgrep genuinely isn't installed.** The `git grep` tier is then used. It
  honours `excluded_paths` and `.gitignore`, so it stays usable — but it is
  still far slower than ripgrep on a large workspace.

If search is slow, check `searchBackend` first, then confirm your build output
(`public/packs`, `app/assets/builds`, bundler/npm caches) is either gitignored
or listed in `excluded_paths`. Setting `search_respect_gitignore = false` makes
git walk every ignored tree and will be slow without ripgrep.

## Asset Pipeline

Mbeditor requires **Sprockets** (`sprockets-rails >= 3.4`). Host apps using **Propshaft** as their asset pipeline are not supported — the engine depends on Sprockets directives to load its JavaScript and CSS assets.

## Development

A minimal dummy Rails app is included for local development and testing:

```bash
cd test/dummy && rails server
```

Then visit http://localhost:3000/mbeditor.

### Vendored JavaScript (no consumer build step)

All third-party JS is **prebuilt and committed** under `vendor/assets/javascripts/`
and served as-is by Sprockets. Installing the gem needs **zero JS tooling** — no
Node, npm, or bundler — which is the contract recorded in
[ADR-0001](docs/adr/0001-no-frontend-build-step.md). `package.json` exists only as
a dependency manifest for `npm audit`.

Most vendored libs are committed verbatim from npm. The one exception is the
collaborative-editing bundle, `vendor/assets/javascripts/yjs-collab.js`, which
combines Yjs + y-monaco + y-protocols (awareness) into a single IIFE exposing
`window.Y`, `window.MonacoBinding`, and `window.awarenessProtocol`. It is produced
by a **maintainer-only** build script. Monaco itself is not bundled — the binding
forwards to the page's runtime `window.monaco`.

To regenerate it after bumping any of those pinned versions in `package.json`:

```bash
npm install          # installs yjs / y-monaco / y-protocols + esbuild (maintainer-only)
npm run build:yjs    # === node script/build-yjs-bundle.mjs
```

then commit the regenerated `vendor/assets/javascripts/yjs-collab.js`. The build is
deterministic: rebuilding from the same pinned versions reproduces identical bytes.
This step is for maintainers only; it never runs on a consumer's machine.

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
