# File Size Tooltip in Explorer — Design

**Date:** 2026-04-30

## Goal

When a user hovers over a file in the sidebar explorer, a native browser tooltip shows the file's workspace-relative path followed by its size in a human-readable auto-scaling format (e.g. `app/models/user.rb — 4.2 KB`). Folders show no size.

## Architecture

No new endpoints, no new components. Two small changes:

1. **Backend — `build_tree`** (`app/controllers/mbeditor/editors_controller.rb`)
   - For file entries (not directories), add `size: File.size(path)` to the returned hash.
   - `File.size` is a stat syscall — no file read, negligible overhead.

2. **Frontend — `FileTree.js`** (`app/assets/javascripts/mbeditor/components/FileTree.js`)
   - Add a `formatSize(bytes)` helper that returns a string scaled to B / KB / MB with one decimal place (e.g. `312 B`, `4.2 KB`, `1.1 MB`).
   - Update the `title` prop on each `.tree-item-name` div (currently `title={node.path}`) to append the formatted size for file nodes: `node.path + ' — ' + formatSize(node.size)`.

## Data Flow

```
build_tree → { name, type, path, size? } → FileTree props
→ title={node.path + ' — ' + formatSize(node.size)}  (files only)
→ native browser tooltip on hover
```

## formatSize Rules

| Range         | Display       | Example   |
|---------------|---------------|-----------|
| < 1 024 B     | `N B`         | `312 B`   |
| < 1 024 KB    | `N.N KB`      | `4.2 KB`  |
| ≥ 1 024 KB    | `N.N MB`      | `1.1 MB`  |

One decimal place for KB and MB; no decimal for bytes.

## Error Handling

`File.size` can raise if the file has been deleted between the directory scan and the stat call. Rescue to `nil` and omit the size field — the tooltip falls back to path-only (existing behaviour).

## Testing

- New unit test on `build_tree`: file entries include a `size` key; directory entries do not.
- Existing controller and system tests continue to pass unchanged.
