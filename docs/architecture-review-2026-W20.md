# Architecture Review — 2026-W20

**Project:** mbeditor Rails engine gem  
**Reviewed:** 2026-05-17  
**Scope:** Backend controllers + services, frontend JS organization, test coverage gaps  
**Status:** All 5 candidates implemented and merged — 2026-05-17 (issues #4–#21 closed)

---

## Glossary

- **Module** — anything with an interface and an implementation (function, class, package, slice).
- **Depth** — leverage at the interface: a lot of behaviour behind a small interface.
- **Seam** — where an interface lives; a place behaviour can be altered without editing in place.
- **Deletion test** — imagine deleting the module. If complexity reappears across N callers, it was earning its keep in the wrong place.

---

## Candidates

### 1. Extract a `GitInfoService` from `EditorsController#git_info` ✓ Done — #4, #5, #6

**Files:**
- `app/controllers/mbeditor/editors_controller.rb` (~139-line `git_info` action)
- `app/controllers/mbeditor/git_controller.rb` (`combined_diff`)
- `app/services/mbeditor/git_service.rb`

**Problem:** `EditorsController#git_info` is 139 lines of wave-based concurrent subprocess orchestration — dependency ordering, threading, cache invalidation, error recovery. It calls `GitService` methods directly but wraps them in logic that belongs nowhere near a controller. `GitController#combined_diff` partially duplicates the same diff logic. Understanding git metadata flow requires reading two controllers and a service module.

**Deletion test:** Delete the 139 lines — the wave orchestration, threading, and dependency ordering reappear across callers. It was earning its keep; it's just in the wrong layer.

**Solution:** Extract the concurrency orchestration into a `GitInfoService` with a single call that takes `repo_path` and returns the full structured git metadata hash. The controller becomes a thin renderer.

**Benefits:**
- *Locality* — all git concurrency bugs live in one place.
- *Leverage* — callers get structured git metadata from a single call without knowing about wave ordering or thread management.
- *Tests* — testable directly with a real repo, asserting on the structure without an HTTP stack.

---

### 2. Consolidate the `rg`/`grep` abstraction into a `CodeSearchService` ✓ Done — #7, #8, #9, #10

**Files:**
- `app/services/mbeditor/js_definition_service.rb`
- `app/services/mbeditor/js_members_service.rb`
- `app/services/mbeditor/unused_methods_service.rb`
- `app/controllers/mbeditor/editors_controller.rb` (`stream_search_results`, `count_search_results`)

**Problem:** Five places each implement `rg_available?`, `build_pattern`, `run_rg`, `run_grep`, `parse_results` with minor variations. `JsDefinitionService` and `JsMembersService` differ only in regex pattern and result filtering. These are shallow modules: interface complexity ≈ implementation complexity.

**Deletion test:** Delete `JsDefinitionService` — the rg/grep subprocess logic reappears in `JsMembersService` identically.

**Solution:** A single `CodeSearchService` parameterized by pattern, file glob, and result shape. Callers pass a query spec; the service handles rg/grep fallback, process timeout, and result parsing uniformly.

**Benefits:**
- *Locality* — subprocess safety, ReDoS guards, and rg/grep fallback in one place.
- *Leverage* — callers get structured results without knowing about process management.
- *Tests* — one test matrix for the subprocess behavior instead of five.

---

### 3. Extract an `ExclusionMatcher` to unify path exclusion logic ✓ Done — #11, #12, #13, #14

**Files:**
- `app/controllers/mbeditor/editors_controller.rb` (3 variants of `excluded_path?`)
- `app/services/mbeditor/ruby_definition_service.rb` (`excluded_dir?`, `excluded_rel_path?`)
- `app/services/mbeditor/unused_methods_service.rb`

**Problem:** Four or more implementations of "should this path be excluded?" with subtly different signatures and semantics. Changes to the exclusion config (adding a new excluded dir) must be applied in multiple places.

**Deletion test:** Delete the controller-level `excluded_path?` — the same predicate logic would have to be reconstructed in the callers.

**Solution:** A single `ExclusionMatcher` that accepts the configured exclusion patterns and exposes one method: `excluded?(relative_path)`. All callers use it.

**Benefits:**
- *Locality* — exclusion bugs and edge cases in one file.
- *Leverage* — callers don't reason about patterns, globs, or partial matches.
- *Tests* — one set of exclusion tests rather than N indirect coverage paths.

---

### 4. Extract a `FileOperationService` from `EditorsController` ✓ Done — #15, #16, #17

**Files:**
- `app/controllers/mbeditor/editors_controller.rb` (actions: `save`, `create_file`, `create_dir`, `rename`, `destroy_path`)
- `app/controllers/mbeditor/application_controller.rb` (`resolve_path`, `path_blocked_for_operations?`)

**Problem:** ~200 LOC of file CRUD logic inline in the controller, including path validation, blocking checks, broadcast triggers, and error handling. `resolve_path` exists in `ApplicationController` but is also privately duplicated in `GitService`. There's no single place that owns "what does a safe file write look like."

**Deletion test:** Delete the inlined save/create/rename logic — path-blocking, mtime tracking, and broadcast wiring reappear scattered across callers.

**Solution:** A `FileOperationService` that takes an operation (`:save`, `:rename`, `:delete`) plus validated paths and returns a result struct. Controllers become request-parsing + response-rendering only.

**Benefits:**
- *Locality* — all file-safety invariants (path blocking, symlink escape prevention, size cap) in one place.
- *Leverage* — callers get success/failure without reasoning about each invariant.
- *Tests* — operations testable without an HTTP stack; path-blocking edge cases testable directly.

---

### 5. Unify subprocess execution behind a `ProcessRunner` ✓ Done — #18, #19, #20, #21

**Files:**
- `app/services/mbeditor/git_service.rb` (`run_git`)
- `app/services/mbeditor/test_runner_service.rb` (`execute_with_timeout`)
- `app/controllers/mbeditor/editors_controller.rb` (`run_with_timeout`)

**Problem:** Three slightly different implementations of "run a subprocess with a timeout, kill the process group on expiry, return stdout/stderr." Similar enough to be confusing but different enough that a fix in one won't land in the others.

**Deletion test:** Delete `TestRunnerService`'s timeout logic — the pattern reappears identically in the controller.

**Solution:** A `ProcessRunner` module/class: `call(cmd, timeout:, env: {})` → `{ stdout:, stderr:, exit_status: }`. Kills the process group on timeout. All subprocess sites use it.

**Benefits:**
- *Locality* — process lifecycle bugs (zombie processes, signal races) concentrated in one place.
- *Leverage* — callers specify command and timeout; get structured output.
- *Tests* — timeout behavior testable once, with stubs, rather than per-service.

---

## Summary

| # | Candidate | Effort | Impact | Status |
|---|-----------|--------|--------|--------|
| 1 | `GitInfoService` | Medium | High | ✓ Done (#4–6) |
| 2 | `CodeSearchService` | Medium | Medium | ✓ Done (#7–10) |
| 3 | `ExclusionMatcher` | Low | High | ✓ Done (#11–14) |
| 4 | `FileOperationService` | Medium | Medium | ✓ Done (#15–17) |
| 5 | `ProcessRunner` | Low | Medium | ✓ Done (#18–21) |

All candidates implemented 2026-05-17. Suite grew from 132 tests / 580 assertions to 403 / 1425.
