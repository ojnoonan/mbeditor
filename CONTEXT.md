# CONTEXT.md — mbeditor domain glossary

Canonical vocabulary for mbeditor (the browser code editor Rails engine). Use these
terms in issues, PRDs, refactor proposals, and test names; don't drift to synonyms.

Architecture/refactoring vocabulary (module, seam, depth, deletion test) lives in the
weekly architecture-review docs under `docs/`, not here — this file is the *domain*.

## Glossary

### Workspace
The root directory mbeditor edits, resolved from configuration. Every file path resolves
under it via `resolve_path` (symlink-safe, 5 MB cap). Paths are spoken of as
workspace-relative unless stated otherwise.

### Buffer
The in-memory contents of a file as the editor currently holds them — may differ from the
file on disk. Linting and formatting operate on the buffer (passed as `code`), not the
saved file.

### Diagnostic
A single linter finding in mbeditor's neutral vocabulary, independent of any editor
front-end: `severity` (`:error`, `:warning`, `:info`), `message`, `line`, `column`,
`end_line`, `end_column`, and — for rubocop — `cop_name` and `correctable`. The Monaco
front-end's marker shape (`startLine`, `copName`, …) is a presentation mapping of a
Diagnostic, applied at the controller edge — never inside the service that produces it.

### LintService
The single module that owns mbeditor's linting toolchain: rubocop (diagnostics via
`--stdin`; autocorrect via a workspace-local tempfile so rubocop's config discovery finds
the host app's `.rubocop.yml`) and haml-lint (diagnostics only). It produces Diagnostics,
autocorrect text-edits, and formatted content, running every subprocess through
`ProcessRunner`. The "Format" action on Ruby files is rubocop autocorrect returning full
content — it is part of LintService, not a separate formatter. (Client-side Prettier for
JS/CSS/HTML/Markdown is a separate, browser-only path and is not part of LintService.)

### Language plugin
A front-end module that contributes editor behaviour for one or more languages, satisfying
a fixed interface: `appliesTo(language)`, `registerGlobal(monaco)` (one-time provider/config
registration), and `attach(editor, model, language)` (per-instance listeners, returns a
disposable). The plugins — `RubyPlugin`, `HtmlPlugin`, `JsPlugin`, `GenericPlugin` — are
named explicitly by the **editor-feature registrar** (`editor_plugins.js`), which fans the
two lifecycle phases across them. `appliesTo` is many-to-many: a `.jsx` editor is attached by
both JsPlugin and HtmlPlugin (JSX tag auto-close). No build step — each plugin is a plain
object on `window`, wired in a fixed order via Sprockets `//= require`.

### Resilient routing
The capability that keeps mbeditor reachable when the host app's `config/routes.rb` is
**broken** — distinct from a **failed boot**, which it cannot recover from (the engine's
initializers never run, so nothing falls back). On by default
(`config.resilient_routing`, the escape hatch when `false`). Built from three collaborators:
the **route map**, the **private route set**, and the **ResilientRouter** middleware, with
the **mount path** resolving where to serve.

### Route map
The single source of truth for the engine's routes (`Mbeditor::ROUTE_MAP`, a `proc`). Both
the engine's own route set and the private route set draw from it, so the two can never
drift apart.

### Private route set
An isolated `ActionDispatch::Routing::RouteSet` built from the route map at boot and
deliberately **never registered with the host's route reloader**. When a bad route draw
makes the reloader wipe every set it knows about, this one is unknown to it and survives —
so mbeditor stays dispatchable while the host table is broken.

### ResilientRouter
The Rack middleware that serves mbeditor's traffic from the private route set. It sits above
`ActionDispatch::Reloader` so a mount-prefix-matching request is dispatched before any route
reload can raise; non-matching requests pass through untouched. It rewrites the matched
request to mirror a mounted engine (prefix moved from `PATH_INFO` to `SCRIPT_NAME`) and wraps
the private set in the host's own cookies/session/flash so session-based `authenticate_with`
still works.

### Mount path
The active URL prefix mbeditor serves from, resolved (never by reading the live route table,
which is wiped at break-time) through a chain: explicit `config.mount_path` → the cached
value **detected from the last healthy route load** → the `/mbeditor` default. Detection only
ever updates from a healthy load, so a broken reload can never overwrite a good prefix — which
is why a custom mount works with zero configuration.
