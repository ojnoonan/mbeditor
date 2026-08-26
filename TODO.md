# TODO — mbeditor

Work is tracked in **GitHub Issues** on `ojnoonan/mbeditor` (see
`docs/agents/issue-tracker.md`). This file is for scratch notes that haven't
been filed as issues yet, plus a pointer at what is currently open.

Last reviewed: 2026-08-26 (against `main` @ 230ab27, v0.13.0).

---

## New from the 2026-08-26 review — unfiled

Verified against current `main`. Ordered roughly by severity.

**`ProcessRunner` can hang forever when called with `timeout: nil`.**
`app/services/mbeditor/process_runner.rb:56-57` join the stdout/stderr reader
threads unbounded. The grandchild-inherited-pipe hazard is real and documented
in the method's own comment — but the deadline-bounded joins only exist inside
the `if timeout` branch. With timeouts disabled (`git_timeout` /
`search_timeout` set nil), any child that leaks a pipe-holding grandchild pins
the request thread forever. Secondary, same file: `stdin.write(stdin_data)`
runs *before* the reader threads start, so a large `stdin_data` to a child that
doesn't drain stdin first deadlocks before the timeout logic ever engages.

**`EditorsController#ruby_lsp` hands the diagnostics translator a different
URI than the one the client sent.**
`editors_controller.rb:688` passes `"file://#{path}"` (raw, unescaped), while
`RubyLspClient#file_uri` (`lib/mbeditor/ruby_lsp_client.rb:231-233`) puts
percent-escaped URIs on the wire. `LspDiagnosticsTranslator.sanitize_code_actions`
compares each embedded edit's `textDocument.uri == uri`, so on any workspace
whose path contains a character `URI_PARSER.escape` changes (a space is enough),
every RuboCop quick-fix carried by diagnostics is silently dropped. The
comment on that line ("it must be the same string the client sent") states the
invariant the code violates. Fix: route it through the same escaping.

**`SearchReplaceService#replace` can corrupt a file when its per-file timeout
fires mid-write.**
`search_replace_service.rb:162-179` wraps read/gsub/`File.binwrite` in
`Timeout.timeout(PER_FILE_TIMEOUT)`. A timeout landing inside the blocking
write leaves a truncated file with no error surfaced beyond "Timed out
processing file". Write to a sibling temp file and rename, the way
`FileOperationService#atomic_write` already does.

**`PresenceRegistry` relays client-supplied strings with no size cap.**
`presence_registry.rb:41-50` slices `RELAYED_FIELDS` but never bounds their
lengths. Any subscribed client can heartbeat a megabyte `name` or
`current_file`, which every peer then receives on every roster broadcast.
Cap field sizes server-side at `record`.

**`ExceptionLog` entries can be displayed out of order.**
Minor follow-up to the fixed seq bug: `record` allocates `id` under `MUTEX`
inside `build` (line 51), then re-acquires the mutex separately to append
(lines 30-34). Two concurrent exceptions can append out of seq order, and
`entries` reverses insertion order, so the panel can show the older exception
above the newer one. Appending inside the same critical section fixes it.

---

## Filed issues #77–#84 — status re-checked 2026-08-26

The recent fix commits (`faee157`, `800e4ef`, `d024f47`, `ec53185`) landed.
Current state:

| # | Status | Note |
|---|---|---|
| #77 | Partial | `health` is now deliberately lock-free so the status chip escapes the stall, but `ready?`/`request_with_document` callers still queue behind a failed handshake holding `@state_mutex` up to 15 s (`ensure_started` → `start_locked`). |
| #78 | **Fixed** | `@doc_mutex` covers sync + write only; the wait is outside, and timed-out requests send `$/cancelRequest`. |
| #79 | **Fixed** | Changed documents are didClose'd + didOpen'd; `@docs` cleared on cleanup/start. Distinct-open growth until process exit is inherent LSP-session behaviour. |
| #80 | **Fixed** | `SchemaService` checks `SafePath.within?`; the controller additionally guards `model` against `RUBY_CONSTANT_PATH`. |
| #81 | Open | Verified still present: `restart_allowed?` returns false once `@crash_times.length >= MAX_RESTARTS` (3), so index 2 (25 s) of `RESTART_BACKOFFS` is unreachable. |
| #82 | Partial | A *missing* babel asset is cached as `:none`. A present-but-broken one still fails `context()` on every save with no negative latch — full `File.read` + eval of the bundle per save. |
| #83 | Partial | Program/global gathering moved outside the mutex and each eval is bounded at 2 s, but the single global `MUTEX` still serializes all save-time JS work. |
| #84 | Open | Verified: per-file test results (`MbeditorApp.js:3534`) still have no eviction or size cap; the suite cache got a raw-output cap only. Quota exhaustion silently kills draft backup (`_saveDraftNow`). |

---

## Unfiled — docs

**`AGENTS.md`/`CLAUDE.md` test counts are stale** — they say `495 tests,
1681 assertions`; the suite outgrew that long ago (last recorded count was
889 runs / 2927 assertions at the previous review). Worth running the suite
once and writing the real number in.

**`CONTEXT.md` glossary gaps** (carried over, still true): no entry for model
graph, file import / conflict protocol, exception log, the ruby-lsp bridge, or
the JS program.

---

## Unfiled — review coverage

**Frontend still has no architecture review**, and the god-file grew again:

| File | Lines (was) |
|---|---|
| `components/MbeditorApp.js` | 7,070 (5,962) |
| `editor_plugins.js` | ~2,400 |
| `components/EditorPanel.js` | ~2,400 |

`EditorsController` is back up to **2,004 lines** (was 1,772 at the W21
follow-up) — the ruby-lsp passthrough, rename, import and model-graph endpoints
all landed in the controller rather than behind services. Same seam question as
before.

The 2026-07-30/31 feature block plus everything since (resilient routing,
pending-migration bypass, suite runner, RuboCop workspace run) has had no
dedicated robustness pass; this review covered the backend service layer and
controllers at read-depth, the frontend only at spot-check depth.

---

## Resolved since the last review (kept for the record)

- 0.13.0 shipped 2026-08-20; `[Unreleased]` is empty and the missing-changelog
  complaint is moot.
- Collaboration epic merged: `CollaborationDocStore` and `PresenceRegistry`
  are on `main`; the `pair_programming` branch is 37 behind with nothing
  unique left to hold hostage. Delete it after confirming zero unique commits.
- The 0.1.0 "collaborative editing via Y.js CRDT" changelog claim is now
  *true* rather than false — no retraction needed.
- `ExceptionLog` seq-inside-mutex bug fixed (`exception_log.rb:51`).
- `.opencode/` ignore question superseded by whatever the current tree does;
  re-check before filing.

---

## Branch hygiene (stale table — re-checked 2026-08-26)

`pair_programming`: behind 37, ahead 0 — see "Resolved" above; safe to delete.
`monaco-esm-followups`, `deepseek-tests`, `restructure-to-root`: still
zero-ahead, deletable. `claude-colab` and `grok-test`: still carry 1–2 old
commits on ancient bases; inspect then drop.
