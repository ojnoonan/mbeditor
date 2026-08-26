# Architecture Review — 2026-W22

**Project:** mbeditor Rails engine gem
**Reviewed:** 2026-08-26
**Scope:** Commit-frequency hot spots over the last 40 commits — `MbeditorApp.js`, `editors_controller.rb`, `EditorPanel.js`, `editor_plugins.js`, `ProblemsPanel.js`. Referenced by [ADR-0001](adr/0001-no-frontend-build-step.md) as the vehicle for `MbeditorApp`/`editor_plugins.js` maintainability work.
**Status:** In progress — candidates 1–2 done, 3–6 open

---

## Glossary

- **Module** — anything with an interface and an implementation (function, class, package, slice).
- **Depth** — leverage at the interface: a lot of behaviour behind a small interface.
- **Seam** — where an interface lives; a place behaviour can be altered without editing in place.
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Deletion test** — imagine deleting the module. If complexity reappears across N callers, it was earning its keep in the wrong place.

None of the candidates below touch anything already extracted in W20/W21 (`AvailabilityProbe`, `FileTreeService`, `SearchReplaceService`, `EditorStateService`, `RubyDefinitionService`, `GitCommitDetailService`, `GitCombinedDiffService`), and none propose a build step or JSX for app code — see ADR-0001.

---

## Candidates

### 1. `RubyLspResultTranslator` — give the LSP result-translation half of the seam a name

**Status: Done**

**Files:**
- `app/services/mbeditor/ruby_lsp_result_translator.rb` (new)
- `app/controllers/mbeditor/editors_controller.rb` (2004 → 1818 lines)
- `test/services/mbeditor/ruby_lsp_result_translator_test.rb` (new, 22 tests)

**Problem:** CLAUDE.md names `sanitize_lsp_uris` as "the one boundary every raw method crosses" — recursive URI-tree sanitization, embedded-markdown link rewriting, and per-kind shaping for `definition`/`hover`/`completion`/raw-passthrough LSP results — but it lived as 9 controller private methods. The sibling half of the same LSP bridge, diagnostics, already had its own deep module (`LspDiagnosticsTranslator`); this half didn't.

**Deletion test:** Deleting the methods doesn't remove the sanitization — it reappears verbatim at the one call site (`ruby_lsp`). Real seam, previously unnamed.

**Solution (as implemented):** `RubyLspResultTranslator` with four narrow public methods — `.definition(result, workspace_root:)`, `.hover(result, workspace_root:)`, `.completion(result)`, `.raw(result, workspace_root:)` — rather than one `kind`-dispatching `.call`. The four kinds don't share a signature (`completion` never touches `workspace_root`; `hover`/`definition`/`raw` do), so a dispatching entry point would have papered over that. `diagnostics` stays a separate branch delegating to `LspDiagnosticsTranslator` directly — folding it in would have added a layer without deepening anything, since that module is already deep and shared with the plain-`/lint` path. The controller's `translate_ruby_lsp_result` is now a 7-line `case` that calls whichever applies; a second call site (`apply_rename_changes`, rename-file URI resolution) that used the same helper was found during extraction and routed through `RubyLspResultTranslator.workspace_relative_uri` too.

**Benefits:**
- *Locality* — a URI-leak bug is fixed once, not per translator.
- *Leverage* — one interface per kind; the controller no longer carries LSP-shape knowledge.
- *Tests* — URI-sanitization edge cases (outside-workspace paths, percent-escaped spaces, `MAX_LSP_DEPTH` recursion bound) are now one-line direct assertions instead of full HTTP round-trips through a mocked `ruby-lsp` response. 22 new unit tests; the existing `editors_controller_test.rb` HTTP coverage (242 tests) passes unchanged.

---

### 2. `LintService` — build the module CONTEXT.md already documents

**Status: Done**

**Files:**
- `app/services/mbeditor/lint_service.rb` (new)
- `app/controllers/mbeditor/editors_controller.rb` (1818 → 1680 lines)
- `test/services/mbeditor/lint_service_test.rb` (new, 3 tests)
- `CONTEXT.md` (`Diagnostic` entry corrected)

**Problem:** `CONTEXT.md` described `LintService` in the present tense as the module owning rubocop/haml-lint diagnostics and autocorrect. It didn't exist in code. `quick_fix` and `format_file` independently duplicated the same tempfile-then-`rubocop -A` body.

**Deletion test:** Deleting either copy made the tempfile-autocorrect pattern reappear at the other call site — already duplicated, not a false abstraction.

**Solution (as implemented):** `LintService.rubocop_diagnostics(root, path, code)` and `.haml_diagnostics(root, code)` — one method per backend rather than a language-dispatching `.diagnose`, mirroring candidate 1's reasoning (the two backends' parameters and response shapes already differ; a shared entry point would paper over that). `.autocorrect(root, path, code)` → `{ok:, content:}`, absorbing the shared tempfile/exit-status handling that `quick_fix` and `format_file` each reimplemented; both callers now derive their own response shape from the same neutral result.

A real doc/code mismatch surfaced during the grill: `CONTEXT.md`'s `Diagnostic` entry described a neutral intermediate shape, snake_case, mapped to Monaco's marker shape "at the controller edge — never inside the service that produces it" — but the one sibling module that exists (`LspDiagnosticsTranslator`) already emits Monaco-marker-shaped hashes directly, and nothing anywhere implemented the documented neutral form. Rather than build a second, differently-shaped Diagnostic pipeline to match the doc literally, `LintService` matches the real precedent and the `Diagnostic` glossary entry was corrected to describe what both modules actually do.

`compute_text_edit` (produces literal Monaco `SingleEditOperation` keys — a genuine presentation mapping) and `rubocop_config_path` (a `.rubocop.yml`-presence check for an unrelated endpoint, `/workspace`) stay controller-private; neither is diagnostics, autocorrect, or formatted content.

**Benefits:**
- *Locality* — the autocorrect tempfile pattern is fixed in one place, not two.
- *Leverage* — both actions become thin adapters over one interface.
- *Tests* — the pure severity mappers get direct unit tests; the real-subprocess paths stay covered by the existing HTTP tests rather than being duplicated as a second real `rubocop`/`haml-lint` invocation.

---

### 3. `FileHistoryService` — stop reimplementing `EditorStateService`'s locking

**Status: Open**

**Files:** `editors_controller.rb` (`file_history`, `save_file_history`, `history_file_path`, `compact_history_ops`, `flock_exclusive_with_timeout!`) vs. `app/services/mbeditor/editor_state_service.rb` (`with_lock`/`lock_exclusive!`).

**Problem:** `save_file_history` hand-rolls the same monotonic-deadline lock loop `EditorStateService` already owns — but locks the history file in place rather than a sidecar, so it writes with `truncate`/`rewind` instead of atomic rename. A crash mid-write truncates history instead of leaving it untouched. Third instance of a duplication W21 candidate 3 already consolidated once for `EditorChannel`/`EditorsController` state.

**Deletion test:** Deleting `flock_exclusive_with_timeout!` doesn't remove the need for locking — it reappears, because it's already the second copy.

**Sketch:** `FileHistoryService.read(branch, path)` / `.append(branch, path, ops:)`, built on `EditorStateService`'s existing sidecar-lock + atomic-write adapter.

---

### 4. Split `registerGlobalExtensions` by provider group

**Status: Open — Worth exploring**

**Files:** `app/assets/javascripts/mbeditor/editor_plugins.js:1005-2775`.

**Problem:** One 1770-line function registers 17 Monaco providers across three languages with nothing but scroll position separating them.

**Deletion test:** Nothing here is a pass-through — every provider is necessary. This is purely giving one necessary function internal seams, not removing complexity.

**Sketch:** `registerRubyProviders(monaco)`, `registerJsProviders(monaco)`, `registerGenericProviders(monaco)` as named top-level functions in the same file (no new files required); `registerGlobalExtensions` becomes a 4-line dispatcher. Also the natural point to reconcile `CONTEXT.md`'s "Language plugin" glossary entry (`RubyPlugin.registerGlobal`, an object shape that doesn't exist in code today) with what's actually there.

---

### 5. `EditorPanel` — separate one-time language setup from per-tab editor mounting

**Status: Open**

**Files:** `app/assets/javascripts/mbeditor/components/EditorPanel.js:226-1075`.

**Problem:** One 850-line `useEffect` (`[tab.id, tab.isPreview, monacoReady, collabReady]`) fuses page-load-once Monarch grammar registration with per-tab editor instantiation, vim mode, and listener wiring. Scattered module-level guard flags (`_hamlLangRegistered`, …) exist only to compensate for the lifecycle mismatch.

**Deletion test:** The effect boundary earns its keep (real cleanup to track); its contents don't need to share a body.

**Sketch:** `ensureCustomLanguagesRegistered(monaco)` — idempotent, called once, owns its own guards internally. `createEditorInstance(container, tab, opts)` → `{editor, model, dispose}`, so the effect's cleanup calls one `dispose()` instead of hand-rolled symmetric teardown.

---

### 6. Collapse project search into one `useProjectSearch` hook

**Status: Open**

**Files:** `app/assets/javascripts/mbeditor/components/MbeditorApp.js:290-437, 1758-1839, 3600-3780`.

**Problem:** No function or grouping owns "project search" — 12 refs (pagination, request-id staleness guard, viewport) sit ~250 lines before the 8 handlers that use them, separated by ~3200 lines of unrelated component code. The same `{regex, matchCase, wholeWord}` options object is rebuilt independently at three call sites.

**Deletion test:** The request-id guard and pagination state are real, necessary logic — not a pass-through — they're just not given a boundary today.

**Sketch:** `useProjectSearch()` — a plain custom hook (no JSX, no build step) returning `{query, results, loading, hasMore, exec, loadMore, clearSearch, toggles, replaceAll, handleScroll, attachResultsContainer}`. Frontend counterpart to the backend `SearchReplaceService`; no domain term exists yet for it.

---

## Summary

| # | Candidate | Effort | Impact | Status |
|---|-----------|--------|--------|--------|
| 1 | `RubyLspResultTranslator` | Low | High | Done |
| 2 | `LintService` | Low | Medium | Done |
| 3 | `FileHistoryService` | Low | Medium | Open |
| 4 | Split `registerGlobalExtensions` | Medium | Low | Open |
| 5 | `EditorPanel` effect split | Medium | Medium | Open |
| 6 | `useProjectSearch` hook | Medium | Medium | Open |
