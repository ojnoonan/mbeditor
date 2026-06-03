## Realtime collaborative editing (pairing)

When Action Cable is available, two people can edit the same files together with live cursors and converged content. It activates automatically and stays inert (single-user, native undo) when cable is unavailable.

- Shared Yjs document per file relayed over a per-file `CollaborationChannel`; the server stores opaque CRDT bytes only (`CollaborationDocStore`)
- Remote carets, selections, and labelled participant identity (`user_name_callback` config); presence roster with click-to-jump and follow mode
- Manual-save reconciliation across peers; on-save snapshot compaction keeps the server buffer small
- Server memory stays bounded over long sessions: idle rooms are reclaimed by an opportunistic, throttled sweep, with a grace window so a briefly-closed file is still recoverable on quick reopen
- An external on-disk edit by another tool never silently clobbers the live shared buffer — collab-bound files are skipped by external-change detection (the CRDT is authoritative while peers edit)
- `authenticate_with` now also runs on the WebSocket handshake: a hook that halts or raises rejects the collaboration / editor socket (fail-closed)
- **Pairing is a deliberate exception to the localhost-only rule** — expose it only via a trusted tunnel / LAN, set `authenticate_with`, and configure `action_cable.allowed_request_origins`. See the README "Collaborative pairing" section.

## Persistent undo history per branch

Undo history is now persisted on the server per file per branch. Reloading the editor or switching VMs restores full Ctrl+Z history back to the first edit on that branch.

- Edit operations are captured client-side (`HistoryService`) and flushed on save, tab close, page hide, and unload
- History files stored in `tmp/mbeditor_history/` as compact JSON op logs
- History replayed in the background after file open (two-phase load) — file is immediately usable while history restores
- Saves to disk do not clear history; undo past a save works correctly
- History pruned automatically on branch deletion and after 7 days of inactivity
- Large op logs compacted automatically (oldest ops folded into base content)
