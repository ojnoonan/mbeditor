# TODO — mbeditor

Work is tracked in **GitHub Issues** on `ojnoonan/mbeditor` (see
`docs/agents/issue-tracker.md`). This file is for scratch notes that haven't
been filed as issues yet, plus a pointer at what is currently open.

Last reviewed: 2026-07-31 (against `main` @ 5989669, suite green at
889 runs / 2927 assertions / 0 failures).

---

## Filed and open — 8 issues (#77–#84)

From the 2026-07-24 review. All still open; nothing has been closed since.

| # | Area | Note |
|---|---|---|
| #80 | `SchemaService` | `model_schema` builds a path from `params[:model]` without `resolve_path` — traversal. **Security; take this one first.** |
| #77 | `RubyLspClient` | A failed `initialize` handshake holds `@state_mutex` for up to 15 s, stalling every thread. `ready-for-human` |
| #78 | `RubyLspClient` | `@doc_mutex` queue wait is covered by no request timeout. `ready-for-human` |
| #79 | `RubyLspClient` | Documents are never `didClose`'d — `@docs` and the server's document set grow unbounded. |
| #81 | `RubyLspClient` | `RESTART_BACKOFFS[2]` (25 s) is unreachable under `MAX_RESTARTS = 3`. |
| #82 | `JsSyntaxCheckService` | A broken babel asset is re-read and re-evaluated on every save. |
| #83 | `JsSyntaxCheckService` | Global `MUTEX` serializes save-time checks with an unbounded wait. |
| #84 | Frontend | Test-result localStorage cache never evicts, silently disabling unsaved-draft recovery. |

Four of the eight are `RubyLspClient` lifecycle/concurrency. Worth doing as one
pass over that file rather than four separate ones.

---

## Unfiled — release and docs

**A 0.12.0 release is overdue, and `[Unreleased]` is incomplete.**
Eleven feature/fix commits have landed since `v0.11.0` (2026-07-29), but the
`[Unreleased]` section of `CHANGELOG.md` documents only drag-and-drop import.
Undocumented:

- ruby-lsp expansion — graded diagnostics + health surfacing (f6b034b), rubocop
  fixes applied straight off the diagnostic (a544210), navigation providers on
  a raw LSP passthrough (a349e30), formatting / signature help / selection
  ranges (35bb71e), workspace-wide constant rename (3a016cc)
- model graph — the ActiveRecord entity diagram (0294ec0) and its promotion to
  a central view with search and relation tooltips (693c3d3)
- host-app exceptions in the Problems panel (b07d1b9)
- assignments to undeclared variables now surface as errors (ace8bf9)
- fixes: branch diff comparing a feature branch against itself (7571382),
  bottom drawers covering the editor instead of pushing it up (150337b),
  What's New tab wiped by session restore (b20ad80)

**`CLAUDE.md` test count is stale** — it says `495 tests, 1681 assertions`;
the suite is now 889 runs / 2927 assertions.

**`CONTEXT.md` glossary has not kept up with the domain.** No entry for model
graph, file import / the conflict protocol, exception log, the ruby-lsp bridge,
or the JS program. Those are all terms the newer code and CLAUDE.md now use
freely.

**`CHANGELOG.md` 0.1.0 claims a feature that has never existed on `main`** —
"Real-time collaborative editing via Action Cable + Y.js CRDT" and "Remote
cursor and selection display during collaboration". There is no collaboration
code on `main` (no `CollaborationChannel`, no Yjs) and no `### Removed` entry
retracting it. See the branch note below.

---

## Unfiled — review coverage gaps

**The 2026-07-30/31 feature block has had no review.** Issues #77–#84 came out
of a 2026-07-24 pass, which predates all of it: the ruby-lsp provider
expansion, the model graph service and view, the exception log, and
drag-and-drop import. That is roughly 1,500 lines of new backend and frontend
code reviewed by nobody. Endpoint-level test coverage is there (14 `import`
controller tests, `model_graph_service_test.rb`, `exception_log_test.rb`), so
this is a design/robustness pass, not a coverage one.

**The frontend has never had an architecture review at all.** W20 and W21
scoped themselves to controllers, services and channels. Current shape:

| File | Lines |
|---|---|
| `components/MbeditorApp.js` | 5,962 |
| `editor_plugins.js` | 2,359 |
| `components/EditorPanel.js` | 2,355 |
| `components/FileTree.js` | 717 |

`MbeditorApp.js` is the same god-object shape W21 candidate #1 identified in
`EditorsController`, and it is three times the size. There is no build step and
no module system for app code (ADR 0001), so any decomposition has to work
within one Sprockets global scope — that constraint is what makes this worth
planning rather than just starting.

**`EditorsController` is back to 1,772 lines** despite the five W21
extractions. Not a regression in the extractions — it is the new endpoints
(`import`, `RUBY_LSP_METHODS` handling, `model_graph`) landing on top. Worth
checking whether the seams W21 established are still being used.

---

## Unfiled — small, verified

**`ExceptionLog` increments `@seq` outside the mutex.**
`lib/mbeditor/exception_log.rb:29-34` — `build` (which does
`@seq = (@seq || 0) + 1`) is called on line 29, *before* `MUTEX.synchronize` on
line 30. Two concurrent host-app 500s can be assigned the same `id`. The
frontend uses that id as a React key (`ProblemsPanel.js:235`), so duplicates
mean duplicate keys. Fix is to move the `build` call inside the existing
`synchronize` block.

**`.opencode/` is untracked and not ignored.** It carries its own
`node_modules/`. Its sibling tool directories (`.superpowers/`,
`.understand-anything/`, `graphify-out/`, `.claude/worktrees/`) are all in
`.gitignore`; this one was missed.

---

## Unfiled — branch hygiene

`main` has seven other branches hanging off it, most of them far behind:

| Branch | Ahead | Behind |
|---|---|---|
| `pair_programming` | 31 | 4 |
| `monaco-esm-followups` | 0 | 110 |
| `grok-test` | 2 | 301 |
| `deepseek-tests` | 0 | 301 |
| `claude-colab` | 2 | 384 |
| `restructure-to-root` | 0 | 413 |

**`pair_programming` is the one that matters.** It holds the entire nine-slice
collaborative-editing epic (issues #52–#60, completed 2026-06-03) — vendored
Yjs bundle, `CollaborationDocStore`, `CollaborationChannel`, the frontend
service, awareness/carets, save reconciliation, presence roster, follow mode,
and the channel-authentication hardening. Six files matching `collaboration`
exist there and nowhere else. It has been unmerged for ~2 months and is 4
commits behind, and the two-profile manual verification recorded against
slices 5–9 was never done. Decide: merge it (after the manual verify), or
close the epic out and drop the branch. Leaving it is the only option that
gets worse with time — and it is why the 0.1.0 changelog claim above reads as
false.

The zero-ahead branches (`monaco-esm-followups`, `deepseek-tests`,
`restructure-to-root`) are fully merged or abandoned and can just be deleted.
`claude-colab` and `grok-test` are 2 commits ahead of a 300–384-commit-old
base; check what those commits are, then drop them.
