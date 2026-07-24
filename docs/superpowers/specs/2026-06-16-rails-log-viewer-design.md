# Rails Log Viewer — Design

**Date:** 2026-06-16
**Status:** Approved, pending implementation plan

## Problem

Developers using the mounted editor have no way to see the running Rails
server's output without leaving the browser and switching to the terminal that
launched `rails server`. An integrated terminal is not an option — other users
can reach the editor, and the only thing gating them is the host app's auth, so
a shell would be a privilege-escalation hole. A **read-only view of the Rails
log** gives the useful 90% (request logs, SQL, errors, app logging) with no
command-execution surface.

## Scope

The mounted engine does **not** own the `rails server` process, so it cannot
capture the process's raw stdout/stderr (boot banner, bare `puts`, etc.). It
**can** read everything that goes through `Rails.logger`, which lands in
`log/<env>.log`. v1 tails that file.

### In scope
- Tail the active environment's log file: `Rails.root.join('log', "#{Rails.env}.log")`.
- Incremental, offset-based reads with rotation/truncation handling.
- Real-time push over the existing ActionCable channel, with an HTTP polling fallback.
- A bottom-drawer UI panel: auto-scroll, pause-on-scroll-up, clear, substring filter.
- Logs shown raw (no redaction), with a documented caveat.

### Explicitly out of v1 (YAGNI)
- Raw server stdout capture (not feasible from inside the engine).
- Multi-file / multi-env picker (fixed to the active env log).
- Secret redaction.
- ANSI colorization (codes are **stripped** in v1).
- Full DOM virtualization (bounded buffer instead).
- Settings/preferences entries.

## Architecture

Follows the existing `EditorStateService` pattern: one service used by **both**
the HTTP controller and the ActionCable channel.

### Backend

**`Mbeditor::LogTailService`** (pure Ruby, no subprocess)
- `log_path` → `Rails.root.join('log', "#{Rails.env}.log")`, run through
  `resolve_path()` for consistency with the codebase's path-safety invariant.
  (The path is fixed, not user-supplied, so this is belt-and-suspenders.)
- `read_since(offset)` → `{ lines: [String], offset: Integer, reset: Boolean }`
  - Reads from `offset` to EOF.
  - Caps bytes per read (~256 KB) to bound payload size; advances offset by the
    bytes actually consumed so the next call resumes cleanly.
  - **Rotation/truncation:** if current file size `< offset`, the file was
    rotated or truncated → reset offset to 0 and set `reset: true` so the client
    clears its buffer.
  - Missing file → empty result, `offset: 0` (no error).
- Initial load: `read_since(nil)` (or a `tail(max_bytes:)` helper) returns the
  last ~N KB of the file plus the current EOF offset, so the panel opens with
  recent context rather than an empty pane.

**`Mbeditor::LogsController#tail`**
- `GET /logs/tail?offset=<int>` → JSON `{ lines, offset, reset }` from
  `LogTailService`.
- Serves both the **initial load** (omit/`offset=` → tail of file) and the
  **HTTP fallback** poll.
- GET request, so the `X-Mbeditor-Client` write-guard does not apply; access is
  gated by the host app's auth like every other editor route.

**Push via `Mbeditor::EditorChannel`** (no new threads, no shared broadcaster)
- Uses ActionCable's idiomatic `periodically` timer.
- New actions `start_log_tail(data)` / `stop_log_tail` toggle an instance flag
  `@log_watching` and seed `@log_offset` (from the client's last-known offset, or
  a fresh tail).
- `periodically :push_log_lines, every: 1.second` — the method returns
  immediately unless `@log_watching`; otherwise it calls
  `LogTailService.read_since(@log_offset)`, and if there are new lines,
  `transmit`s `{ type: 'log', lines:, offset:, reset: }` directly to this
  subscriber and updates `@log_offset`.
- Per-subscriber state — no cross-client broadcast, no refcounting.

### Frontend

**`LogPanel.js`** — bottom drawer (resizable height, toggleable)
- Chosen over a modal (`TestResultsPanel` style) because logs are watched
  *while* editing; a modal would block the editor.
- Features: auto-scroll to tail; pause auto-scroll when the user scrolls up
  (resume on scroll-to-bottom or a button); clear; substring filter box.
- Renders plain text with ANSI escape sequences stripped.

**`LogService.js`** — client transport
- Primary: subscribe via the existing websocket service, sending
  `start_log_tail` on open and `stop_log_tail` on close; append transmitted
  lines.
- Fallback: when the WebSocket is unavailable, `axios`-poll `/logs/tail?offset=`
  on an interval.
- Tracks `offset`; on `reset: true` clears the buffer.
- Caps the in-memory/DOM buffer (~2000 lines, drop oldest) to keep rendering
  light; full virtualization deferred.

**Wiring**
- Toggle exposed via a sidebar icon, a keyboard shortcut, and a `ShortcutHelp`
  row.

## Data flow

1. User toggles the Log drawer.
2. Client fetches `GET /logs/tail` for initial context → renders last N KB,
   stores `offset`.
3. Client sends `start_log_tail` over the channel (or starts HTTP polling if no
   WS).
4. Every ~1s the channel's periodic method reads new bytes since `@log_offset`
   and `transmit`s them; client appends and auto-scrolls.
5. On rotation/truncation the service returns `reset: true`; client clears and
   continues from offset 0.
6. Closing the drawer sends `stop_log_tail` (or stops polling).

## Error handling
- Missing log file → empty stream, no error surfaced (file may not exist yet).
- Rotation/truncation → `reset` flag, client re-syncs.
- Oversized reads → byte cap per read; remaining bytes arrive on the next tick.
- WebSocket unavailable → automatic HTTP polling fallback.

## Security
- Read-only; no command execution.
- Same gating as the rest of the editor: host-app auth + (for writes, N/A here)
  `X-Mbeditor-Client`.
- Reads only the fixed env log path; path resolved via `resolve_path()`.
- **Logs may contain secrets** (request params, tokens, SQL values). Shown raw
  by design. Documented in CHANGELOG + a note in CLAUDE.md / CONTEXT.

## Testing
- **`LogTailService`** unit tests: incremental read advances offset; multiple
  reads concatenate correctly; rotation/truncation resets offset with
  `reset: true`; byte cap splits a large append across reads; missing file
  returns empty; initial tail returns the last N KB.
- **`LogsController#tail`**: returns `{ lines, offset, reset }`; offset advances
  across successive requests as the file grows.
- **`EditorChannel`** log-tail action: `start_log_tail` begins transmitting new
  lines; `stop_log_tail` halts them. (First EditorChannel test coverage —
  closes an existing gap.)
- **System test (optional):** open the drawer, append to the log, see lines
  stream in.

## Open questions
None — design approved.
