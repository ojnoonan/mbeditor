## Persistent undo history per branch

Undo history is now persisted on the server per file per branch. Reloading the editor or switching VMs restores full Ctrl+Z history back to the first edit on that branch.

- Edit operations are captured client-side (`HistoryService`) and flushed on save, tab close, page hide, and unload
- History files stored in `tmp/mbeditor_history/` as compact JSON op logs
- History replayed in the background after file open (two-phase load) — file is immediately usable while history restores
- Saves to disk do not clear history; undo past a save works correctly
- History pruned automatically on branch deletion and after 7 days of inactivity
- Large op logs compacted automatically (oldest ops folded into base content)
