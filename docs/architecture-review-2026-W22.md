# Architecture Review — 2026-W22

**Project:** mbeditor Rails engine gem
**Reviewed:** 2026-08-26
**Scope:** Commit-frequency hot spots over the last 40 commits — `MbeditorApp.js`, `editors_controller.rb`, `EditorPanel.js`, `editor_plugins.js`, `ProblemsPanel.js`. Referenced by [ADR-0001](adr/0001-no-frontend-build-step.md) as the vehicle for `MbeditorApp`/`editor_plugins.js` maintainability work.
**Status:** In progress — candidates 1–4 done, 5–6 open

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

**Status: Done**

**Files:**
- `app/services/mbeditor/locked_json_file.rb` (new)
- `app/services/mbeditor/file_history_service.rb` (new)
- `app/services/mbeditor/editor_state_service.rb` (rebuilt on the new primitive, public interface unchanged)
- `app/controllers/mbeditor/editors_controller.rb` (1680 → 1577 lines)
- `test/services/mbeditor/locked_json_file_test.rb` (new, 5 tests)
- `test/services/mbeditor/file_history_service_test.rb` (new, 13 tests)
- `test/controllers/mbeditor/editors_controller_test.rb` (two assertions repointed at the new service's constants)

**Problem:** `save_file_history` hand-rolled the same monotonic-deadline lock loop `EditorStateService` already owned — but locked the history file in place rather than a sidecar, so it wrote with `truncate`/`rewind` instead of atomic rename. A crash mid-write truncated history instead of leaving it untouched. Third instance of a duplication W21 candidate 3 already consolidated once for `EditorChannel`/`EditorsController` state.

**Deletion test:** Deleting `flock_exclusive_with_timeout!` didn't remove the need for locking — it reappeared, because it was already the second copy.

**Solution (as implemented):** The sidecar-lock + atomic-write mechanics that lived as private methods on `EditorStateService` (`with_lock`/`lock_exclusive!`/`atomic_write`/`read_json`) are now `LockedJsonFile`, a tiny class bound to one path with `#read`, `#write(payload)`, and `#with_lock { }` — the third caller (history) is what made the primitive worth naming rather than inlining a second time. `EditorStateService` is rebuilt on it with its public interface and `LockTimeoutError` identity unchanged (an `error_class:` constructor arg lets each service keep raising its own named timeout error rather than a shared one leaking across two unrelated APIs). `FileHistoryService.read(branch, path)` / `.append(branch, path, ops:, base:, base_given:)` / `.prune(active_branches:)` replace the five controller-private methods; `append` now writes by rename via `LockedJsonFile#write` instead of `truncate`/`rewind`, closing the crash-truncation gap. `base_given` (rather than checking `base.present?`) preserves the existing rule that an explicit empty base is a legitimate first snapshot and only an absent `base` param is an error — collapsing that into "base truthy" would have broken the empty-base case a prior fix depended on.

**Benefits:**
- *Locality* — the sidecar-lock/atomic-write contract is defined once; a fix (or the next caller) doesn't need a fourth hand-rolled copy.
- *Correctness* — history writes are now crash-safe the same way state writes are: a torn write can never leave a truncated file on disk.
- *Tests* — the lock-timeout, atomic-rename, and compaction-arithmetic behavior are direct unit tests instead of requiring an HTTP round trip with a real held file lock; the existing `editors_controller_test.rb` HTTP coverage (242 tests) passes unchanged.

---

### 4. Split `registerGlobalExtensions` by provider group

**Status: Done**

**Files:**
- `app/assets/javascripts/mbeditor/editor_plugins.js` (2801 → 2818 lines — pure reorganization; the +17 is new function signatures/braces/dispatcher calls and a short doc comment, not moved logic)
- `CONTEXT.md` (`Language plugin` entry corrected)

**Problem:** One 1770-line function registered 17 Monaco providers across three languages with nothing but scroll position separating them.

**Deletion test:** Nothing here was a pass-through — every provider was necessary. This was purely giving one necessary function internal seams, not removing complexity.

**Solution (as implemented):** `registerJsProviders(monaco)`, `registerRubyProviders(monaco)`, `registerGenericProviders(monaco)` as named top-level functions in the same file, grouped by provider affinity rather than by language exclusively — "generic" holds the four features that are registered once across several languages at once (linked-editing ranges for js/ts/ruby, the shared `file://` editor opener, Prettier formatting across every Prettier-backed language, and the vim fold-marker provider for `scheme: '*'`), since forcing those into a single language's function would have been arbitrary. `registerGlobalExtensions` is now the four-line dispatcher the sketch proposed: the existing `globalsRegistered` once-guard, then three calls in the original registration order (JS setup, Ruby setup, generic). No behavior moved across the split — Monaco merges multiple providers of the same kind (hover, folding, linked-editing) regardless of registration order, and the one place order actually matters (JS formatting) is already decided by `setModeConfiguration` disabling the TypeScript worker's own formatter, not by which function runs first — so grouping by affinity instead of call order changes nothing at runtime. Verified with a line-multiset diff against the pre-refactor file: the touched region gained exactly the four function signatures, their closing braces, and the three dispatcher calls, and lost nothing — every provider registration, helper function, and cache is byte-identical to before, just regrouped.

A real doc/code mismatch surfaced here too, same pattern as candidates 2 and 3: `CONTEXT.md`'s `Language plugin` entry described `RubyPlugin`/`HtmlPlugin`/`JsPlugin`/`GenericPlugin` objects on `window`, each satisfying an `appliesTo(language)` / `registerGlobal(monaco)` / `attach(editor, model, language)` interface — a design that was never built. Nothing in `editor_plugins.js` or anywhere else in the JS tree defines any of those four names. The entry was rewritten to describe the actual two-phase shape: `registerGlobalExtensions` (now the affinity-grouped dispatcher above) for one-time registration, and `attachEditorFeatures(editor, language)` — one function that branches on its own `language` parameter internally (e.g. `EMMET_MARKUP_LANGS[language]`) rather than being fanned out across per-language objects — for per-instance attach.

**Benefits:**
- *Locality* — a provider bug is now found by asking "is this JS, Ruby, or cross-language," not by scrolling a 1770-line function.
- *Leverage* — each of the three functions is independently readable and, per the deletion-test note above, none reads state another one sets up.
- *Docs* — `CONTEXT.md` now names the module shape that exists, so the next reader doesn't go looking for a `JsPlugin` object that was never written.

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
| 3 | `FileHistoryService` | Low | Medium | Done |
| 4 | Split `registerGlobalExtensions` | Medium | Low | Done |
| 5 | `EditorPanel` effect split | Medium | Medium | Open |
| 6 | `useProjectSearch` hook | Medium | Medium | Open |
