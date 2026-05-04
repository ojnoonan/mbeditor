# Design: Large File Pagination & JSON Pretty-Print

**Date:** 2026-04-30

## Context

Mbeditor currently enforces a hard 5 MB cap on file reads (`MAX_OPEN_FILE_SIZE_BYTES`). Files over this limit return HTTP 413 with an error message and cannot be viewed. Users need to view files larger than this (confirmed case: 11.4 MB file). Separately, JSON files are often stored minified (all on one line), making them unreadable in the editor despite Monaco's built-in JSON syntax highlighting being active.

---

## Feature 1: Large File Pagination (View-Only)

### Goal

Files that exceed the 5 MB cap open in a read-only paginated mode (500 lines per page) rather than showing an error. The user can page through the file using Prev/Next controls.

### Backend — `editors#show` (`app/controllers/mbeditor/editors_controller.rb`)

Extend the existing `GET /mbeditor/file` endpoint with two optional query params:

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `start_line` | integer | — | 0-indexed line to start reading from |
| `line_count` | integer | 500 | Number of lines to return |

When `start_line` is present:
- Skip the `MAX_OPEN_FILE_SIZE_BYTES` size check
- Single-pass read: one `File.foreach` call that both extracts the requested line slice and counts `total_lines` — the file is never fully buffered in memory and never read twice
- Return extended JSON:

```json
{
  "path": "path/to/file",
  "content": "...500 lines...",
  "truncated": true,
  "start_line": 0,
  "line_count": 500,
  "total_lines": 8432,
  "total_bytes": 11943936
}
```

Security: `resolve_path` still validates the path. No size cap bypass for write actions.

### Frontend — File Service (`app/assets/javascripts/mbeditor/file_service.js`)

Add:

```javascript
FileService.getFileChunk(path, startLine, lineCount = 500)
// GET /mbeditor/file?path=...&start_line=N&line_count=500
```

### Frontend — Tab Manager (`app/assets/javascripts/mbeditor/tab_manager.js`)

In `openTab`, when `FileService.getFile` returns a 413 response, automatically retry with `FileService.getFileChunk(path, 0, 500)`. Tab state gains fields:

```javascript
{
  truncated: true,
  startLine: 0,
  lineCount: 500,
  totalLines: 8432,
  totalBytes: 11943936
}
```

### Frontend — Editor Panel (`app/assets/javascripts/mbeditor/components/EditorPanel.js`)

When `tab.truncated` is true:

- Set Monaco to read-only: `editor.updateOptions({ readOnly: true })`
- Render a pagination bar (below the existing toolbar) showing:
  `Lines 1–500 of 8,432  (11.4 MB)  [← Prev]  [Next →]`
- Prev/Next buttons call `FileService.getFileChunk` with updated `startLine` and replace Monaco content
- First page: Prev is disabled. Last page: Next is disabled.

### No new routes needed

The existing `GET /mbeditor/file` route is extended in place.

---

## Feature 2: JSON Auto Pretty-Print on Open

### Goal

JSON files are automatically formatted (2-space indented) when opened. Monaco's built-in JSON syntax highlighting (already active for `.json` files) then applies to the readable structure. Invalid JSON falls back to raw display.

### Frontend only — Editor Panel (`app/assets/javascripts/mbeditor/components/EditorPanel.js`)

In the content initialization path, before `editor.setValue(content)`, intercept JSON files:

```javascript
if (language === 'json') {
  try {
    content = JSON.stringify(JSON.parse(content), null, 2);
  } catch (_) {
    // invalid JSON — use raw content, Monaco will show error markers
  }
}
```

**Dirty tracking:** Because the formatted string is passed to the initial `setValue`, the AVI baseline is set to the formatted version. The file only appears "unsaved" if the user edits it afterward. Saving writes the formatted JSON to disk (expected and desirable behavior).

**No backend changes needed.**

---

## Files to Modify

| File | Change |
|------|--------|
| `app/controllers/mbeditor/editors_controller.rb` | Add `start_line`/`line_count` params to `show`, add chunk-read logic |
| `app/assets/javascripts/mbeditor/file_service.js` | Add `getFileChunk()` method |
| `app/assets/javascripts/mbeditor/tab_manager.js` | Handle 413 → retry as chunk; store pagination state in tab |
| `app/assets/javascripts/mbeditor/components/EditorPanel.js` | Pagination bar UI, read-only mode, JSON pre-format |

---

## Verification

1. **Large file pagination:**
   - Open a file > 5 MB — editor enters paginated read-only mode instead of showing an error
   - Pagination bar shows correct line range and total
   - Next/Prev navigate correctly; buttons disable at boundaries
   - File cannot be edited (Monaco read-only)
   - Files under 5 MB open normally (no regression)
   - Backend test: `GET /mbeditor/file?path=...&start_line=100&line_count=50` returns correct slice

2. **JSON pretty-print:**
   - Open a minified JSON file — content is formatted with 2-space indent on load
   - File does not appear dirty (no unsaved indicator) after open
   - Open an invalid JSON file — raw content displayed, Monaco shows error markers
   - Syntax highlighting (colors) visible on the formatted output

3. **Run full test suite:** `bundle exec rake test` — all 132 tests pass
