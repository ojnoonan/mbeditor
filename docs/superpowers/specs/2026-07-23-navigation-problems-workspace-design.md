# Navigation and Problems Workspace — Design

**Date:** 2026-07-23
**Status:** Design approved, pending written-spec review

## Problem

Mbeditor already provides Quick Open, Monaco diagnostics, Ruby LSP definition,
hover, completion, and document diagnostics. These features are exposed through
separate controls and editor integrations, however:

- there is no searchable command surface;
- diagnostics cannot be reviewed across the files encountered during a session;
- developers cannot browse document or workspace symbols from the keyboard; and
- new actions are wired directly into large UI components instead of through a
  reusable command boundary.

The goal is to make everyday navigation and problem review feel coherent while
preserving mbeditor's development-only, zero-frontend-build-step architecture and
its conservative security boundary.

## Goals

- Provide a keyboard-first command palette.
- Provide document-symbol and workspace-symbol navigation.
- Aggregate known diagnostics in a Problems panel without running an automatic
  full-workspace scan.
- Use the same normalized diagnostic records for Monaco markers and the Problems
  panel.
- Create focused command, problem, and bottom-panel interfaces that the later
  Test Workbench can reuse.
- Degrade clearly when Ruby LSP or another provider is unavailable.

## Non-goals

- Git staging, commits, branch operations, or any other source-control mutation.
- Rename, automatic code-action application, Rails generators, or other commands
  that write files.
- An integrated terminal or arbitrary command execution.
- Automatic linting of every file in the workspace.
- Test discovery, test result presentation, or coverage. Those belong to the
  separate Test Workbench design.
- Replacing Monaco's built-in editor actions or language services.
- A general refactor of `MbeditorApp.js` or `EditorPanel.js`.

## Chosen approach

Introduce a shared command-and-problem foundation, then build the palette,
symbol pickers, and Problems panel on it.

This was selected over:

1. **LSP-first implementation.** Extending the Ruby LSP bridge before defining a
   shared user experience would improve Ruby support but leave commands and
   diagnostics fragmented.
2. **Direct component wiring.** Adding handlers and state directly to
   `MbeditorApp.js` and `EditorPanel.js` would be initially smaller but would
   further concentrate unrelated responsibilities in two existing hotspots.

The chosen approach adds only the seams required by this feature. Existing
actions remain implemented by their current owners and register lightweight
command adapters.

## Architecture

### `CommandRegistry`

A plain JavaScript module loaded through the existing asset pipeline. It owns
command discovery and dispatch, not command business logic.

Each command has:

```text
id                stable namespaced identifier
title             user-facing label
category          optional grouping label
keybinding        optional display and dispatch metadata
keywords          optional search aliases
isAvailable()     current availability and optional disabled reason
execute(context)  action supplied by the owning feature
```

The registry:

- rejects duplicate identifiers;
- detects conflicting registered shortcuts;
- ranks title, category, and keyword matches deterministically;
- returns at most 100 palette results;
- supports synchronous and asynchronous handlers; and
- catches rejected handlers through one error boundary.

It does not own modal state, editor state, filesystem access, or network calls.
`MbeditorApp` supplies a narrow execution context containing existing callbacks
such as open file, show panel, and focus editor.

Initial registered commands:

- Quick Open
- Go to Symbol in Editor
- Go to Symbol in Workspace
- Show Problems
- Go to Next Problem
- Go to Previous Problem
- Toggle Rails Log
- existing safe editor actions that already have keyboard or menu entry points,
  including format and test-at-cursor where available

Registering an existing action does not change its authorization or behavior.

### `ProblemStore`

A plain JavaScript external store with subscription semantics consistent with
the existing editor state modules. It is the canonical session model for known
diagnostics.

Records are keyed by:

```text
workspace-relative path
provider/source identifier
document version
diagnostic identity
```

The normalized diagnostic shape is:

```text
path, source, severity, message, code
startLine, startCol, endLine, endCol
documentVersion, stale
```

Rules:

- Providers update only their own records.
- A successful empty result clears that provider's records for the file.
- A failed or timed-out request retains the last successful records and marks
  that provider/file pair stale.
- Results for an older document version are ignored.
- Closing a tab retains known diagnostics for the session.
- A later successful provider result replaces the applicable records; saving a
  file alone does not imply that diagnostics were refreshed.
- Rename migrates records to the new path.
- Delete removes records for the deleted path and its descendants.
- Workspace reload clears the store.
- At most 1,000 diagnostics are accepted per provider and file. Truncation is
  represented explicitly in the UI.

Engine-owned providers such as Ruby LSP, RuboCop, and HAML lint normalize into
the store first, then project their records into Monaco using their existing
marker owners. Monaco-owned language diagnostics, including JavaScript and
TypeScript diagnostics, remain owned by Monaco; an
`monaco.editor.onDidChangeMarkers` observer mirrors them into the store using
the model version. The store never clears or rewrites a Monaco-owned marker
owner. This preserves Monaco's language-service lifecycle while ensuring the
Problems panel consumes the markers actually visible in the editor.

### `NavigationService`

The browser-facing navigation module coordinates symbol queries and translates
responses into a shared symbol result:

```text
name, kind, containerName
workspace-relative path
startLine, startCol, endLine, endCol
provider
```

Document symbols:

- use `textDocument/documentSymbol`;
- include the active unsaved buffer through the existing Ruby LSP document
  synchronization path; and
- preserve hierarchy from the LSP response for display while allowing every
  result to be selected directly.

Workspace symbols:

- use `workspace/symbol`;
- cap returned results at 200;
- ignore superseded queries;
- convert file URIs to safe workspace-relative paths; and
- discard responses outside the mounted workspace.

Ruby LSP is preferred. When it is unavailable:

- document-symbol navigation may use
  `RubyDefinitionService.defs_in_file` as a saved-file, method-only fallback;
- that fallback is identified as limited and does not claim to reflect unsaved
  content; and
- workspace-symbol navigation is disabled with a clear Ruby LSP availability
  reason.

The existing definition service performs exact-symbol searches and therefore
is not presented as a fuzzy workspace-symbol index.

### Rails boundary

The existing Ruby LSP endpoint is extended only for:

- `textDocument/documentSymbol`
- `workspace/symbol`

The controller keeps an explicit method whitelist. File-scoped requests pass
through `resolve_path`; workspace-symbol response URIs are resolved and checked
against the workspace before serialization. The browser never receives
out-of-workspace paths.

The Ruby LSP initialize capabilities advertise only the newly supported symbol
capabilities in addition to the capabilities already present. No generic
pass-through for arbitrary LSP methods is introduced.

### UI components

#### `CommandPalette`

An overlay opened by `Cmd/Ctrl+Shift+P`. It provides:

- fuzzy command search;
- keyboard selection and execution;
- keybinding hints;
- disabled commands with a concise reason when discoverability is useful; and
- focus restoration to the previously focused editor when dismissed.

Quick Open remains `Cmd/Ctrl+P` and retains its current file-oriented behavior.

#### Symbol pickers

Document and workspace symbols use the established picker interaction style:
type to filter, arrow keys to select, Enter to navigate, and Escape to return
focus. They can be opened directly or through the command palette.

Default shortcuts:

- `Cmd/Ctrl+Shift+O`: symbols in the active editor
- `Ctrl+T`: workspace symbols

The implementation must avoid overriding a Monaco binding when Monaco reports
that the binding is already owned by a higher-priority action. All commands
remain accessible through the palette if a host/browser shortcut wins.

#### Bottom panel host

The existing Rails log drawer is generalized into a reusable resizable bottom
panel host. It initially exposes:

- `PROBLEMS`
- `RAILS LOG`

The Problems tab contains:

- total error, warning, and informational counts;
- severity and source filters;
- grouping by file;
- a stale-provider indicator;
- an explicit truncation row when a provider exceeds its limit; and
- rows that open and focus the exact diagnostic range.

The status bar shows error and warning totals. Selecting those totals opens the
Problems tab. The reusable host is intentionally limited to panel selection,
height, and close/resize behavior; each panel owns its own data and controls.

The future Test Workbench may add a `TESTS` tab, but this design does not add
test-specific behavior.

## User workflow

### Commands

1. The user presses `Cmd/Ctrl+Shift+P`.
2. `CommandPalette` requests ranked entries from `CommandRegistry`.
3. Availability is evaluated against current editor context.
4. Selecting a command closes the palette and calls its registered handler.
5. On completion or failure, focus returns to the appropriate editor or opened
   panel.

### Diagnostics

1. Existing Monaco, Ruby LSP, RuboCop, or HAML integrations produce results for
   a file.
2. The relevant adapter submits a provider-scoped update with the document
   version to `ProblemStore`.
3. The store rejects an older version or replaces only that provider's current
   records.
4. Monaco markers and the Problems panel update from the same store snapshot.
5. Selecting a row opens the file, reveals the range, places the cursor, and
   focuses the editor.

The Problems panel shows diagnostics known during the current editor session.
It does not claim to represent files that no provider has inspected.

### Symbols

1. The user opens a document or workspace symbol picker.
2. The picker starts a request and assigns it a monotonically increasing query
   identifier.
3. `NavigationService` uses Ruby LSP when available. Document symbols may fall
   back to saved-file Ruby method definitions; workspace symbols have no
   fallback.
4. A response is normalized, bounded, and path-checked.
5. A response whose query identifier is no longer current is discarded.
6. Selecting a result opens the file and navigates to the symbol range.

## Error and availability behavior

- A provider failure never becomes a successful empty diagnostic result.
- Failed diagnostic providers preserve their last result, mark it stale, and
  show a non-blocking status message.
- Superseded symbol requests fail silently.
- A current symbol timeout produces an inline retryable message without closing
  the picker.
- Document symbols remain enabled with a clearly identified saved-file,
  method-only fallback when Ruby LSP is unavailable.
- Workspace symbols remain discoverable but disabled when Ruby LSP is
  unavailable.
- Commands with no available implementation remain visible but disabled when
  their presence teaches the user about an optional dependency; the disabled
  row states the missing dependency.
- A command handler exception is caught centrally, reported through the
  existing notification mechanism, and cannot leave the palette or focus state
  stuck.
- A malformed provider result is ignored and recorded through the Rails logger
  or browser console as appropriate; it does not corrupt existing store state.

## Security

- This feature introduces no Git writes, file mutations, shell commands,
  generators, rename operations, or generic LSP request proxy.
- All file paths continue through `resolve_path`.
- Out-of-workspace LSP URIs are discarded.
- Non-GET requests retain the `X-Mbeditor-Client: 1` requirement.
- LSP methods remain explicitly whitelisted.
- Result caps bound server payloads and browser rendering work.
- The document-symbol fallback is limited to the already resolved active file.

## Performance

- Command matching is local and limited to 100 displayed results.
- Symbol results are limited to 200.
- Diagnostic ingestion is limited to 1,000 records per provider and file.
- Symbol requests are debounced while typing and stale responses are ignored.
- No automatic workspace-wide lint is added.
- The Problems panel groups collapsed files and renders expanded rows
  incrementally rather than mounting every known row at once.
- New application code remains plain JavaScript delivered by Sprockets. Monaco's
  generated bundle is not modified.

## Testing

### JavaScript unit tests

`CommandRegistry`:

- deterministic ranking by title, category, and keywords;
- duplicate identifier rejection;
- shortcut-conflict detection;
- availability and disabled reasons;
- synchronous and asynchronous execution; and
- rejected-handler cleanup and error reporting.

`ProblemStore`:

- provider isolation;
- successful empty clearing;
- failed-result stale behavior;
- older document-version rejection;
- severity counts and filters;
- per-provider truncation;
- rename migration;
- recursive delete cleanup; and
- workspace reset.

`NavigationService`:

- document and workspace symbol normalization;
- hierarchical document symbols;
- URI/path rejection;
- result caps;
- stale-query rejection; and
- saved-file method fallback for document symbols.

### Ruby tests

- Ruby LSP method whitelist accepts only the two new methods.
- Document-symbol requests synchronize unsaved content.
- Workspace-symbol requests use the correct request shape.
- LSP initialization advertises the supported symbol capabilities.
- Out-of-workspace and malformed result URIs are discarded.
- Symbol responses are capped at 200.
- Timeouts and unavailable Ruby LSP produce the documented document-symbol
  fallback or disabled workspace-symbol state.
- Existing path-safety and client-header behavior remain intact.

### Component and system tests

- `Cmd/Ctrl+Shift+P` opens the command palette and Escape restores focus.
- Direct symbol shortcuts and palette commands open the same symbol providers.
- Keyboard navigation selects and executes a command.
- Status-bar counts open the Problems tab.
- Severity and source filters produce the expected grouped rows.
- Selecting a problem opens the exact file and range.
- `F8` and `Shift+F8` traverse known diagnostics in stable
  path/line/column order and wrap at the ends.
- Engine-owned markers are projected from `ProblemStore`; Monaco-owned markers
  are mirrored without changing Monaco ownership.
- With Ruby LSP available, unsaved Ruby content produces current document
  symbols.
- Missing Ruby LSP degrades document symbols to saved-file method definitions
  and disables workspace symbols with a clear reason.
- Rails Log behavior, Quick Open, existing Monaco diagnostics, formatting, and
  test-at-cursor continue to work.

The CI test matrix remains the default Gemfile plus Rails 7.1.

## Acceptance criteria

The feature is complete when:

1. A developer can discover and execute registered editor actions through a
   keyboard-accessible command palette.
2. With Ruby LSP available, a developer can navigate document and workspace
   symbols without saving the active Ruby buffer first.
3. Known diagnostics across the current session appear in one Problems panel
   and match Monaco's markers.
4. Next/previous problem navigation works entirely from the keyboard.
5. Missing or failing providers do not create a false clean state.
6. No automatic full-workspace lint, file mutation, Git mutation, or arbitrary
   LSP method exposure is introduced.
7. Existing Quick Open and Rails Log workflows remain functional.
