# VSCode-style UX features

Date: 2026-07-16

Four independent editor enhancements modelled on VSCode, built on existing mbeditor
infrastructure (`TabBar`, `QuickOpenDialog`, `TabManager`, `FileTree`, `FileService`,
Monaco boot in `EditorPanel`).

## 1. Color swatches + picker (all files)

**Goal:** show a clickable colored square before color literals in any file; clicking it
opens Monaco's built-in color picker, and choosing a color rewrites the literal.

**Approach:** register a Monaco `DocumentColorProvider`.

- New file `app/assets/javascripts/mbeditor/color_provider.js` exporting a single
  `registerMbeditorColorProvider(monaco)` function (idempotent — guard against double
  registration).
- Register for every registered language (`monaco.languages.getLanguages()`) **except**
  `css`, `scss`, `less` — Monaco's own language services already provide color decorators
  and a picker for those, and double-registering would duplicate swatches.
- `provideDocumentColors(model)`: scan each line for:
  - hex: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`
  - functional: `rgb(...)`, `rgba(...)`, `hsl(...)`, `hsla(...)`
  Return `{ range, color: {red, green, blue, alpha} }` with channels normalized to 0–1.
- `provideColorPresentations(model, colorInfo)`: return presentations that write the color
  back. Preserve the original notation family where practical (a hex literal stays hex; an
  `rgb()`/`rgba()` literal stays functional). Default to hex when ambiguous.
- Wire once at Monaco boot in `EditorPanel.js`, immediately after Monaco is available, by
  calling `registerMbeditorColorProvider(monaco)`.

**Notes / guards:**
- Regexes must be bounded and applied per line (no catastrophic backtracking).
- Parsing tolerates whitespace inside functional notations; ignores invalid ranges.

## 2. Top-bar search box → recent files, then fuzzy search

**Goal:** a VSCode-like search box in the title bar. Clicking it opens the quick-open
dialog; when the query is empty it lists recently opened files; typing runs the existing
fuzzy workspace search.

**Approach:**

- **Recent-files tracking (new):** small helper (in `tab_manager.js` or a tiny module) that
  persists opened file paths to `localStorage` key `mbeditor_recent_files` as an ordered
  list (most-recent first), deduped, capped at 12. Push the path from `TabManager.openTab`
  when a real file tab opens (skip special tabs: commit graph, diff, preview, settings).
  Expose a getter (e.g. `window.getRecentFiles()`).
- **Title-bar search box:** add a clickable, input-styled element in the `ide-titlebar`
  (centered region). Clicking it sets `isQuickOpenVisible` (the existing state that renders
  `QuickOpenDialog`). Keep the existing `Ctrl/Cmd+P` binding working — same entry point.
- **QuickOpenDialog empty state:** when `query` is empty, render a "Recently opened" section
  from `getRecentFiles()` (path list, each selectable via the existing `onSelect(path)`).
  Once the user types, fall back to the current fuzzy search results unchanged. Recent items
  reuse existing row rendering / keyboard navigation where possible.

## 3. Tab context menu: Close / Close Others / Close Saved / Close All

**Goal:** right-clicking a tab offers the four standard close actions.

**Approach:**

- **TabManager (new helpers):**
  - `closeOtherTabsInPane(paneId, keepPath)` — close every tab in the pane except `keepPath`.
  - `closeSavedTabsInPane(paneId)` — close every non-dirty tab in the pane.
  - reuse existing `closeTab(paneId, path)` for **Close** and `closeAllTabsInPane(paneId)`
    for **Close All**.
  - Follow the existing dirty-check / confirm behavior already in `closeTab` so unsaved
    tabs are handled consistently (Close Saved never prompts because it only targets
    non-dirty tabs).
- **TabBar context menu:** extend the existing menu (`tabContextMenu`) with four items —
  Close, Close Others, Close Saved, Close All — above or below the current File History /
  Find in Explorer items, with a separator. Each item closes the menu then calls the
  corresponding `TabManager` method with the tab's `paneId`/`path`. Suppress the menu for
  special tabs exactly as today (`isSpecial` guard).

## 4. `+` new-file button after the last tab

**Goal:** a small `+` button to the right of the rightmost tab that creates a new file in
the current directory.

**Approach:**

- Render a `+` button in `TabBar` after the last tab (inside the scrolling tab row, or
  pinned at the row's end). Tooltip: "New File".
- "Current directory" = the directory of the active file's path; if there is no active file
  tab, use the workspace root.
- Clicking reuses **FileTree's existing inline-create flow** (the `pendingCreate` inline
  input), pre-targeted at that directory, so filename entry, validation, creation
  (`FileService.createFile`) and auto-open match the existing tree UX exactly. This is
  wired via a callback passed from `MbeditorApp` down to `TabBar` (e.g. `onNewFile(dir)`)
  that triggers the tree's create state and expands to that directory.

## Testing

- **System tests** (`test/system/mbeditor/`): tab context-menu actions (Close, Close
  Others, Close Saved, Close All) and the `+` new-file button end-to-end.
- **Unit tests:** `TabManager.closeOtherTabsInPane` and `closeSavedTabsInPane` behavior
  (including dirty-tab handling); recent-files helper (dedupe, cap, ordering).
- **Manual/browser preview:** color swatches render + picker rewrites literals across a few
  file types (JS, HTML, Ruby); title-bar search opens quick-open showing recent files then
  fuzzy results.

## Out of scope (YAGNI)

- No named-color (`red`, `rebeccapurple`) swatches — only hex/rgb/hsl literals.
- No pinning/reordering of recent files; no cross-device sync (localStorage only).
- No new-folder button in the tab bar (folders stay in the file tree).
