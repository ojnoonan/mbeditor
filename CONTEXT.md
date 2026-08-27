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
A single linter finding, in the Monaco marker shape (`startLine`, `startCol`, `endLine`,
`endCol`, `severity`, `message`, and — for rubocop — `copName`/`correctable`). Both
Diagnostic-producing modules (`LspDiagnosticsTranslator` for ruby-lsp, `LintService` for
plain rubocop/haml-lint) emit this shape directly rather than a separate neutral
representation later mapped at the controller edge — there is only ever one shape, so
there is nothing to keep in sync between a neutral form and its presentation.

### LintService
The single module that owns mbeditor's linting toolchain: rubocop (diagnostics via
`--stdin`; autocorrect via a workspace-local tempfile so rubocop's config discovery finds
the host app's `.rubocop.yml`) and haml-lint (diagnostics only). It produces Diagnostics,
autocorrect text-edits, and formatted content, running every subprocess through
`ProcessRunner`. The "Format" action on Ruby files is rubocop autocorrect returning full
content — it is part of LintService, not a separate formatter. (Client-side Prettier for
JS/CSS/HTML/Markdown is a separate, browser-only path and is not part of LintService.)
`compute_text_edit` (the original-vs-corrected diff that becomes a Monaco
`SingleEditOperation`) and `rubocop_config_path` (a `.rubocop.yml`-presence check for the
`/workspace` payload) stay controller-private — neither is diagnostics, autocorrect, or
formatted content.

### Language plugin
`editor_plugins.js` splits into two lifecycle phases, neither of which is a per-language
object — there is no `RubyPlugin`/`HtmlPlugin`/`JsPlugin` on `window`, and nothing declares
an `appliesTo(language)`. **One-time registration** is `registerGlobalExtensions(monaco)`, a
dispatcher (guarded so it runs once) over three named functions grouped by provider
affinity rather than by language: `registerJsProviders`, `registerRubyProviders`, and
`registerGenericProviders` (features registered once across several languages at once —
linked editing, the `file://` opener, Prettier formatting, vim fold markers). **Per-instance
attach** is `attachEditorFeatures(editor, language)`, one function taking a `language`
string and returning a disposable; it does its own per-call branching (e.g. ERB/HAML markup
auto-close applies regardless of language, JSX-specific behaviour checks `language` itself)
rather than being fanned out across language objects. No build step — plain functions in one
file, wired via Sprockets `//= require`.

### Log viewer
The read-only, real-time view of the active environment's Rails log. It tails
`Rails.root/log/<env>.log` through `LogTailService` — an offset-based incremental
reader that returns only complete lines and detects rotation/truncation (an offset
past EOF resets to the file start). The same service feeds two transports: `LogsController#tail`
(HTTP, used for the initial load and as the polling fallback) and `EditorChannel`
(`start_log_tail`/`stop_log_tail` actions plus a `periodically` push over ActionCable).
The drawer renders raw log lines with **no redaction** by design — logs are shown
verbatim and may contain secrets, so the viewer relies on the host app's auth gate
like every other editor route.

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
