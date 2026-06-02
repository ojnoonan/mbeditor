# Architecture Review — 2026-W21

**Project:** mbeditor Rails engine gem  
**Reviewed:** 2026-05-23  
**Scope:** Controllers, services, channels, test coverage gaps — post W20 refactor  
**Status:** Complete — all open candidates implemented (W21)

---

## Glossary

- **Module** — anything with an interface and an implementation (function, class, package, slice).
- **Depth** — leverage at the interface: a lot of behaviour behind a small interface.
- **Seam** — where an interface lives; a place behaviour can be altered without editing in place.
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Deletion test** — imagine deleting the module. If complexity reappears across N callers, it was earning its keep in the wrong place.

---

## Candidates

### 1. `EditorsController` — god object with no internal seams

**Status: Done** — commit `4687d38`, `7a971b3`, `cf2b29e`

**Files:**
- `app/controllers/mbeditor/editors_controller.rb` (935 lines, down from 1,281)

**Problem:** The controller's interface (HTTP routes) is nearly as complex as its implementation. File I/O, regex search, linting, Rails introspection, test running, PWA assets, and Monaco worker serving all live in one class. There is no seam between these domains — no way to alter search behaviour without opening the same file as tree building or lint execution. Private method proliferation (900+ lines total) means helper logic is unreachable by tests.

**Deletion test:** Delete it and complexity scatters across 8–10 places — but that complexity already is scattered, just inside one file. The problem is the absence of seams, not the presence of logic.

**Solution:** Extract private helper clusters into deep modules with narrow interfaces — `FileTreeService`, `SearchReplaceService`, `AvailabilityProbe`. The controller becomes a thin dispatch layer. Each extracted module's interface becomes the test surface.

**Implemented:** `AvailabilityProbe` (83 lines), `FileTreeService` (69 lines), `SearchReplaceService` (184 lines), and `EditorStateService` (91 lines) all extracted. Controller reduced by 346 lines; service logic is now directly testable.

**Benefits:**
- *Locality* — feature-specific bugs and changes land in feature-specific files.
- *Leverage* — callers (and the controller itself) get results without reasoning about implementation.
- *Tests* — service logic testable directly without an HTTP stack; controller tests shrink to routing and auth.

---

### 2. `SearchReplaceService` — duplicated subprocess logic, security buried in action

**Status: Done** — commit `7a971b3`

**Files:**
- `app/services/mbeditor/search_replace_service.rb` (184 lines)
- `app/services/mbeditor/code_search_service.rb` (44 lines, retained as thin public alias)

**Problem:** `CodeSearchService` and the controller share no code, yet independently implement `RG_AVAILABLE` detection, `rg`/`grep` flag building, and whole-word/case-sensitivity flags — two copies of each. `replace_in_files` buries path validation, ReDoS protection, per-file timeout (line 536: `Timeout::timeout(5)`), and encoding handling inside a 95-line controller action. `CodeSearchService` is a shallow module: its interface is nearly as complex as its 44-line body.

**Deletion test:** Delete `CodeSearchService` — the rg/grep switching logic reappears verbatim in the controller. It was earning its keep in the wrong layer.

**Solution:** One deep `SearchReplaceService` — takes `(workspace_root, query, options)`, returns a result struct. `RG_AVAILABLE` detection, rg/grep switching, exclusion filtering, encoding, and per-file timeout all live inside. Streaming vs. counted search become adapters on the same seam. `CodeSearchService` either dissolves into it or becomes its internal adapter.

**Implemented:** `SearchReplaceService` (184 lines) consolidates all rg/grep detection, flag building, ReDoS protection, and per-file timeout. `search`, `stream_search_results`, and `replace_in_files` in the controller are now thin delegators.

**Benefits:**
- *Locality* — `rg` flag changes, ReDoS guards, and encoding edge cases in one place.
- *Leverage* — callers specify query and options; get structured results with no process-management knowledge required.
- *Tests* — security logic (path validation, file size limit) testable in isolation; one test matrix for subprocess behavior.

---

### 3. State persistence — identical logic in two protocol layers

**Status: Done** — commit `cf2b29e`

**Files:**
- `app/services/mbeditor/editor_state_service.rb` (91 lines)
- `app/channels/mbeditor/editor_channel.rb` — thin adapters calling the service
- `app/controllers/mbeditor/editors_controller.rb` — thin adapters calling the service

**Problem:** `save_state` and `save_branch_state` exist twice — once for HTTP, once for WebSocket. Both write JSON to `tmp/mbeditor_*.json`, both acquire a file lock, both validate sizes, both handle errors identically. There is no seam between the persistence logic and its protocol; fixing a locking bug requires editing two files.

**Deletion test:** Delete the channel copy — complexity reappears in WebSocket clients. Delete the controller copy — complexity reappears in HTTP clients. Both copies earn their keep, but neither should own the logic.

**Solution:** A single `EditorStateService` — `read_state`, `write_state`, `write_branch_state`, `prune_branch_states`. Both `EditorChannel` and `EditorsController` become thin adapters: call the service, translate the result into their protocol's response. File locking, size limits, and error handling live entirely inside.

**Implemented:** `EditorStateService` (91 lines) owns file locking, size validation, JSON serialization, and error handling. Both protocol layers are now thin adapters.

**Benefits:**
- *Locality* — locking bugs, size-limit changes, and path conventions concentrated in one place.
- *Leverage* — protocol layers get success/failure without reasoning about file locking.
- *Tests* — persistence logic testable without Rails or ActionCable; protocol adapters testable with stubs.

---

### 4. `RubyDefinitionService` — cache lifecycle leaked through the interface

**Status: Done** — commit `06cfba5` (closes #33–#36)

**Files:**
- `app/services/mbeditor/ruby_definition_service.rb` (406 lines)
- `app/services/mbeditor/unused_methods_service.rb` — warmup hack removed

**Problem:** The interface exposes `load_disk_cache_once`, `persist_cache`, `clear_cache!`, `scan`, and `defs_in_file` as public class methods. Callers must know that `call()` populates a class-level cache before `defs_in_file()` can be used, and that `persist_cache()` must be called after bulk operations. `UnusedMethodsService` contains a warmup hack — calling with the dummy symbol `"__mbeditor_warmup__"` (lines 45–53) to force cache population. The implementation has leaked through the interface.

**Deletion test:** Delete the public cache methods — the warmup hack in `UnusedMethodsService` and the lifecycle assumptions in callers collapse. The leaked contract was load-bearing, but in the wrong place.

**Solution:** Make the cache an opaque implementation detail. Public interface: `call(workspace_root, symbol)` and `defs_in_file(path)` — cache warming, disk persistence, and lifecycle happen inside. The warmup hack disappears.

**Implemented:** `load_disk_cache_once` and `persist_cache` are now private class methods. `defs_in_file` and `includes_in_file` self-warm on first call. `clear_cache!` retained as public for test teardown only. Warmup hack in `UnusedMethodsService` removed — it now calls `defs_in_file` directly.

**Benefits:**
- *Locality* — cache lifecycle bugs (stale entries, disk persistence race) in one file.
- *Leverage* — callers get results without a mental model of cache state.
- *Tests* — interface testable through two methods; cache behavior verifiable without callers knowing the mechanism.

---

### 5. Git service family — thin aggregation, shallow pass-throughs

**Status: Done (targeted scope)** — commit `d9ddd6a` (closes #37, #38, #41)

**Files:**
- `app/services/mbeditor/git_commit_detail_service.rb` (46 lines, new)
- `app/services/mbeditor/git_combined_diff_service.rb` (43 lines, new)
- `app/controllers/mbeditor/git_controller.rb` (140 lines, down from ~200; now a true thin dispatcher)

**Problem:** `GitController` is a pass-through facade: instantiate service, call `.call`, render JSON. Five specialized services each repeat the same `repo_path:, file_path:` initialization pattern with minimal logic beyond delegating to `GitService` utilities. `GitService` is a shallow mixin — 11 parse/run utilities included into other services, interface complexity ≈ implementation complexity. The real depth (wave orchestration threading in `GitInfoService`) is isolated behind its own deep interface but the supporting cast isn't.

**Deletion test:** Delete `GitController` — 30 lines of routing logic move to callers; no business logic lost. Delete `GitDiffService` — `Open3.capture3("git diff ...")` reappears in the controller directly. Shallow.

**Solution (as implemented):** The full consolidation into a `GitRepository` module was evaluated and not pursued — the existing service-per-operation pattern is clear and each service has a narrow, stable interface. The actual pain point was two controller actions (`commit_detail`, `combined_diff`) that contained raw `Open3` subprocess calls inline. These were extracted into `GitCommitDetailService` and `GitCombinedDiffService`. `GitController` is now a true thin dispatcher with no subprocess logic.

**Not pursued:** Collapsing `GitDiffService`, `GitBlameService`, `GitFileHistoryService`, `GitCommitGraphService` into a `GitRepository` module; retiring `GitService` as a mixin. These remain as-is — no active pain point justified the churn.

**Benefits:**
- *Locality* — git output parsing in one namespace, not spread across five services.
- *Leverage* — `GitRepository` offers named operations; callers don't build `Open3` calls.
- *Tests* — one mock point for subprocess execution; parse logic testable with fixture strings.

---

### 6. `TestRunnerService` — parser coupled to framework detection

**Status: Wontfix**

The stated benefits don't hold against the current code. `parse_minitest_output` and `parse_rspec_output` are already called directly in tests with fixture strings — no HTTP stack required. `detect_framework` and `parse_output` are already separate methods; the entanglement described here was resolved in the W20 refactor. Adding a new framework is already additive (one `when` branch each in `parse_output` and `build_command`). Extraction would also complicate the existing `parse_rspec_output` → `parse_minitest_output` JSON-failure fallback by introducing a cross-module dependency. Low effort / Low impact with no active pain point.

---

### 7. `RailsRelatedFilesService` — 122-line naming method with 12 case branches

**Status: Wontfix**

The stated benefits don't hold against the current code. The branches in `extract_resource_names` are structurally identical (check suffix, split namespace, build plural/singular) and self-contained — understanding one branch does not require reading all 122 lines. A "data-driven table" either reintroduces lambdas per entry (case branches in different clothes) or collapses into a generic extractor that must still special-case `app/views`, which reads `parts[2..N-2]` rather than stripping a suffix. The "leverage" benefit is hollow: `extract_resource_names` is already `private_class_method` with a single internal caller. The only concrete gain is dropping `.send` in tests — a minor awkwardness, not a real problem. No active pain point, and the proposed design has a structural flaw views expose immediately.

---

## Summary

| # | Candidate | Effort | Impact | Status |
|---|-----------|--------|--------|--------|
| 1 | `EditorsController` god object | High | High | Done |
| 2 | `SearchReplaceService` | Medium | High | Done |
| 3 | `EditorStateService` (state persistence) | Low | Medium | Done |
| 4 | `RubyDefinitionService` cache encapsulation | Medium | Medium | Done |
| 5 | Git service family (targeted: extract inline Open3 from controller) | Medium | Medium | Done |
| 6 | Test runner output parsers | Low | Low | Wontfix |
| 7 | `RailsNamingConventions` module | Medium | Low | Wontfix |
