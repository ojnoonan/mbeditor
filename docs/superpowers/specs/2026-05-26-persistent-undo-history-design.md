# Persistent Undo History Per Branch

**Date:** 2026-05-26  
**Status:** Approved

## Goal

Persist Monaco editor undo history per file per branch on the server so that reloading the editor (or switching machines/VMs) restores full undo history all the way back to the first edit made on that branch.

## Constraints

- No build step — plain JS only, no npm packages
- No new gem dependencies
- Must not flood the Rails server log
- History survives page reloads and VM switches
- Saves to disk do not clear history (user may want to undo past a save)

---

## 1. Data Storage

### Location

```
{workspace_root}/tmp/mbeditor_history/{branch}/{filehash}.json
```

- `{branch}` — sanitised branch name (existing `sanitize_branch_name` validation)
- `{filehash}` — first 16 hex chars of SHA256 of the relative file path (safe filename, no length limit issues)

One JSON file per (branch × file). Directory is created on first write via `FileUtils.mkdir_p`.

### File Format

```json
{
  "path": "app/models/user.rb",
  "base": "...original file content at first edit on this branch...",
  "ops": [
    [1, 1, 1, 5, "hello"],
    [2, 1, 2, 1, ""]
  ],
  "t": "2026-05-26T10:00:00Z"
}
```

Each op is `[startLine, startCol, endLine, endCol, insertedText]` — ~40 bytes each. A heavy session of 5,000 ops ≈ 200 KB per file per branch.

### Size Cap & Compaction

When the op count would exceed 10,000, the server compacts: it replays the oldest 5,000 ops into `base`, removes them from the `ops` array, and updates `t`. This keeps the file bounded while preserving the invariant `replay(base, ops) === current content`.

### Pruning

- **Branch deletion:** Extended in the existing `prune_branch_states` action — also deletes `tmp/mbeditor_history/{deleted-branch}/`.
- **TTL:** On GET, if `t` is older than 7 days, the history file is deleted and an empty response is returned.

---

## 2. Backend API

Two new actions in `Mbeditor::EditorsController`, following existing patterns exactly (file locking, `resolve_path`, `sanitize_branch_name`, `verify_mbeditor_client`).

### `GET /mbeditor/file_history`

Params: `branch`, `path`

Returns `{ base, ops }` or `{}` if no history exists yet. Runs TTL check on read.

### `POST /mbeditor/file_history`

Body: `{ branch, path, ops, base? }`

- `base` is only required on the first flush for a given branch+file (when the history file does not yet exist). Ignored on subsequent flushes.
- Appends `ops` to the stored list.
- Runs compaction if total ops exceed 10,000.
- Returns 204.

### Routes

```ruby
get  'file_history', to: 'editors#file_history'
post 'file_history', to: 'editors#save_file_history'
```

---

## 3. Log Silencing

A Rack middleware inserted before `Rails::Rack::Logger` suppresses all log output for `/file_history` requests.

**`lib/mbeditor/log_silencer.rb`:**

```ruby
module Mbeditor
  class LogSilencer
    def initialize(app) = @app = app

    def call(env)
      if env['PATH_INFO'].end_with?('/file_history')
        Rails.logger.silence { @app.call(env) }
      else
        @app.call(env)
      end
    end
  end
end
```

**`lib/mbeditor/engine.rb`** — new initializer:

```ruby
initializer 'mbeditor.log_silencer' do |app|
  app.middleware.insert_before Rails::Rack::Logger, Mbeditor::LogSilencer
end
```

`end_with?('/file_history')` is used (not a hardcoded `/mbeditor/` prefix) so it works regardless of engine mount point.

---

## 4. Client: HistoryService

New file: `app/assets/javascripts/mbeditor/history_service.js`

Responsibilities:
- Capture ops from Monaco's `onDidChangeContent` events
- Snapshot `base` content on the first op for a branch+file
- Buffer ops in memory and flush to server on trigger events
- Fetch history from server for replay

### Flush Triggers (event-driven, not polling)

| Trigger | Action |
|---------|--------|
| File save | `flush(branch, path)` |
| Tab close / switch away | `flush(branch, path)` |
| `document.visibilitychange` (hidden) | `flushAll()` |
| `window.beforeunload` | `flushAll()` (sync via `sendBeacon`) |
| 30s idle (reset on each new op) | `flush(branch, path)` |

`fetch` with `keepalive: true` is used for the `beforeunload` flush — unlike `sendBeacon`, it supports custom headers (required for `X-Mbeditor-Client: 1`) and survives page unload.

### Op Recording

All `onDidChangeContent` events are recorded, including undo and redo operations. This produces a linear op log. When replayed, Ctrl+Z steps backward through every recorded content change in order — not identical to the original undo tree, but correct for the use case of "undo all the way back to first edit on this branch."

A `replayInProgress` flag suppresses recording during Phase 2 replay to avoid polluting the op log.

---

## 5. Client: Two-Phase Load

Integrated into `EditorPanel.js` tab-open flow.

### Phase 1 — Immediate (synchronous)

Create or reuse Model A with the current file content from the server. Attach to editor. File is immediately readable and editable.

### Phase 2 — Background (after `requestIdleCallback`)

1. Call `HistoryService.fetchHistory(branch, filePath)`
2. If `null` or empty ops, done — no history to restore
3. Create Model B (detached) with `base` content
4. Set `replayInProgress = true`
5. Replay each op onto Model B via `model.pushEditOperations()` — builds Monaco's undo stack without touching the editor
6. Set `replayInProgress = false`
7. Verify `modelB.getValue() === currentContent`. On mismatch: dispose B, bail silently (file works, just no history)
8. Capture any edits the user made to Model A during replay; apply them to Model B via `pushEditOperations`
9. Save view state → `editor.setModel(modelB)` → restore view state → dispose Model A → update `window.__mbeditorModels` cache entry

The swap in step 9 is imperceptible: same text content, cursor and scroll position preserved.

---

## 6. Error Handling

| Scenario | Behaviour |
|----------|-----------|
| Server returns error on GET | Phase 2 bails silently; file works without history |
| Content mismatch after replay | Dispose Model B, bail silently |
| Server returns error on POST | Ops remain in local buffer; next flush retries |
| History file corrupt/unparseable | Server deletes it, returns `{}`; fresh history starts |
| `pushEditOperations` throws | Caught; dispose Model B, bail silently |

No error is ever surfaced to the user — history is best-effort, the editor always works.

---

## 7. Files Affected

| File | Change |
|------|--------|
| `lib/mbeditor/log_silencer.rb` | New — Rack middleware |
| `lib/mbeditor/engine.rb` | Add `log_silencer` initializer |
| `config/routes.rb` | Add 2 new routes |
| `app/controllers/mbeditor/editors_controller.rb` | Add `file_history` + `save_file_history` actions; extend `prune_branch_states` |
| `app/assets/javascripts/mbeditor/history_service.js` | New — capture, buffer, flush, fetch |
| `app/assets/javascripts/mbeditor/components/EditorPanel.js` | Wire `onDidChangeContent` → HistoryService; add two-phase load |
| `app/assets/javascripts/mbeditor/tab_manager.js` | Call `HistoryService.flush` on tab close/switch |
| `app/assets/javascripts/mbeditor/components/MbeditorApp.js` | Call `HistoryService.flushAll` on save + visibilitychange + beforeunload |

---

## 8. Testing

- **Unit:** `history_service.js` — op recording, flush triggers, base-capture-once behaviour
- **Controller tests:** `file_history` GET/POST, TTL pruning, compaction at 10,000 ops, path sandbox validation, branch name validation
- **Integration:** Open file, make edits, reload, verify undo steps back through recorded ops
- **Mismatch fallback:** Corrupt ops → editor opens normally with no history
