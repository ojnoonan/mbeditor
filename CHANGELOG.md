# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Paste re-indents instead of reformatting.** Pasting ran the pasted range
  through Prettier, which reprinted the whole enclosing statement — and for a
  paste that filled the document, every line of it — so pasting a snippet
  rewrote code you never touched. Paste now only re-indents to the file's
  indentation setting; quotes, semicolons and spacing come through exactly as
  copied. The setting is renamed "Format on paste" → "Indent on paste"
  (`indentOnPaste`, still on by default). Monaco ships no indentation rules for
  JavaScript, which would have made the re-indent a silent no-op there, so
  VS Code's JS rules are now registered. Format-on-save is unchanged and still
  off by default.

### Fixed
- **Go-to-definition on a JS symbol defined in the same file opened a junk tab
  named after a number.** Models are created without an explicit URI, so Monaco
  identifies each as `inmemory://model/N`; the TS worker returns that URI for
  an in-file definition, and the editor opener stripped it to a path and opened
  a phantom tab called "57". Only `file://` resources are treated as workspace
  files now — the rest go back to Monaco, which reveals the position in the
  current editor.
- **Search results ignored created and deleted files.** Only saves dropped the
  client-side search cache, so a search re-run after adding or removing a file
  was served the stale cached page. Every structural mutation now invalidates
  it and re-runs the active query.
- **Search and the git status counts lagged behind file changes.** The
  live-result refresh sat behind a 2 s debounce (now 250 ms), and every save
  fired the full `/git_info` fan-out — the most expensive request the editor
  makes — twice over, once directly and once from the broadcast handler, which
  on a dev server with a few threads queued the tree and search requests behind
  it. Saves and file mutations now use the cheap `/git_status` probe, which
  patches the branch and file list immediately and escalates to the fan-out
  itself only when the branch actually changed.

## [0.12.8] - 2026-08-07

### Added
- **Untitled scratch tabs.** The tab bar's "+" now opens an in-memory
  `Untitled-N` buffer (VS Code-style) instead of prompting to create a file on
  disk. Nothing is written anywhere until you save, at which point a save-as
  prompt asks for a workspace-relative path and the tab converts to a real
  file. Scratch tabs are skipped by Save All (each needs its own prompt) and
  are not persisted across reloads.

### Fixed
- **"was updated externally" fired after your own saves.** A successful save
  never refreshed the external-change baseline (the save-time grace window
  skipped the very fetch that would have), so once you edited the file again,
  the next save of *any* file compared new disk content against the stale
  pre-save baseline and raised the banner. Saves now update the baseline
  directly, the check re-reads live tab state instead of a snapshot taken
  before its fetch, and — since the files_changed push only ever announces
  mbeditor's own writes — the push-triggered check is now scoped to the pushed
  paths instead of re-fetching every open tab on every save. The manual
  Refresh Workspace button still checks everything.
- **Virtual tabs no longer poll git.** Changelog/untitled/diff tabs were
  fetching git line-diff every 10 s and git/file history on focus — guaranteed
  no-ops, now skipped, along with persistent-undo tracking for paths that have
  no file behind them.
- **git-tier search returned nothing, instantly, on hosts with older git.** The
  exclusion pathspecs added in 0.12.6 produced a pathspec list of nothing but
  `:(exclude)` entries. Newer git reads that as "everything except these";
  older git refuses it ("fatal: There is nothing to exclude from"), exits 128,
  and — with stderr discarded — search silently returned empty. The list is
  now anchored with a `.` pathspec, which every git version accepts.

### Added
- **Babel-based scope lint for JS/JSX, surfaced as warnings on save.** On top
  of the existing babel syntax check (host mini_racer + babel-standalone), the
  saved file is now traversed for identifier references that bind to nothing:
  not to any scope in the file, not to a top-level declaration in any other
  workspace JS file (Sprockets concatenates them into one scope), not to a
  known `window.X` global, and not to the browser/React/hook names. Each one
  gets a warning marker — `'name' is not defined in any reachable scope` — in
  the editor and Problems panel. Also warns on bindings that are only assigned
  inside a `useEffect`/`useLayoutEffect` callback but read during render
  (undefined on first render). Report-only; `config.js_scope_lint = false`
  disables it. Requires a babel-standalone new enough to expose
  `Babel.packages` (7.9+); older bundles degrade to the syntax check alone.

## [0.12.7] - 2026-08-06

### Fixed
- **Project search was 10-80x slower than terminal grep on hosts without
  ripgrep.** grep's `--exclude-dir` only accepts plain directory names, so the
  slashed default exclusions (`vendor/bundle`, `public/assets`) never reached
  the command line and grep walked those trees in full on every search, with
  the matches discarded in Ruby afterwards. The grep tier now prunes every
  exclusion with `find` — slashed paths included — and feeds the survivors to
  grep in parallel batches (`xargs -P`), measured 7.2 s → 0.09 s on a 350 MB
  tree with a realistic `vendor/bundle`, 3-4x faster than a plain terminal
  `grep -r`. The same fix applies to `CodeSearchService`, which backs the JS
  definition/global lookups and was reading precompiled `public/assets`
  bundles on every "Cannot find name" the editor reported.
- **A search query starting with `-` was parsed as grep options.** Queries now
  pass through `-e … --` on the grep tier.
- **Superseding a search now kills the whole pipeline.** The subprocess is
  spawned in its own process group and the TERM goes to the group, so a
  stacked keystroke cannot leave a find/grep pipeline running behind the
  shell.
- **`vendor/cache` is excluded from search by default.** `bundle install
  --local` keeps every `.gem` archive there — gigabytes of binary files search
  has no business opening.

## [0.12.6] - 2026-08-05

### Added
- **Format All.** A second toolbar button formats every open document. Each tab
  is formatted independently and failures are collected rather than thrown, so
  one unparseable file cannot stop the rest; the status line reports how many
  were formatted, skipped and failed.
- **Format on paste actually formats.** `formatOnPaste` has been on by default
  for a long time and did nothing outside Ruby: Monaco acts on a paste only
  through a *range* formatting provider, and none was registered. Prettier-backed
  range and document providers now cover JS/JSX, JSON, CSS/SCSS/LESS, HTML and
  Markdown. A paste that fills the document is formatted as a document — so
  pasting into a blank file formats the whole thing — while a paste in the middle
  is formatted as a range, reprinting the smallest enclosing statement and
  leaving the rest of the file byte-identical. Code copied in from a spaces
  project therefore lands as tabs (or the reverse), which was previously a manual
  chore that never converted cleanly.
- **Files symlinked in from outside the workspace now open.** An app that links a
  shared config directory or a sibling engine into its tree could see those files
  in the explorer but not open them — the tab opened and closed itself a moment
  later. Symlinks are now followed the way a file manager does. Containment is
  still enforced: `File.expand_path` collapses `..` before a lexical check
  against the workspace root, so no request can name anything outside it, and
  git operations stay strictly inside the repo.

### Fixed
- **Search returned nothing, instantly, on some workspaces without ripgrep.** The
  git-grep tier was chosen on the mere presence of a `.git` entry, with no check
  that git could actually open the repo. When it cannot — dubious ownership under
  Docker, a `.git` file pointing at a gitdir that moved, no git binary on the
  server's `PATH` — `git grep` fails, its stderr goes to `/dev/null`, and the
  result is an empty set indistinguishable from "no matches". The tier is now
  gated on `git rev-parse --is-inside-work-tree`, which fails in exactly those
  cases, so a bad repo falls through to plain grep. Definition lookups had the
  same check and were silently broken the same way.
- **Formatting ignored the tab/space setting.** There were four copies of the
  Prettier options and they had drifted: two read a `prettierTabWidth` /
  `prettierUseTabs` pair that no settings screen ever wrote, frozen at two
  spaces, overriding the `tabSize` / `insertSpaces` actually configured. A JSX
  file in a tabs workspace came back space-indented. Indentation now comes from
  the same preferences Monaco itself is given.
- **One JS file had two formatters that disagreed.** Monaco's TypeScript worker
  registers its own range formatter for `javascript` and Monaco uses whichever it
  finds first, so the toolbar button went through Prettier while `Shift+Alt+F`
  and format-on-paste got the worker's two-space, no-semicolon output. The
  worker's formatting is switched off; its completions, hovers, diagnostics and
  rename are untouched.
- **"Server offline" flashed during ordinary actions.** The reachability check
  counted any error without a response as a network failure, and a request the
  editor aborts itself has none either. The editor cancels constantly — each
  keystroke supersedes the previous search, hover and completion providers abort
  when the cursor moves on, opening a file aborts its own prefetch — so two in a
  row declared the server offline until the `/ping` probe a second later put it
  back. Creating a file reliably triggered it. Cancellations are now ignored; a
  genuinely unreachable host still marks offline and still recovers.
- **Warnings logged by the host app from mbeditor's own hooks were swallowed.**
  Editor requests were silenced at `ERROR`, which hides Rails' own INFO-level
  request lines but also everything a host app logs from inside
  `authenticate_with` or `user_name_callback` — those procs run within the
  request, so a developer debugging their own hook saw nothing and had no way to
  know why. Silenced at `WARN` now, which still hides the request lines.

### Changed
- RuboCop's output is taken as-is. Ruby indentation belongs to the project's
  `.rubocop.yml`, so rewriting it in the editor fought the linter about to run
  over the same file. The previous code converted the source to tabs *before*
  handing it to RuboCop, which discarded it. To convert an already-open file,
  use Monaco's built-in "Convert Indentation to Tabs / to Spaces" (F1).

## [0.12.5] - 2026-08-03

### Fixed
- **The cable took up to 30 seconds to reconnect.** The retry was a flat 30s
  interval, and because a disconnect tears the consumer down, Action Cable's own
  much faster reconnection monitor was discarded with it. Any transient blip or
  dev-server restart therefore cost half a minute with no cable at all: no
  presence, no collaboration, no file-change push. Replaced with a jittered
  backoff from 1s to a 8s ceiling, reset on a successful connect. Measured
  against a real server restart: **2.8 seconds** from the server answering again
  to the cable being back, where the flat interval could take the full 30.
- **Collaboration broadcasts flooded the development log.** The Action Cable log
  filter matched `Mbeditor::` and `mbeditor_editor`, but a broadcast line names
  only the stream — `Broadcasting to mbeditor_collab:…` — so every keystroke and
  cursor move was logged with the base64 CRDT payload inlined.
- **The browser console filled with failed requests when the server became
  unreachable.** A dropped VPN, a closed lid or a stopped server left the file
  tree polling every 10s, git status every 5s and the git line tint every 10s,
  all failing forever — and the browser logs every failed request itself, which
  no amount of JavaScript can suppress. The only fix is to stop making them.

  Background polls are now skipped before the request is issued once two
  consecutive *network-level* failures have been seen (an HTTP error does not
  count — a 500 proves the server is there), and a single probe on a 1s→30s
  backoff decides when it is back. Requests you initiate are never blocked; they
  fail fast with a real error rather than hanging until the 30s timeout.
  Measured with the server down: two failed requests, then silence, instead of
  an unbounded stream.

## [0.12.4] - 2026-08-03

### Fixed
- **Rejected-subscription logging flooded the console.** 0.12.3 made a silent
  failure visible, which was right, but logged every occurrence — and a
  rejection is not a one-off: the client retries every 30 seconds, every open
  tab retries independently, and both the editor channel and every per-file
  collaboration room authenticate. One message per distinct reason per five
  minutes now, which says the same thing without drowning the log.

## [0.12.3] - 2026-08-03

### Added
- **`config.cable_authenticate_with`** — authentication for the collaboration
  WebSocket, falling back to `authenticate_with` when unset.
- **A "Pairing off" chip and diagnostics panel.** When collaboration cannot
  work, the editor now says so and lists every condition it depends on — the
  vendored libraries, Action Cable's JavaScript, whether the server advertises
  it, whether the socket actually connected, and whether anyone else is here —
  with the fix written beside each failure. Nothing is shown when everything is
  healthy and you are simply alone.

### Fixed
- **A WebSocket subscribe runs no controller, and this made pairing silently
  impossible for most authenticated apps.** `authenticate_with` is evaluated on
  the cable against a probe exposing `session`, `cookies`, `request` and
  `params` — so a hook reading `Current.user`, calling `UserSession.find`, or
  using a memoised `current_user` gets `nil` or a `NameError`, denies, and the
  socket is rejected. The hook keeps working perfectly over HTTP, so nothing
  looks wrong; collaboration simply never connects.

  Rejections are now logged as `[mbeditor] WebSocket subscription rejected: …`
  naming the cause, `cable_authenticate_with` provides an escape hatch when one
  proc cannot serve both contexts, and the README says this plainly instead of
  noting that request-scoped state "may be narrower". The README's own example
  used `UserSession.find`, which is exactly the pattern that cannot work.

## [0.12.2] - 2026-08-03

### Added
- **Inline route hints in controllers.** Every action in a controller file is
  annotated with the verb and path that reach it — `GET /orders/:id` beside
  `def show` — and a public action nothing routes to is flagged `no route`.
  Hovering adds the named-route helper. Answering "is this actually reachable?"
  previously meant reading `config/routes.rb` and expanding `resources` in your
  head.

  Routes come from the host app's own route set rather than by parsing
  `config/routes.rb`. mbeditor runs inside the app, so the routes are already
  built — and they are the only source that accounts for `resources` expansion,
  `member`/`collection` blocks, scopes, constraints and mounted engines.

- **`config.model_graph_max_models`** (default 1000, was a hard-coded 300).
  A schema over the cap silently lost models and only said "(truncated)".

### Changed
- **Model boxes are sized to their contents** rather than all being one width,
  so a long model or column name is no longer truncated while a model called
  `Tag` wastes most of its box. Layer positions accumulate per layer, since a
  fixed stride would let a wide box overlap the next layer.
- **Cluster blocks are packed in two dimensions** instead of stacked in a single
  column, which left a schema with one big core and several small islands
  running off the bottom with the right-hand side empty.
- **The dummy app now carries a real ActiveRecord schema** — 20 models and 44
  associations covering a hub, a chain, a self-reference, a join table, a
  polymorphic association and unconnected islands — so the model graph can be
  demonstrated and tested against something representative.

### Fixed
- **mbeditor could stop a host app from booting.** The pending-migrations
  middleware was installed whenever `ActiveRecord::Migration::CheckPending` was
  defined, but Rails only puts that middleware in the stack when
  `config.active_record.migration_error` is `:page_load`. Any app loading
  ActiveRecord with a different setting raised "No such middleware to insert
  before" during boot. It now tests the same condition Rails does.
- **Long labels drew straight out past the edge of their model box.** SVG text
  neither wraps nor ellipsises; labels are now measured against the font the
  theme actually resolves and cut to fit.
- **"no database connection" hung below the box it belonged to** — the box
  height did not count that placeholder line.
- **The model search is a real dropdown.** The native `<datalist>` rendered in
  the browser's own chrome: unstyleable, and unable to show the table name and
  column count beside each model. Arrow keys and Enter work as before.
- **The titlebar wrapped to two lines in a narrow window**, pushing the toolbar
  out of its 32px row. It no longer wraps, and below the width where the toolbar
  drops its button labels the title gives way to the icon alone.

## [0.12.1] - 2026-08-03

### Added
- **The collaboration name now comes from the signed-in user automatically.**
  Previously it required a `user_name_callback`; with none set the editor fell
  straight through to a generated name like "Witty Operator" even on an
  authenticated instance. When no callback is configured, the name is now read
  off `current_user`, trying `name`, `full_name`, `display_name`, `username`,
  `login` and `email` in order. New `config.user_name_methods` names your own
  column instead — `%w[preferred_name]` — so the common case no longer needs a
  callback at all. An explicit `user_name_callback` still wins.

  This works when your auth library exposes `current_user` to an
  `ActionController::Base` subclass, which Devise and Sorcery do. A
  `current_user` written by hand on your own `ApplicationController` is **not**
  reachable — the engine's controllers do not inherit from it — so that case
  still needs a callback reading `session` directly.

### Changed
- **The model graph is laid out by dependency, not by traversal order.** It now
  uses the Sugiyama layered method — break cycles, layer by longest path, cut
  crossings with the median heuristic, then straighten — which is what Graphviz
  `dot`, and so Rails ERD, uses for this picture. The previous radial layout
  became one enormous circle on a real schema, fitted so far out that no box was
  legible. A model's position now tells you something: depth reads left to
  right, and each connected part of the schema is drawn as its own area.

- **Your own presence chip only appears once someone else is connected.** Action
  Cable is up in any normal dev setup, so it used to sit in the toolbar
  permanently announcing a session of one.

### Fixed
- **The model graph was unusable on a large schema.** On 300 models and 513
  associations a single zoom tick cost 27 ms; it is now 0.2 ms. Three causes,
  all compounding: the entire layout ran on every render, the pan/zoom transform
  sat in the render output so each tick rebuilt ~7,000 SVG elements, and the
  wheel handler read `getBoundingClientRect()` per tick, forcing a synchronous
  reflow of the whole scene.
- **Fit-to-pane produced a zoom the controls refused to honour.** It clamped to
  `min(1, ...)` but not to the minimum zoom, so a large graph fitted at ~0.04
  against a 0.2 floor — and the first scroll snapped up to the floor, a fivefold
  jump anchored on the cursor that looked like the diagram leaping somewhere
  random. The floor is now low enough to frame a few hundred models, and the fit
  clamps to the same range the wheel enforces. Opening the tab also no longer
  leaves the graph unfitted when the pane has not been sized yet.
- **Hovering a model now shows what its associations actually are** — macro,
  name, direction and `through:` — and dims every unrelated edge, which is the
  only way to follow one model's relationships among hundreds of lines.
- **Clicking a model zooms to it** instead of opening its schema; the schema is
  an explicit button in the model's header, so navigating no longer throws a
  modal at you.
- **The model-graph search field drew its text over a magnifier icon.** The icon
  comes from the vendored Pico stylesheet, whose selector outranks a plain class
  rule — disabling the browser's own `type="search"` decorations did not touch
  it.
- **A failing `user_name_callback` was swallowed silently.** Any exception
  returned a bare `nil`, which made a broken callback indistinguishable from an
  unconfigured one: you got the generated name and no clue why. The usual cause
  is a `NameError` on a `current_user` the engine cannot see. It is now logged
  as `[mbeditor] user name lookup failed: ...` and still never breaks the
  request.

## [0.12.0] - 2026-07-31

### Added
- **Realtime collaborative editing (pair programming).** When Action Cable is
  available, two or more people can open the same file and edit it together —
  content converges through a Yjs CRDT, with live remote carets, selections and
  a coloured name label per participant. Undo is scoped to your own edits, so
  Ctrl+Z can never revert your partner's work. Joining late is safe: the shared
  document wins over the copy on disk, and one save on any side settles the file
  for everyone.

  Participants appear as chips in the toolbar. A solid dot means they are in the
  file you are looking at, a hollow ring means they are elsewhere (with their
  filename beside it, when the toolbar is showing labels). Hovering gives their
  name, current file and measured cable latency; clicking follows them, so their
  file and scroll position track yours. Past three participants the chips
  collapse to colour dots so the toolbar cannot overflow. Colours are assigned
  against the live roster rather than hashed from the name, so two people never
  share one while a free colour exists.

  Collaboration only activates once someone else is actually connected — on your
  own, the editor behaves exactly as before, keeping persistent undo history and
  external-change detection.

  **This is the one feature intended to be reached from another machine**, so it
  is a deliberate exception to mbeditor's localhost-only posture. Read the
  [Collaborative pairing](README.md#collaborative-pairing-optional) section
  before exposing it: put it behind a trusted tunnel, set `authenticate_with`
  (now also evaluated on the WebSocket handshake, fail-closed), restrict
  `action_cable.allowed_request_origins`, and run a single web process. New
  `user_name_callback` config resolves the display name from your host app.

- **Drag files and folders from your desktop straight into the explorer.**
  Drop onto a folder row to import there, or onto the empty space below the
  tree to import into the workspace root. Folders are imported recursively.
  Any file type works — binary content round-trips byte for byte. When a
  target path already exists, a dialog offers Overwrite all, Keep both (which
  writes `name 2.ext` beside the original), or Skip. Imports are capped at 100
  files and 50 MB per drop, and 5 MB per file, and every target path goes
  through the same sandbox checks as every other file operation.

- **A model graph — an entity diagram of the host app's ActiveRecord models.**
  The activity-bar button opens it as a full-width editor tab, drawing each
  model with its fields. Search centres the view on a model; hovering an edge
  names the relation. (Released with a radial layout; replaced by a layered one
  in the next version — see Unreleased.)

  Associations are read by **reflection, not by parsing model files**. mbeditor
  runs inside the host app, so `reflect_on_all_associations` is right there and
  resolves `class_name:`, `through:`, polymorphic and inverse sides correctly —
  all of which regex or AST parsing of `has_many` lines silently gets wrong.
  The graph never touches the database connection, so it works against a
  database that isn't running or migrated. It is built only when the tab is
  opened (it eager-loads the host app) and cached on a fingerprint of
  `app/models` and `db/migrate`, so saving a model invalidates it. It also
  writes `tmp/mbeditor_model_graph.mmd`, a Mermaid `erDiagram` that GitHub and
  VS Code render natively.

- **Ruby navigation through real Monaco providers.** Go-to-definition was
  hand-wired per editor with an `onMouseDown` and an `addAction`, so Monaco
  never knew Ruby had definitions and peek-definition, Ctrl+hover previews and
  the references widget all did nothing. Definition, references, document
  symbols, folding, highlights, rename, formatting, signature help and
  selection ranges are now registered providers, fed by a raw ruby-lsp
  passthrough instead of a bespoke translator per method.

  - **F2 renames a Ruby constant across the workspace.** Open files get their
    edits back for Monaco to apply, so the change is undoable and marks the tab
    dirty; closed files are written server-side. That split is what keeps
    unsaved work safe — anything dirty is by definition open.
  - **Shift+Alt+F and format-on-save now work for Ruby.**
  - **RuboCop fixes apply straight from the diagnostic.** The edits are already
    in the diagnostics response, so the lightbulb no longer makes a second
    request or spawns a `rubocop -A` over the buffer on every click. "Disable
    <cop> for this line" comes from the same payload.
  - **Diagnostics are graded Error / Warning / Info / Hint** instead of
    everything non-error being one yellow warning, and unnecessary code is
    faded rather than squiggled. A status-bar chip shows ruby-lsp health.

- **Host-app exceptions appear in the Problems panel.** A failed request used to
  show up only in the log. Controller exceptions are now listed with clickable
  backtrace frames and pushed live over the existing cable channel. Backtraces
  are filtered to frames under the workspace root and capped, since absolute
  host paths are both a leak and unopenable. Development only, and
  `config.exception_capture = false` disables it.

- **PageUp/PageDown cycle between the cursor and the last jump origin.**
  Opening a file at a line — go-to-definition, a search result, a hover link —
  snapshots where you came from, and PageUp/PageDown swap between the two.
  Replaces the default page-scroll binding.

### Changed
- **Search is dramatically faster on host apps without ripgrep**, where it was
  effectively unusable. Three separate causes, all on the `git grep` tier:
  the exclusion list was computed and then never put on the command line, so
  git walked `node_modules` in full and the results were discarded afterwards;
  `search_respect_gitignore` defaulted to `false`, which asks git to search
  every ignored tree the app has; and `LC_ALL=C` was set, measured neutral for
  the default and 2.2× *slower* for regex. Measured 3714 files walked → 253.
  `search_respect_gitignore` now defaults to `true`, matching VS Code and
  ripgrep. `GET /workspace` reports `searchBackend` so the live tier is visible,
  and `ripgrep_command` now resolves the usual install prefixes as well as
  `PATH` — a server started from launchd, systemd or an IDE has a stripped
  `PATH`, which silently dropped search to the 10–30× slower tier.

- **Assignments to undeclared variables are reported as errors.** `foo = 1`
  with no declaration anywhere is an implicit global the host's Babel pipeline
  rejects, so it keeps Error severity with an explanatory hint. Read-side
  unknowns still downgrade to a warning, since those are usually host globals
  the language service cannot see.

### Fixed
- **The bottom drawers covered the code instead of making room for it.** The
  log and problems drawers were absolutely positioned, so they sat on top of
  what you were reading. They are now ordinary flow siblings of the split
  panes, so opening one shrinks the editor.
- **"Changes in Branch" showed nothing on a branch well ahead of the base.**
  With no base branch resolved it fell back to diffing against the branch's
  upstream — which for a feature branch is its own remote copy, reliably empty.
  Every layer then degraded to empty rather than erroring, so it looked like
  there were no changes.
- **The What's New tab was wiped by the session restore** when it opened on a
  version change.
- **An idle editor no longer re-renders.** Polls that found nothing changed were
  still writing fresh objects into state — the file tree every 10 s and the
  ruby-lsp health chip every 10 s — each costing a full reconciliation of a
  tree that had not changed. Verified by counting React renders over an idle
  minute: now zero.

## [0.11.0] - 2026-07-29

### Added
- **Real types for your own JavaScript, from your own JavaScript.** The
  workspace's JS source is now loaded into Monaco's TypeScript program instead
  of being grepped for names and declared as ambient `any`. Under Sprockets a
  JS file with no `import`/`export` is a TypeScript *script*, so its top-level
  declarations land in the global scope — which is exactly the Sprockets model.
  Cross-file references now get inferred signatures, member completion, and
  argument-count checking, and genuine unknowns still report `Cannot find
  name`:

  ```jsx
  var c = <Card title="x" />;   // Card: (props: any) => JSX.Element
  var s = formatCents(500);     // formatCents(value: any): string
  var t = formatCents(1, 2);    // Expected 0-1 arguments, but got 2
  ```

  Two new options: `config.js_program` (default `true`) and
  `config.js_program_exclude` (default `%w[vendor]`, added on top of
  `excluded_paths`). Measured at ~93 ms/MB to build and ~30 ms per file
  afterwards, so a ~10 MB tree costs under a second, once; only changed files
  are re-sent after that.

  Ambient declarations are still used for what a program cannot express.
  TypeScript only sees *lexical* declarations: `window.Foo = ...` is not a
  declaration to it, and UMD-wrapped libraries assign their global inside a
  closure — `factory(global.React = {})` — which it cannot follow statically.
  Their source contributes nothing, which is why vendored code is excluded by
  default and React stays typed by a bundled stub. Point
  `js_program_exclude` at any other third-party or generated JS.
- **A whitespace toggle in the status bar** (¶), showing tabs, spaces and
  hidden characters in the active editor.

### Fixed
- **The editor became very slow on JSX files with many unresolved names.**
  Opening such a file fired one `/js_definition` request per unknown symbol,
  in parallel — each spawning an `rg` process — and called `addExtraLib` once
  per resolution, re-validating every open model each time. A file with a
  thousand warnings meant a thousand greps saturating the dev server and a
  thousand full TypeScript re-validations. That starved the file-tree poll,
  git status, and saves behind it. Lookups are now serialized and capped, and
  the declaration updates are coalesced into a single flush.
- **Minified bundles crowded out the workspace's real globals.** A minified
  file is one enormous line that usually opens with `var a,b,c,…` running to
  thousands of declarators; split on commas, that single line exhausted the
  3000-symbol cap before the scan reached your own components, so every
  reference to them showed "Cannot find name". Declaring `a`/`n`/`t` as
  ambient `any` also silenced real diagnostics for those names everywhere.
  Minified files are now skipped by filename and by shape, and the endpoint
  reports `truncated` so a workspace that outgrows the cap is diagnosable
  instead of silently incomplete.
- **"File was edited externally" appeared for files nothing had touched.** The
  check compared the file on disk against the editor buffer — which differ for
  every unsaved tab by definition — so saving one file broadcast a change that
  flagged every *other* dirty tab. It now compares disk against the last disk
  content seen, so only a real on-disk change raises the banner.

---

## [0.10.1] - 2026-07-27

### Removed
- **The `listen`-based file watcher, and with it `config.watch_files`.**
  0.10.0 enabled a workspace watcher by default. On Linux each watched
  directory costs an inotify watch from `fs.inotify.max_user_watches`, a
  *per-user* budget shared with everything else watching files — including the
  host app's own code reloader and any other gem using `listen`. Exhausting it
  raises `iNotify max watches exceeded`, and because `listen` reports some of
  those failures from its own background thread, mbeditor could not even
  rescue them. Claiming a share of a scarce OS resource by default was the
  wrong trade for a development tool, and raising the limit needs root, which
  a developer may not have.

  Nothing is lost: external changes are picked up by polling, which is how the
  editor already tracked git state. If you set `config.watch_files`, remove it
  — it is now ignored.

### Fixed
- **The file tree never refreshed for changes made outside the editor.** Its
  10-second poll returned early whenever the Action Cable socket was connected,
  on the reasoning that the push covered it — but the server only broadcasts
  from mbeditor's own mutation endpoints. With a socket connected, which is the
  normal case, an external `git checkout` or generator run was never picked up.
  The poll now always runs; the push remains the instant path for our own
  writes. This is the bug the 0.10.0 watcher was compensating for.
- **Git line-number tinting went stale for external changes**, for the same
  reason, and its refresh timer was being cleared and recreated on every
  re-render so it never survived long enough to fire. It now polls on its own
  timer and on window focus, matching the file tree.
- **Watched paths were dropped when the workspace was reached through a
  symlink** (macOS `/var` → `/private/var`, or a symlinked checkout), because
  reported paths resolve to the real path and no longer matched the configured
  root.

---

## [0.10.0] - 2026-07-27

### Added
- **Git-status line numbers** — line numbers are tinted by what git thinks of
  the line: green for added, orange for modified, red on the line a deleted
  block sat after. Backed by a new `GET /mbeditor/git/line_diff` endpoint over
  `git diff -U0`, and never a reason to fail a file load: a missing HEAD or a
  non-repo simply leaves the numbers plain.
- **Problems panel** — error and warning counts in the status bar open a
  drawer listing every diagnostic across the open files, grouped by file with
  the offending source line and click-to-navigate. Counts cover the open tabs,
  which is where Monaco's markers live; RuboCop, ruby-lsp and the TypeScript
  worker all feed it through one subscription.
- **Outline for JS, JSX and TypeScript** — the Methods/Outline button now
  works in those files, translating the TypeScript worker's own navigation
  tree rather than adding a second lexer. Arrow functions and function
  expressions assigned to variables are listed; data constants, object-literal
  keys and anonymous callbacks are not.
- **Colour-coded Rails log** — the log drawer distinguishes request
  boundaries, controller dispatch, SQL, renders, redirects and failures, with
  `Completed` lines coloured by status code.
- **Optional workspace file watching** — with the host's
  [`listen`](https://github.com/guard/listen) gem, changes made outside the
  editor (a terminal `git checkout`, a generator, another editor) refresh the
  file tree and git decorations instead of going stale. Absent the gem,
  behaviour is unchanged. Configurable via `config.watch_files`.

### Fixed
- **ruby-lsp hover showed a dead link.** ruby-lsp renders its "Definitions"
  line as VS Code `file://` links, which Monaco draws as links but nothing in
  the browser can open, so clicking did nothing. In-workspace links are now
  rewritten to a Monaco command that opens the file at the line; gem and
  stdlib links, which the editor cannot open at all, degrade to plain code
  spans. The `/module_members` breakdown is also restored beneath a constant
  hover — ruby-lsp's constant hover never lists what the class or module
  defines, so taking its output wholesale had dropped it.
- **False-positive type errors in plain JS/JSX.** The editor kept a denylist
  of TypeScript diagnostic codes to suppress; it had grown to eight and still
  leaked (TS2322 on a spread carrying an extra prop). Untyped JS gives
  TypeScript nothing to check against, and which way it guesses is arbitrary —
  state seeded with `useState({})` errors on every key while the same object
  from `JSON.parse` stays silent. JS/JSX now keeps only the checks that are
  sound without annotations: syntax errors, `Cannot find name`, and unused
  locals. `.ts`/`.tsx` keeps full checking, where the types are hand-written.

### Changed
- The **Logs** button moved from the top toolbar to the status bar.
- **Quick-open ranks recently opened files** above the static file-type tier,
  so a file you were just in outranks a never-opened controller. Match quality
  still comes first, so a worse match cannot jump the queue.
- The title-bar search field now fills 75% of the space between the title and
  the toolbar buttons instead of a fixed 340px.
- Test-suite compatibility fixes carried over from the unreleased 0.9.1/0.9.2
  work: MiniRacer-dependent parser suites skip in minimal bundles, and the
  Outline system tests exercise navigation through click semantics.

---

## [0.9.0] - 2026-07-23

### Added
- **Test-aware Ruby Outline** — the editor now recognises Minitest and RSpec
  suites, tests, and helper methods in `_test.rb` and `_spec.rb` files. It
  reads the unsaved Monaco buffer, preserves nested suite depth and method
  visibility, supports keyboard navigation, and safely reports truncation or
  parser failures without disrupting the editor.
- **Ruby test-DSL highlighting** — Minitest/RSpec declarations, hooks, and
  helpers now receive structural Monaco tokens while Ruby files retain the
  existing `ruby` language identity and integrations.

### Security
- **Dangling symlink containment** — every editor and Git path check now
  rejects dangling symlinks that resolve outside the workspace or repository,
  closing a write-through escape for create, save, rename, and directory
  operations.
- **Filesystem-aware exclusions** — exclusion matching now normalizes Unicode
  spellings and folds case only on case-insensitive filesystems, preventing
  case or normalization variants from reaching excluded directories such as
  `.git`.

### Changed
- Generated `graphify-out/` artifacts are ignored by Git.

---

## [0.8.1] - 2026-07-22

### Fixed
- **ruby-lsp features never started on Ruby 3.0 and 3.1.** The client waited
  for responses with `Queue#pop(timeout:)`, which only accepts that keyword
  from Ruby 3.2 — so the initialize handshake raised on older rubies and every
  ruby-lsp request fell back to the built-in services. The gemspec supports
  Ruby >= 3.0; the wait now uses a portable path there. Both branches are
  covered by tests regardless of which Ruby runs the suite.
- The gem's own `mini_racer`/`ruby-lsp` development dependencies are gated on
  Ruby >= 3.2 — mini_racer's native extension fails to build on 3.0/3.1, which
  broke `bundle install` for contributors on those versions. Neither gem is
  needed by the suite.

---

## [0.8.0] - 2026-07-22

### Added
- **Ruby language-server integration (optional)** — when the host app has
  [ruby-lsp](https://github.com/Shopify/ruby-lsp) installed, go-to-definition,
  hover, completion, and diagnostics for Ruby are answered by a persistent
  ruby-lsp process (unsaved buffer contents included), with automatic fallback
  to the built-in grep/Ripper services on timeout, crash, or absence — hosts
  without ruby-lsp see no change. Adding `ruby-lsp-rails` alongside it needs no
  mbeditor configuration. New config: `ruby_lsp` (`:auto`/`false`),
  `ruby_lsp_command`, `ruby_lsp_timeout`.
- **Ruby diagnostics from ruby-lsp** — Ruby files are checked by the language
  server instead of booting RuboCop over HTTP on every debounce, adding Prism
  syntax errors and warnings alongside RuboCop offenses. Quick-fix lightbulbs
  still work for correctable cops; non-RuboCop diagnostics correctly get none.
- **Run the test under the cursor** — `Ctrl/Cmd+Shift+T`, or *Run Test at
  Cursor* in the editor context menu, runs only the enclosing test. The filter
  follows the detected framework (`path:line` for RSpec and `bin/rails test`, a
  `-n` name filter for the plain Minitest runner), so it works with a custom
  `test_command` too, and falls back to the whole file when the cursor isn't
  inside a test.
- **Ruby intellisense inside ERB** — hover, completion, go-to-definition, and
  auto-`end` now work inside `<% %>` tags in `.html.erb` views and stay inert in
  the surrounding HTML. ERB uses the built-in workspace services (ruby-lsp
  cannot parse ERB), and Rails view helpers are filtered out.
- **Workspace-wide JS ambient globals** (`GET /js_globals`) — every top-level
  `var`/`let`/`const`/`function`/`class` declaration and `window.X =` assignment
  across the workspace's JS-family files (incl. `.js.jsx`, `.js.erb`) is
  declared to Monaco's TypeScript worker in one shot, so cross-file component
  references in Sprockets/react-rails apps no longer show "Cannot find name" —
  no imports needed. Refreshes automatically on file changes. New
  `config.js_global_identifiers` declares runtime-only globals (e.g.
  `%w[Routes I18n]`).
- **Save-time babel syntax check for JS/JSX** — when the host app has
  `mini_racer` and a babel-standalone asset (the react-rails no-node setup),
  saving a `.js`/`.jsx` file runs the same babel transform the asset pipeline
  will, surfacing pipeline-breaking parse errors as editor markers.
  Auto-detected; `config.js_syntax_check = false` disables,
  `config.babel_standalone_path` overrides asset lookup.
- **Format on save** — new editor setting (off by default): saving runs RuboCop
  `-A` for Ruby or Prettier for JS/JSX/JSON/CSS/SCSS/HTML/Markdown before
  writing, and never blocks the save if the formatter fails.
- **RuboCop server mode** — lint/quick-fix/format use `rubocop --server` when
  the workspace's rubocop supports it (>= 1.31), cutting per-lint latency from
  seconds (cold boot per request) to ~100 ms. `config.rubocop_server = false`
  restores `--no-server`.
- **`git grep` search tier** — project search picks rg > `git grep`
  (multithreaded) > plain grep, so hosts without ripgrep get fast search instead
  of the slow grep fallback.
- **Live search results** — saving a file through mbeditor re-scans just that
  file and updates its rows in the open search panel in place.
- **`config.search_respect_gitignore`** (default `false`) — when enabled,
  project search and definition lookups skip `.gitignore`d files.
- **Inline color swatches + picker (all file types)** — color literals
  (`#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()`) show a
  clickable color square, opening Monaco's native color picker; choosing a color
  rewrites the literal in its original notation. The CSS family (css/scss/less)
  keeps Monaco's own built-in provider.
- **Title-bar search box** — a "Search files…" box opens quick-open (same as
  `Ctrl/Cmd+P`); its empty state lists recently opened files before Favourites
  and Recent Searches.
- **Tab context menu** — right-clicking an editor tab offers Close, Close
  Others, Close Saved, and Close All (alongside File History / Find in
  Explorer).
- **New-file button in the tab bar** — a `+` button after the last tab creates a
  new file in the active file's directory via the file-tree inline-create flow.
- **Rails log viewer** — a drag-resizable bottom-drawer panel (toggle via the
  status bar or `Ctrl+Shift+L`) that streams the active environment's
  `log/<env>.log` in real time over ActionCable, with an HTTP polling fallback.
  Includes a substring filter; height persists across sessions. Read-only.

### Changed
- **Search executes one subprocess per query** (previously two — the second, a
  full-workspace count scan, could not terminate early). The capped full result
  set is cached ~30 s, so pagination and total counts are served from memory; a
  new query kills the previous still-running search. New `config.search_timeout`
  (default 15 s) bounds every search subprocess. Case-insensitive grep runs
  under `LC_ALL=C` (10–50× faster on BSD grep; non-ASCII case folding is not
  attempted on the grep tier).
- **`config.git_timeout` now defaults to 10 seconds** (was unbounded). All git
  subprocesses in the info fan-out are individually bounded; a timed-out call
  blanks its own field instead of failing the payload. Set
  `config.git_timeout = nil` to restore unbounded behavior.
- **Git polling is two-tier** — the 5 s background poll hits the cheap
  `/git_status` (2 subprocesses) and only runs the full `/git_info` fan-out
  (~10 subprocesses) when the branch or working tree actually changed.
  `GitInfoService` gained single-flight computation and stale-while-error.
- **`formatOnType` is now off by default** — on-type formatting added
  per-keystroke latency on slower machines; enable it in editor settings.
  Format-on-paste and the explicit Format action are unchanged.
- **The Ruby definition cache is now bounded.** Entries carry each file's full
  source, and the whole cache was rewritten on every change, so a large
  workspace grew to tens of megabytes. Entries are LRU-ordered and trimmed to
  2000 before each persist.
- Default `excluded_paths` also covers `public/assets` and `storage`.
- Unavailable lint tools are re-probed every 60 s, so installing rubocop or
  ripgrep while the server is running is picked up without a restart.

### Fixed
- **ruby-lsp answered from stale buffers.** ruby-lsp supports only incremental
  document sync, so mbeditor's full-text change notification raised inside the
  server and left it holding the content from the first open — every hover,
  definition, and completion on an edited buffer used out-of-date text. Changed
  buffers are now re-opened, which is correct without computing incremental
  ranges.
- **JS go-to-definition picked nested functions over globals** — with two
  same-named functions (one top-level, one inside an IIFE/object), Ctrl+click
  navigated to whichever grep match came first. Top-level declarations
  (column 0, `window.X =`, `export`) now rank first, and clicking
  `SomeParent.myFunction` or a name in `const { myFunction } = SomeParent`
  resolves the parent's member definition directly. Hover follows the same
  rules, and nested matches no longer pollute the ambient-globals list.
- **JS definition lookups were silently broken on rg-less machines in git
  workspaces** — the search patterns used `(?:`, `\b`, and `\s`, which
  `git grep`'s POSIX ERE engine rejects or treats as literals, so the git-grep
  tier returned nothing. All patterns are now pure POSIX ERE.
- **Project search and definition lookups disagreed about `.gitignore`** —
  search ignored it while definition lookups honoured it. Both now follow
  `config.search_respect_gitignore`.
- **Ruby auto-`end` failed in the most common case** — typing a new
  `def`/`class`/`if` *above* an existing sibling block: the sibling's `end`
  (same indentation) was mistaken for the new block's, so Enter inserted no
  `end`. Same-indent code lines now correctly terminate the scan
  (`else`/`elsif`/`when`/`rescue`/`ensure` still continue it).
- Ruby auto-`end` could insert a tab into a spaces-indented file when Monaco's
  indentation auto-detection misreported the file; the opener line's own
  indentation style now wins.
- Search crashed with `ArgumentError: invalid byte sequence in UTF-8` when a
  match line contained invalid UTF-8 (subprocess output is now scrubbed).
- Search pagination's virtual-scroll loader called an undefined `basePath()`
  (latent `ReferenceError`) (#69).
- The CSRF Referer check used `URI#origin`, raising a 500 on Ruby 3.0.
- Corrupt branch-state JSON was discarded silently; `prune_branch_states` now
  logs it (#68), and `EditorChannel#save_branch_state` logs rejected invalid
  branch names (#74).
- `EditorChannel` spawned a `git rev-parse` subprocess on every WebSocket action
  (including every auto-save); the workspace root is now resolved once per
  process and shared with the controllers.
- The first go-to-definition after boot no longer blocks the request on a full
  workspace Ripper scan — the definition cache warms in a background thread on
  the first `/workspace` call.
- JS definition lookups' grep fallback scanned `node_modules` and vendor trees
  with no exclusions and no timeout.
- **Optional React props flagged as required** — Monaco's JS type-checking
  (`checkJs`) inferred every referenced prop of a plain-JS component as required
  and flagged call sites that omitted it (TS 2741/2739). Those false positives
  are now suppressed while genuinely useful checks remain.
- Tab bar's `+` (new file) button had a full-height, over-wide hover box; now a
  centred 24 px square matching other icon buttons.
- Title-bar "Search files…" box is now pill-shaped.
- Source-control panel buttons (`git-header-btn`, `git-action-btn`,
  `git-section-action-btn` — the latter two previously unstyled) now share the
  explorer panel's button geometry, radius, and hover treatment.

### Security
- **Origin/Referer validation for non-GET requests** (#75) — mutating requests
  are now checked against the request's own origin, closing the last gap left
  by the `X-Mbeditor-Client` header guard alone.
- **Symlink escape hardening** — the file tree no longer recurses into
  symlinked directories (#65), and `GitService.resolve_path` resolves symlinks
  before its containment check (#66), matching the guarantee `resolve_path`
  already made elsewhere.
- Bumped the bundled `form-data` dev dependency to 4.0.6 to clear a HIGH npm
  advisory.
- The log viewer displays log contents **verbatim**, which may include request
  params, tokens, or SQL values. It is read-only and gated by the host app's
  auth like every other editor route, but operators should be aware that logs
  can contain secrets.

---

## [0.7.5] - 2026-06-03

### Fixed
- **What's New tab restored blank** — `isChangelog` was stripped during periodic tab persistence (`MbeditorApp.js:1540`), so the changelog tab was restored without the flag on page reload. The pane rendered it as a normal file tab (Monaco) instead of `ChangelogView`. Added `isChangelog` to the serialized tab properties and patched `openChangelogTab` to set the flag on any restored tabs that lack it.

---

## [0.7.4] - 2026-06-03

### Fixed
- **Custom path reverse lookup (frontend)** — the v0.7.3 backend fix was complete, but the frontend's `resourceLabelFromPath` still returned `null` for paths under `app/` that weren't `controllers|models|views|helpers`, so custom paths like `app/assets/javascripts/…` were never recognized. Moved the custom-path check to the top of the function, matching the backend approach.

---

## [0.7.3] - 2026-06-03

### Fixed
- **Custom path reverse lookup (backend)** — moved the custom-path check in `extract_resource_names` before the `case` statement so paths under `app/assets/`, `app/javascript/`, etc. are handled. Stripped `_controller`/`_model`/`_helper`/`_service` suffixes from custom-path filenames for consistent label/grouping.
- **Schema modal `self.table_name` support** — reads `self.table_name` from the model file before falling back to `ActiveSupport::Inflector.tableize`, enabling custom table names.
- **Structure.sql broader schema-prefix regex** — handles quoted schemas, non-public schemas, and no prefix.
- **PostgreSQL type coverage** — expanded `sql_type_to_rails` with full PostgreSQL type coverage (timestamptz, double precision, citext, hstore, geometric types, etc.).
- **Schema read error handling** — broadened rescue in `try_schema_rb`/`try_structure_sql` to catch encoding errors.

---

## [0.7.2] - 2026-06-03

### Changed
- **Changelog entries backfilled** — added full release notes for 0.7.1 (persistent undo history, `db/structure.sql` schema support, Rails panel fixes) so the What's New panel shows accurate content on upgrade.
- **Release workflow documented** — `CLAUDE.md` now describes the release process so future releases can be triggered with a single instruction.

---

## [0.7.1] - 2026-06-03

### Added
- **Persistent undo history** — edit operations are captured in the browser and flushed to the server on save and tab close, then replayed the next time the file is opened. Undo/redo now reaches back further than the current session. Stale history is pruned automatically when old branches are cleaned up.
- **`db/structure.sql` schema support** — the model schema modal now reads `db/structure.sql` when `db/schema.rb` is absent (SQL-format migrations).

### Fixed
- **Rails panel long filenames** — long filenames in the Rails panel are now truncated correctly and custom-path entries populate reliably.
- **Schema lookup error logging** — failures to parse the schema file now emit a diagnostic log entry to aid debugging.

---

## [0.7.0] - 2026-05-21

### Added
- **Model schema modal** — click the table icon next to any resource in the Rails panel to view its database columns, types, constraints, and indexes parsed from `db/schema.rb`.
- **Changelog tab** — click the version number in the status bar to open a formatted changelog tab. Upgrades automatically open "What's New" on first boot after a version bump.
- **Rails panel: concerns** — model and controller concerns appear as a dedicated group in the Rails panel.
- **Rails panel: file kind labels** — each entry shows a dim label (Controller, Model, View, Test, Concern, Helper) on the right so you can distinguish files with similar names at a glance.
- **Rails panel: custom-path awareness** — files living outside the standard `app/` tree (configured via `related_files_custom_paths`) now show related files in the panel.
- **SQL/HTML heredoc highlighting** — Ruby heredocs with `<<~SQL`, `<<~HTML`, etc. tokenize their body with SQL/HTML keyword colours in the Monaco Monarch tokenizer.
- **Rake file syntax** — `.rake` files now use Ruby syntax highlighting.
- **Middle-click to close tab** — scroll-wheel click on any tab closes it (matching browser and VS Code behaviour).

### Fixed
- **Format button on Ruby files** — the Format button now correctly converts space-indented buffers to tabs before sending to RuboCop, so `Layout/IndentationStyle` offenses are fixed rather than silently ignored.
- **Hover highlight position** — hovering a JS/JSX global or component name now highlights the exact word under the cursor instead of text on a different line. The hover cache now stores only the popup contents and rebuilds the Monaco `Range` fresh per hover call so the same symbol on different lines highlights correctly.
- **`<MyComponent/>` hover** — components defined as `const MyComponent = () => {}` resolve correctly on hover; the JsDefinitionService grep pattern no longer uses `\s` inside character classes, which was silently failing under macOS BSD grep.
- **"Edited externally" false positives** — a `recentSavesRef` map suppresses external-edit warnings for 3 s after a successful save, preventing the warning triggered by the WebSocket `files_changed` broadcast that follows every save.
- **Branch detection race during save** — saving a file no longer triggers a false branch-switch (which was closing all tabs) by guarding the branch-change subscriber with `isSavingRef`.
- **File creation performance** — `GitInfoService.invalidate` is now called in a background thread so create-file and create-directory requests respond immediately.
- **Explorer type-ahead jump during rename/create** — global key-down handler returns early while a rename or create input is active.
- **Authlogic SHA512 console spam** — optional `authentication_cache_ttl` config (default 0 = disabled) caches successful authentication results in the session, reducing per-request auth lambda calls to at most once per TTL window.
- **Unused-method false positives in test files** — the unused-methods overlay is suppressed when the active file lives under `test/` or `spec/`.
- **JSX "defined twice" errors** — TS2300/TS2451 diagnostics are filtered out; they are structural false positives caused by Monaco treating all open JS files as a shared global script context.

### Changed
- **Dirty marker in Rails panel** now uses the same orange (`#e5c07b`) as the tab bar dirty dot.
- **Rails panel branch-switch UX** — tabs stay visible (read-only) during a branch switch instead of disappearing immediately; a `branch_state_restore` setting (default `true`) controls whether tab state is saved/restored across branch switches.

## Internal refactor (2026-05-23)

### Changed (no user-visible behavior change)
- **`AvailabilityProbe` extracted** — tool-availability checks (`rg`, `rubocop`, `haml_lint`, `git`, etc.) pulled out of `EditorsController` into `AvailabilityProbe`. Closes #22, #23, #24.
- **`FileTreeService` extracted** — directory-tree construction pulled out of `EditorsController` into `FileTreeService`. Closes #22, #23, #24.
- **`SearchReplaceService` extracted** — `rg`/`grep` detection, flag building, ReDoS guards, per-file timeout (`5 s`), size cap, encoding handling, and replace-in-files all unified in one service. `stream_search_results`, `count_search_results`, `RG_AVAILABLE`, and the inline 95-line `replace_in_files` action removed from the controller; replaced by thin delegators. Closes #25, #26, #27, #28.
- **`EditorStateService` extracted** — JSON state persistence (file locking, size limits, error handling) was duplicated between `EditorsController` and `EditorChannel`. Both protocol layers now delegate to `EditorStateService`; fixing a locking bug requires editing one file. Closes #29, #30, #31, #32.
- **`RubyDefinitionService` cache encapsulated** — `load_disk_cache_once`, `persist_cache`, `scan`, `file_cache`, and `mutex` removed from the public interface. `defs_in_file` and `includes_in_file` self-warm on cache miss; callers no longer need to manage lifecycle. Warmup hack in `UnusedMethodsService` removed. Closes #33, #34, #35, #36.
- **`GitCommitDetailService` and `GitCombinedDiffService` extracted** — the two `GitController` actions that contained raw `Open3.capture3` calls (`commit_detail`, `combined_diff`) are now thin delegators. No `EditorsController` action contains subprocess logic. Closes #37, #38, #41.

### Tests
- 92 new tests and 256 new assertions across 6 new service test files; suite now at 495 tests / 1681 assertions (up from 403 / 1425).

---

## Internal refactor (2026-05-17)

### Changed (no user-visible behavior change)
- **`GitInfoService` extracted** — the 139-line concurrent wave-orchestration block in `EditorsController#git_info` is now `GitInfoService.call(repo_path)` with a 5 s TTL cache and `invalidate` hook. Controller action is a single `render json:` call. `parse_porcelain_status` and `parse_name_status` promoted to `GitService` module functions. Closes #4, #5, #6.
- **`CodeSearchService` extracted** — `rg`/`grep` subprocess execution, fallback, ReDoS guards, and result parsing unified in one place. `JsDefinitionService` and `JsMembersService` are now thin wrappers. Closes #7, #8, #9, #10.
- **`ExclusionMatcher` extracted** — four diverged implementations of "should this path be excluded?" replaced by `ExclusionMatcher.new(config.excluded_paths).excluded?(path)`. `EditorsController`, `RubyDefinitionService`, and `UnusedMethodsService` all delegate to it. Closes #11, #12, #13, #14.
- **`FileOperationService` extracted** — ~200 LOC of inline file-CRUD logic in `EditorsController` moved to `FileOperationService` (save, create_file, create_dir, rename, destroy_path). Each controller action is now: resolve path → block-check → call service → broadcast → render. Closes #15, #16, #17.
- **`ProcessRunner` extracted** — three copies of "Open3 + timeout thread + SIGKILL" unified in `ProcessRunner.call(cmd, timeout:, env: {}, stdin_data: nil, chdir: nil)`. `GitService`, `TestRunnerService`, and the `EditorsController` lint path all delegate to it. Fixes the latent popen deadlock in `TestRunnerService`. Closes #18, #19, #20, #21.

### Tests
- 271 new tests and 845 new assertions across 10 new service test files; suite now at 403 tests / 1425 assertions (up from 132 / 580).

---

## [0.6.0] - 2026-05-11

### Added
- **Virtual scrolling in FileTree** — only visible rows are rendered, dramatically improving performance with large file trees.
- **Multi-resource Rails panel** — the sidebar Rails panel now shows related files for up to 10 open Rails resources simultaneously, grouped by resource name with a dirty-file dot indicator.
- **Vim `:split` / `:vsplit` commands** — split the current file into the other pane using standard Vim command-line syntax.
- **Format changed-line highlighting** — after running Format Document, changed lines are highlighted with a green background for 3 seconds.
- **Sidebar panel titles** — "Explorer", "Search", and "Rails" labels now appear at the top of each sidebar panel.
- **Dirty-file indicators in Rails panel** — a small dot appears next to related files with unsaved changes.

### Changed
- Rails activity bar icon updated from text "R" to a Font Awesome gem icon.
- Monaco model cache size raised from 15 to 25 (`MAX_MODELS`).
- `wordBasedSuggestions` default changed to `'currentDocument'`; `linkedEditing` now respects user preferences.
- Git file comparison uses a lightweight signature function instead of `JSON.stringify`.
- Window-globals detection improved: symbols found on `window` at runtime are declared as globals to suppress TS2304 errors.

### Removed
- JSON auto-pretty-print on file open (files now display raw content).

## [0.5.1] - 2026-04-30

### Added
- **Large file pagination** — files over 5 MB now open in read-only paginated mode (500 lines per page) instead of showing an error. A bar below the toolbar shows the current line range, total line count, and file size, with Prev/Next navigation. The backend streams only the requested line slice via `File.foreach` so arbitrarily large files never load fully into memory.
- **JSON auto pretty-print** — `.json` files are automatically formatted with 2-space indentation when opened. Invalid JSON falls back to raw display with Monaco's built-in error markers. The formatted content is set as the editor baseline so the file does not appear dirty after opening.

## [0.5.0] - 2026-04-30

### Added
- **Zen / focus mode** — `Cmd+Shift+Z` hides the sidebar and git panel for a distraction-free editing experience.
- **Bulk find-and-replace** — search and replace across all workspace files in one operation.
- **File content prefetch on hover** — opening a file from the tree is now instant; content is fetched while hovering the row.
- **Client-side search cache** — search results are cached client-side for 30 s and invalidated automatically on save.
- **Monaco model cache with LRU eviction** — in-memory Monaco models are capped at 15 and evicted in LRU order to keep memory use bounded.

### Changed
- **Faster initial render** — Monaco startup is now decoupled from the React mount lifecycle, cutting time-to-first-edit.
- **Robust dirty-state tracking** — dirty state is now driven by Monaco's `alternativeVersionId`; `cleanVersionId` is reset correctly on save-on-close so re-opened tabs start clean.

### Fixed
- ActionCable reconnect logic hardened; regression tests added to confirm websocket lifecycle log filtering still works after reconnect.
- Bulk replace: fixed a security issue and a correctness bug in the replacement pipeline; added covering tests.

## [0.4.5] - 2026-04-23

### Fixed
- Suppressed Action Cable websocket request lifecycle noise (`Started/Finished "/cable" [WebSocket] ...`) in development logs via `CableLogFilter`.
- Added regression coverage to ensure websocket lifecycle request logs stay filtered while regular Action Cable logs continue to pass through.

## [0.4.4] - 2026-04-23

### Fixed
- `CableLogFilter` now preserves Action Cable and Action Pack tagged-logger compatibility by supporting formatter-level `current_tags` access and no-op tag operations for untagged or nil formatters.
- Added regression coverage for formatter-tag compatibility paths to prevent `current_tags` runtime errors.
- System test Cuprite driver configuration now applies explicit startup timeout options through `driven_by` to avoid intermittent Ferrum browser bootstrap timeouts in CI.

## [0.4.3] - 2026-04-22

### Added
- Documented optional Action Cable host-app setup and fallback behavior for realtime editor updates.

### Changed
- `bundle exec rake test` now includes `test/lib/**/*_test.rb` so release validation covers library-level regression tests.

### Fixed
- Action Cable availability detection now respects whether `/cable` is actually mounted, and websocket handshake failures fall back to polling without noisy console errors.
- Circular loading indicators keep animating even when global reduced-motion styles are active in production.
- `CableLogFilter` now remains compatible with untagged logger stacks used outside full Action Cable setups.

## [0.4.2] - 2026-04-22

### Fixed
- Updated sidebar search system test selectors to match the current UI loading and clear controls, resolving CI matrix failures in GitHub Actions.

## [0.4.1] - 2026-04-22

### Added
- Real-time file update integration via Action Cable to improve collaborative and live-refresh editing workflows.

### Changed
- Search functionality enhancements for improved result handling and responsiveness.

## [0.4.0] - 2026-04-22

### Added
- **Draft auto-save and restore** — unsaved edits are written to `localStorage` every 500 ms per file. On reconnect after a server outage, a dialog offers to restore any drafts that diverged from the in-memory tab content.
- **Tab bar layout setting** — new "Tab bar layout" preference (Scroll / Wrap multi-row) stored in editor prefs; `TabBar` receives a `tabDisplayMode` prop and applies the appropriate CSS class; horizontal wheel scroll is disabled in wrap mode.

### Fixed
- **Drag-to-split** — pane 2 drop zone is now only shown when the cursor actively hovers over the right-half content area, preventing the tab bar from collapsing during a drag. Dropping onto a tab bar element is no longer intercepted by the cross-pane drop handler, preserving same-pane reordering.
- **Quick Open sorting** — files consistently rank above directories; within the same priority tier results are sorted by match relevance (exact basename > prefix match > substring > other).
- **Search total count** — the count thread is joined with a 100 ms timeout; `total_count` is omitted from the response when the thread has not finished, so the first page is never blocked by the counting subprocess.
- **Status bar message colour** — removed `color-mix` transparency that was dimming the accent-text colour.

## [0.3.9] - 2026-04-21

### Added
- Search responses now include a total result count; background counting runs for the first page to populate it without blocking.
- Editor preferences expanded with line height, letter spacing, cursor style, and auto-closing bracket/quote settings.

### Fixed
- Multi-line tab indentation corrected; added regression test to prevent recurrence.
- 8 correctness, security, and reliability fixes surfaced by ultrareview.

## [0.3.8] - 2026-04-16

### Fixed
- Prevented Emmet's custom Tab action from intercepting selected text, so multi-line selections are no longer replaced when pressing Tab/Shift+Tab in markup editors.

### Added
- Added a system regression test to ensure multi-line selections in JSX are not collapsed by the Emmet Tab integration.

## [0.3.7] - 2026-04-16

### Fixed
- Corrected the `destroy_path` missing-path controller test to expect `200 OK` for idempotent DELETE behavior, which unblocks the tag-based publish workflow for this release.

## [0.3.6] - 2026-04-15

### Fixed
- Multi-file/folder delete now deduplicates child paths covered by a selected ancestor directory, preventing redundant requests and Rails 404 console errors.
- Switched multi-delete from `Promise.all` to `Promise.allSettled` so all deletions complete before checking for failures rather than bailing on the first rejection.
- `destroy_path` controller action is now idempotent — returns 200 when the path is already gone, matching correct REST DELETE semantics.

## [0.2.8] - 2026-04-15

### Changed
- Refactor code structure for improved readability and maintainability.

## [0.2.4] - 2026-04-02

### Added
- **Global service exposure** — `SearchService` and `GitService` are now attached to the `window` object so host-app scripts can call them directly.
- **Loading indicator** — editor now shows a loading state while assets initialise.

### Changed
- **Service worker** — simplified to a minimal implementation; removed the caching layer that was causing stale-asset issues.
- **Monaco Handlebars language** — updated language definition for improved syntax coverage and structure.

### Fixed
- Test suite clean-up following recent service and SW changes.

## [0.2.3] - 2026-04-02

### Changed
- Released the current mainline commit as the latest tagged version.

## [0.2.1] - 2026-04-01

### Fixed
- **Missing files in restored tabs** — file loads can now opt into a structured missing-file response so restored editor tabs stay stable instead of erroring when a file has been deleted.
- **Markdown preview restore** — markdown preview tabs are only recreated after a real file load, which avoids blank preview panes for missing files.
- **Fallback search exclusions** — the non-ripgrep search path now excludes configured nested directories without accidentally excluding unrelated sibling directories with the same basename.
- **Branch combined diff baseline** — branch-wide combined diffs now prefer the same merge-base style baseline used elsewhere in the git panel instead of relying only on the upstream ref.
- **PWA assets** — the web manifest is emitted with explicit manifest content, and the service worker now uses install and activate handlers instead of a no-op fetch listener.

## [0.1.9] - 2026-03-27

### Added
- **Authentication hook** — new `authenticate_with` configuration option accepts a proc/lambda that runs as a `before_action` in all engine controllers. Use it to plug in the host app's auth system (e.g. Authlogic's `UserSession.find`, Devise's `authenticate_user!`). The proc executes via `instance_exec` so `session`, `cookies`, `redirect_to`, and auth library class methods are all accessible. Default: `nil` (no auth, existing behaviour preserved).

### Fixed
- **HTTP status code** — all 422 responses now use `:unprocessable_content` (the correct Rails symbol for HTTP 422 since RFC 9110) instead of the deprecated `:unprocessable_entity`.
- **Search exclusion** — search command construction refactored for clearer exclusion handling.

## [0.1.8] - 2026-03-27

### Fixed
- **Stray engine config** — removed `config/environments/development.rb` from the engine root; environment configs belong only in the dummy app.
- **CI workflow** — corrected ref format in the GitHub Actions checkout step.
- **Test reliability** — refactored HTTP stubbing in `RedmineServiceTest` for improved clarity.

## [0.1.7] - 2026-03-26

### Added
- **Test results panel** — a dedicated panel shows pass/fail counts, per-test status icons, and error messages after a test run. Inline failure markers overlay the Monaco editor and can be toggled independently of RuboCop markers.
- **File history context menu** — the tab bar context menu now includes a file history option that opens the per-file commit log.

## [0.1.6] - 2026-03-25

### Added
- **Editor preferences** — added a settings tab for theme, font size, font family, tab size, and insert-spaces preferences.

### Changed
- **Theme support** — Monaco now initializes with the saved editor theme and other user preferences.
- **Language tooling** — JavaScript and TypeScript use the dedicated worker setup for better editor support.

### Fixed
- **Search results** — capped workspace search results now surface the cap state in the UI.
- **File size validation** — the 5 MB file-size limit now applies on write as well as read.
- **System test teardown** — Cuprite sessions now reset before deleting temporary workspaces, preventing background git requests from hitting removed paths in CI.

## [0.1.5] - 2026-03-24

### Added
- **Shared file icons** — explorer, git panel, tabs, and quick-open now use the same icon mapping.
- **Quick-open polish** — Ctrl+P shows file icons beside each result and includes a clear button.

### Changed
- **Search UX** — the sidebar search now shows a loading spinner while the backend search request is in flight, and it includes a clear button.
- **Git refresh UX** — the git panel refresh button now spins while refresh data is loading.

## [0.1.4] - 2026-03-24

### Fixed
- **Blame workspace root** — git blame now resolves paths through the shared workspace-root helper, which keeps dummy-app and auto-detected repo roots consistent.
- **Heartbeat log noise** — `/ping` requests are silenced at the middleware layer before Rails request logging runs.
- **Blame presentation** — blame is rendered as grouped headers showing author and commit message above contiguous code blocks.

## [0.1.3] - 2026-03-24

### Performance
- **Heartbeat log spam** — `ping` action now uses `Rails.logger.silence`; the frontend switches to a self-rescheduling `setTimeout` (30 s online / 5 s offline) and skips polls entirely while the browser tab is hidden (`document.hidden`).
- **FileTree re-renders** — `FileTree` is now wrapped in `React.memo` with a data-only comparator. Event handler references (which are re-created on every `MbeditorApp` render) are intentionally ignored, preventing the entire O(n) tree traversal on every keypress, git poll, or status-bar update.
- **Search index blocking** — `SearchService.buildIndex` is now deferred to idle time via `requestIdleCallback` (with a 50 ms `setTimeout` fallback for Safari). The main thread is no longer blocked during the synchronous MiniSearch rebuild that runs after every project-tree refresh.
- **Blame decoration churn** — removed `tab.content` from the blame-decoration `useEffect` dependency array in `EditorPanel`. Decorations are derived from `blameData` (fetched once on toggle); re-applying the same decorations via `deltaDecorations` on every keystroke was unnecessary.
- **EditorStore slice subscriptions** — added `EditorStore.subscribeToSlice(keys, fn)` so future sub-components can subscribe only to the store keys they care about, avoiding re-renders for unrelated state changes.

## [0.1.2] - 2026-03-24

### Fixed
- **Webfonts 404** — Font Awesome CSS used relative `../webfonts/` paths that resolved to `/webfonts/fa-*` at the host-app root, where no route existed. The vendor stylesheet is now processed by Sprockets ERB so font URLs are rendered as fingerprint-correct `asset_path` calls, and `.ttf` fallback references (which were never bundled) have been removed.
- **Git compatibility** — `git branch --show-current` is only available in Git ≥ 2.22. All three call sites have been replaced with `git rev-parse --abbrev-ref HEAD` (works on any modern Git), centralised in `GitService.current_branch`. The git panel no longer reports an error on older Git installations.
- **Slow initial load** — `workspace_root` (when not explicitly configured) now caches the `git rev-parse --show-toplevel` subprocess result at the class level so the subprocess runs at most once per process. `rubocop_available?`, `haml_lint_available?`, and `git_available?` are similarly cached, keyed by their respective configuration values so tests and reconfiguration still get fresh results.

## [0.1.1] - 2026-03-24

### Changed
- Bumped the release to avoid republishing the already-pushed 0.1.0 gem and to include the latest GitHub Actions publish workflow updates

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
