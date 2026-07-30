# Drag-and-drop external file import

**Date:** 2026-07-22
**Status:** Approved, not yet implemented

## Problem

The file explorer supports dragging nodes onto folders to move them within the
workspace. It cannot accept files dragged in from outside the browser. Getting a
file into the workspace today means leaving the editor for a terminal or Finder.

## Goal

Dragging files or folders from the operating system onto the explorer imports
them into the workspace, with explicit handling when the target path already
exists.

## Scope

In scope:

- Text and binary files (images, PDFs, fonts, archives — any byte content).
- Recursive folder drops, recreating the directory structure.
- Conflict resolution: overwrite, keep both, or skip.
- Drop onto a folder row (imports into that folder) or onto the empty area
  below the tree (imports into the workspace root).

Out of scope:

- Dropping onto a file row. Only folder rows and the empty area are targets.
- Uploading from a file picker button. Drag-and-drop only.
- Progress bars for large batches. Batches are capped small enough that a
  spinner suffices.

## Architecture

Three new pieces and two edits to existing files:

| Piece | Kind | Responsibility |
| --- | --- | --- |
| `Mbeditor::FileImportService` | new service | Write imported entries to disk, resolve conflicts |
| `POST /mbeditor/import` | new route + controller action | Validate paths, enforce batch limits, delegate to the service |
| Import-conflict modal | new UI in `MbeditorApp.js` | Present conflicts, collect the user's decision |
| `FileTree.js` | edit | Detect external drops, walk dropped directories |
| `MbeditorApp.js` | edit | Orchestrate the two-pass upload |

### Conflict protocol

The client uploads in up to two passes.

1. **Pass one** sends every entry with `on_conflict=ask`. The server writes
   entries whose target path is free and returns the rest as `conflicts`,
   leaving them untouched on disk.
2. If `conflicts` is non-empty the client opens the modal. The user's choice
   drives **pass two**, which re-sends only the conflicting entries with
   `on_conflict=overwrite` or `on_conflict=rename`. Choosing skip ends the
   flow with no second request.

The existence check and the write happen inside the same server call, so there
is no window between checking and writing. The cost is that conflicting files'
bytes travel twice; non-conflicting files are sent once.

This was chosen over a separate preflight endpoint (two routes, and a race
between check and write) and over extending `create_file` with base64 JSON (one
request per file, 33% payload inflation, and an endpoint whose contract already
means "must not exist").

## Backend

### `Mbeditor::FileImportService`

Lives in `app/services/mbeditor/file_import_service.rb`, alongside
`FileOperationService`, and follows the same shape: constructed with the
workspace root, returns relative paths, raises typed errors.

```ruby
FileImportService.new(workspace_root).import(entries, on_conflict:)
```

`entries` is an array of `{ target_path:, io: }` where `target_path` is an
absolute path already cleared by `resolve_path`, and `io` responds to `read`
and `size` (an `ActionDispatch::Http::UploadedFile` in practice).

`on_conflict` is one of:

- `:ask` — write entries whose target does not exist; collect the others into
  `conflicts` without touching disk.
- `:overwrite` — write every entry, replacing existing files.
- `:rename` — for a conflicting target, find the first free name by inserting
  a counter before the extension: `logo.png` → `logo 2.png` → `logo 3.png`.
  The search starts at 2 and increments until a free name is found.

Return value:

```ruby
{
  imported:  [{ path: "app/assets/logo.png", name: "logo.png" }, ...],
  conflicts: [{ path: "app/assets/logo.png" }, ...],
  errors:    [{ path: "vendor/big.zip", error: "File too large" }, ...]
}
```

Per-entry rules:

- Reuse `FileOperationService::MAX_FILE_SIZE_BYTES` (5 MB). An oversized entry
  becomes an `errors` element; it does not abort the batch.
- `FileUtils.mkdir_p` on the target's dirname so nested folder drops create
  their intermediate directories.
- A conflicting target that is a **directory** is always an error, never
  overwritten, regardless of `on_conflict`.

### `POST /mbeditor/import`

Route added to `Mbeditor::ROUTE_MAP` (`post 'import', to: 'editors#import'`),
which keeps the engine route set and the private route set in sync.

Multipart request. Parameters:

- `files[]` — the uploaded file bodies.
- `paths[]` — parallel array of workspace-relative target paths, one per file.
- `on_conflict` — `ask`, `overwrite`, or `rename`; anything else is rejected.

The action:

1. Rejects the request if `files` and `paths` differ in length.
2. Enforces batch limits: **100 files** and **50 MB total**. Exceeding either
   returns `422` with a message naming the limit. This keeps an accidental
   `node_modules` drop from stalling the server. The file count sits below
   Rack's `multipart_part_limit` (128 file parts), which is enforced during
   param parsing — a larger batch would raise `MultipartPartLimitError` outside
   the action and surface as a `500` rather than this `422`.
3. Runs each `paths[i]` through `resolve_path` and
   `path_blocked_for_operations?`. A path that fails either check becomes an
   `errors` element for that entry; the rest of the batch proceeds.
4. Delegates to `FileImportService`.
5. Calls `broadcast_files_changed(written_paths)` so other connected tabs
   refresh their trees.

The action is a non-GET request, so `verify_mbeditor_client` already requires
the `X-Mbeditor-Client: 1` header and a same-origin `Origin`/`Referer`. No new
security surface beyond what `resolve_path` already guarantees.

Response is the service's hash rendered as JSON, always `200` when the batch
was structurally valid — per-entry outcomes live in `imported`, `conflicts`,
and `errors`. Structural failures (length mismatch, limits exceeded, bad
`on_conflict`) return `422`.

## Frontend

### `FileTree.js` — drop detection

The existing `onDragOver` / `onDrop` handlers on folder rows gain an external
branch. The discriminator is `e.dataTransfer.types.includes('Files')`: internal
node drags carry `text/plain` JSON and no `Files` entry, so the existing move
path is untouched.

External drags set `dropEffect = 'copy'` and apply a `.drag-over-external`
class, visually distinct from the move-target `.drag-over`.

A drop zone on the tree's root container catches drops that miss every row —
the empty space below the last node — and targets the workspace root. Row
handlers already call `stopPropagation`, so the container only sees drops that
genuinely missed.

### Directory walking

Dropped directories are expanded with `DataTransferItem.webkitGetAsEntry()`.
For each entry:

- A file entry yields `{ file, relativePath: entry.fullPath }`.
- A directory entry is read with `createReader().readEntries()`, recursing into
  children. `readEntries` returns at most 100 entries per call, so it is called
  repeatedly until it yields an empty array.

The walk is asynchronous and must complete before the upload begins, because
`dataTransfer` items are only valid during the drop event's synchronous phase —
`webkitGetAsEntry()` is therefore called on every item up front, before any
`await`.

Where `webkitGetAsEntry` is unavailable, fall back to `dataTransfer.files`,
which is flat: files import, folders are silently absent. Surface a note when
the fallback is used and the drop contained something that produced no files.

### `MbeditorApp.js` — orchestration

`handleImportFiles(entries, targetFolderPath)`:

1. Joins `targetFolderPath` with each entry's `relativePath` to form the target
   paths, normalising away the leading slash `fullPath` carries.
2. Builds `FormData` and posts to `/import` with `on_conflict=ask`, through the
   existing axios instance (which already sets `X-Mbeditor-Client`).
3. If the response has conflicts, opens the modal, retaining the original
   `File` objects so pass two needs no re-read from disk.
4. On resolution, posts pass two with only the conflicting entries.
5. Refreshes the tree and reports the outcome through the existing status/toast
   path: how many imported, how many skipped, how many failed.

Passed to `FileTree` as `onImportFiles`, mirroring the existing `onMove` prop.

### Import-conflict modal

Follows the existing `schema-modal` pattern in `MbeditorApp.js`: an overlay
element that closes on click-outside and Escape, with styles added to
`editor.css` next to the schema modal rules.

Contents:

- A heading naming the count: "3 files already exist".
- The conflicting paths, listed. Above 10, the list scrolls.
- Three actions: **Overwrite all**, **Keep both**, **Skip**. Escape and
  click-outside are equivalent to Skip.
- Any `errors` from pass one render in the same modal, below the conflicts, so
  a batch that both conflicts and fails needs one dialog rather than two.

Per-file toggles are deliberately omitted: batch-level actions cover the real
cases, and the three-way choice stays legible.

## Error handling

- Per-entry failures collect into `errors` and never abort the batch.
- Zero imports and non-empty errors → error toast rather than the modal, since
  there is nothing to resolve.
- A batch rejected for exceeding the file-count or total-size limit reports the
  limit it hit, so the user knows to drop a smaller selection.
- Network or server failure surfaces through the existing axios error path.

## Testing

`FileImportService` unit tests:

- Each `on_conflict` mode against a pre-existing target.
- Rename collision chains: `logo.png` with `logo 2.png` already present yields
  `logo 3.png`.
- Nested directory creation from a folder-shaped entry list.
- Oversized entry becomes an error while its siblings import.
- A target resolving outside the workspace root is rejected.
- A conflicting target that is a directory is an error under every mode.

Controller tests using `fixture_file_upload`:

- Binary round-trip: uploaded bytes equal bytes on disk.
- A path caught by `path_blocked_for_operations?` is rejected as an entry error.
- File-count and total-size limits return `422`.
- Missing `X-Mbeditor-Client` header is rejected.
- Mismatched `files`/`paths` lengths return `422`.

Tests run against `Dir.mktmpdir` as workspace, matching
`editors_controller_test.rb`.

The repo has no JS test harness, so `FileTree.js` and the modal are verified
manually in `test/dummy`: single file, multiple files, nested folder, conflict
in each of the three modes, drop on empty area, and an oversized file.
