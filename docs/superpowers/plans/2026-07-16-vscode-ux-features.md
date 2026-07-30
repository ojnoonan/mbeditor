# VSCode-style UX Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four VSCode-style editor conveniences to mbeditor — inline color swatches + picker, a title-bar search box that surfaces recently opened files, a tab-bar right-click menu (Close / Close Others / Close Saved / Close All), and a `+` new-file button after the last tab.

**Architecture:** All frontend, plain-ES5 React (`React.createElement`, `var`) matching the existing transpiled style — no build step (Monaco is the only bundled exception and is untouched here). New color logic lives in a standalone module wired into Monaco boot in `EditorPanel`. Recent-files tracking is added to `TabManager` and surfaced in `QuickOpenDialog`. Tab close/new-file actions extend `TabBar` + `MbeditorApp`, reusing existing `TabManager` close primitives and the existing `confirmBulkClose` pattern.

**Tech Stack:** React 16-style global (`window.React`), Monaco (`window.monaco`), Sprockets manifest (`application.js`), Capybara/cuprite system tests (Ruby/minitest).

**Conventions to match (read before writing code):**
- Files are hand-edited transpiled ES5: `var`, `_slicedToArray`, `React.createElement`, no JSX, no arrow-only. Match surrounding style in each file.
- All component/service files are concatenated into one IIFE (`application_iife_head`/`tail`), so `TabManager`, `EditorStore`, `SearchService`, `FileService` are in-scope globals across files — reference them directly.
- New JS files must be added to the Sprockets manifest `app/assets/javascripts/mbeditor/application.js`.

---

## File Structure

- **Create** `app/assets/javascripts/mbeditor/color_provider.js` — Monaco `DocumentColorProvider` for hex/rgb/hsl in all languages. One responsibility: color literal detection + presentation.
- **Modify** `app/assets/javascripts/mbeditor/application.js` — add `//= require` for the new module.
- **Modify** `app/assets/javascripts/mbeditor/components/EditorPanel.js` — one-time registration of the color provider at Monaco boot.
- **Modify** `app/assets/javascripts/mbeditor/tab_manager.js` — recent-files persistence + `closeOtherTabsInPane` / `closeSavedTabsInPane`.
- **Modify** `app/assets/javascripts/mbeditor/components/QuickOpenDialog.js` — "Recently Opened" section in the empty state.
- **Modify** `app/assets/javascripts/mbeditor/components/MbeditorApp.js` — title-bar search box; tab context-menu handlers; `+` new-file handler; new props into `TabBar`.
- **Modify** `app/assets/javascripts/mbeditor/components/TabBar.js` — four close menu items; `+` button after the last tab.
- **Create/Modify** `test/system/mbeditor/tab_actions_test.rb` — system tests for the context menu and `+` button.

---

## Task 1: Color provider module

**Files:**
- Create: `app/assets/javascripts/mbeditor/color_provider.js`
- Modify: `app/assets/javascripts/mbeditor/application.js:11-12`

- [ ] **Step 1: Create the color provider module**

Create `app/assets/javascripts/mbeditor/color_provider.js`:

```javascript
'use strict';

// Monaco DocumentColorProvider for color literals in ALL languages except the
// CSS family (css/scss/less) — Monaco's own language services already provide
// color decorators + picker for those, so registering again would duplicate swatches.
(function () {
  var _registered = false;

  var HEX_RE = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/g;
  // rgb(), rgba(), hsl(), hsla() — bounded, no nested parens.
  var FUNC_RE = /\b(rgba?|hsla?)\(\s*[^()]{0,80}?\)/gi;

  function clamp01(n) { return n < 0 ? 0 : n > 1 ? 1 : n; }

  // Parse a hex literal into {red,green,blue,alpha} in 0..1, or null.
  function parseHex(text) {
    var h = text.slice(1);
    if (h.length === 3 || h.length === 4) {
      h = h.split('').map(function (c) { return c + c; }).join('');
    }
    if (h.length !== 6 && h.length !== 8) return null;
    var r = parseInt(h.slice(0, 2), 16);
    var g = parseInt(h.slice(2, 4), 16);
    var b = parseInt(h.slice(4, 6), 16);
    var a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    if (isNaN(r) || isNaN(g) || isNaN(b)) return null;
    return { red: r / 255, green: g / 255, blue: b / 255, alpha: a };
  }

  function parseFunc(text) {
    var fn = text.slice(0, text.indexOf('(')).toLowerCase();
    var inner = text.slice(text.indexOf('(') + 1, text.lastIndexOf(')'));
    var parts = inner.split(/[,\/\s]+/).filter(function (s) { return s.length; });
    if (parts.length < 3) return null;
    function num(p, max) {
      if (p == null) return null;
      if (p.charAt(p.length - 1) === '%') return clamp01(parseFloat(p) / 100) * max;
      return parseFloat(p);
    }
    if (fn === 'rgb' || fn === 'rgba') {
      var r = num(parts[0], 255), g = num(parts[1], 255), b = num(parts[2], 255);
      var a = parts[3] != null ? num(parts[3], 1) : 1;
      if (r == null || g == null || b == null) return null;
      return { red: clamp01(r / 255), green: clamp01(g / 255), blue: clamp01(b / 255), alpha: clamp01(a == null ? 1 : a) };
    }
    // hsl / hsla
    var h = parseFloat(parts[0]);
    var s = parseFloat(parts[1]) / 100;
    var l = parseFloat(parts[2]) / 100;
    var ha = parts[3] != null ? num(parts[3], 1) : 1;
    if (isNaN(h) || isNaN(s) || isNaN(l)) return null;
    var rgb = hslToRgb(((h % 360) + 360) % 360, clamp01(s), clamp01(l));
    return { red: rgb[0], green: rgb[1], blue: rgb[2], alpha: clamp01(ha == null ? 1 : ha) };
  }

  function hslToRgb(h, s, l) {
    var c = (1 - Math.abs(2 * l - 1)) * s;
    var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    var m = l - c / 2;
    var r = 0, g = 0, b = 0;
    if (h < 60)       { r = c; g = x; }
    else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; }
    else              { r = c; b = x; }
    return [r + m, g + m, b + m];
  }

  function to255(n) { return Math.round(clamp01(n) * 255); }

  function toHex(color) {
    function h2(n) { var s = to255(n).toString(16); return s.length === 1 ? '0' + s : s; }
    var base = '#' + h2(color.red) + h2(color.green) + h2(color.blue);
    if (color.alpha != null && color.alpha < 1) base += h2(color.alpha);
    return base;
  }

  function toRgb(color) {
    var r = to255(color.red), g = to255(color.green), b = to255(color.blue);
    if (color.alpha != null && color.alpha < 1) {
      return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + Math.round(color.alpha * 100) / 100 + ')';
    }
    return 'rgb(' + r + ', ' + g + ', ' + b + ')';
  }

  function provideDocumentColors(model) {
    var colors = [];
    var lineCount = model.getLineCount();
    for (var ln = 1; ln <= lineCount; ln++) {
      var line = model.getLineContent(ln);
      if (line.length > 2000) continue; // skip pathological lines
      collect(line, ln, HEX_RE, parseHex, colors);
      collect(line, ln, FUNC_RE, parseFunc, colors);
    }
    return colors;
  }

  function collect(line, ln, re, parse, out) {
    re.lastIndex = 0;
    var m;
    while ((m = re.exec(line)) !== null) {
      var color = parse(m[0]);
      if (!color) continue;
      var startCol = m.index + 1;
      var endCol = m.index + m[0].length + 1;
      out.push({
        range: { startLineNumber: ln, startColumn: startCol, endLineNumber: ln, endColumn: endCol },
        color: color
      });
    }
  }

  function provideColorPresentations(model, colorInfo) {
    var color = colorInfo.color;
    var original = model.getValueInRange(colorInfo.range);
    var isFunc = /^(rgb|hsl)/i.test(original);
    var primary = isFunc ? toRgb(color) : toHex(color);
    return [{ label: primary }];
  }

  function register(monaco) {
    if (_registered || !monaco || !monaco.languages) return;
    _registered = true;
    var provider = {
      provideDocumentColors: provideDocumentColors,
      provideColorPresentations: provideColorPresentations
    };
    var skip = { css: true, scss: true, less: true };
    (monaco.languages.getLanguages() || []).forEach(function (lang) {
      if (skip[lang.id]) return;
      try { monaco.languages.registerColorProvider(lang.id, provider); } catch (e) {}
    });
  }

  window.MbeditorColorProvider = { register: register };
})();
```

- [ ] **Step 2: Add the module to the Sprockets manifest**

In `app/assets/javascripts/mbeditor/application.js`, add the require after `tab_manager` (line 11) and before `editor_plugins`:

```
//= require mbeditor/tab_manager
//= require mbeditor/color_provider
//= require mbeditor/editor_plugins
```

- [ ] **Step 3: Register the provider at Monaco boot**

In `app/assets/javascripts/mbeditor/components/EditorPanel.js`, inside the `useEffect` that runs when Monaco is ready (right after the `registerGlobalExtensions` block, ~line 175), add:

```javascript
    if (window.MbeditorColorProvider) {
      window.MbeditorColorProvider.register(window.monaco);
    }
```

- [ ] **Step 4: Verify in the browser**

Run the dummy app (`cd test/dummy && rbenv exec rails server`) and open `http://localhost:3000/mbeditor`, OR use the preview tools. Open a JS/HTML/Ruby file containing `#ff0000`, `rgb(0, 128, 255)`, and `hsl(210, 100%, 50%)`.
Expected: a colored square appears immediately before each literal; clicking it opens Monaco's color picker; choosing a new color rewrites the literal (hex literal stays hex, `rgb()` stays functional). Confirm no duplicate squares in a `.css` file.

- [ ] **Step 5: Commit**

```bash
git add app/assets/javascripts/mbeditor/color_provider.js app/assets/javascripts/mbeditor/application.js app/assets/javascripts/mbeditor/components/EditorPanel.js
git commit -m "feat: inline color swatches + picker for all file types"
```

---

## Task 2: Recent-files tracking in TabManager

**Files:**
- Modify: `app/assets/javascripts/mbeditor/tab_manager.js:121-146` (record on open), and the returned object (`:562-580`) plus a new helper block near the top.

- [ ] **Step 1: Add recent-files persistence helpers**

Near the top of the IIFE in `tab_manager.js` (after `var MAX_MODELS = 25;`), add:

```javascript
  var RECENT_FILES_KEY = 'mbeditor_recent_files';
  var MAX_RECENT_FILES = 12;

  function _loadRecentFiles() {
    try { return JSON.parse(localStorage.getItem(RECENT_FILES_KEY)) || []; }
    catch (e) { return []; }
  }

  function _recordRecentFile(path, name) {
    if (!path) return;
    // Skip virtual/special tabs — only real files belong in recents.
    if (path.indexOf('diff://') === 0 || path.indexOf('combined-diff://') === 0 ||
        path.indexOf('mbeditor://') === 0 || path === '__settings__') return;
    var list = _loadRecentFiles().filter(function (e) { return e.path !== path; });
    list.unshift({ path: path, name: name || path.split('/').pop() });
    list = list.slice(0, MAX_RECENT_FILES);
    try { localStorage.setItem(RECENT_FILES_KEY, JSON.stringify(list)); } catch (e) {}
  }

  function getRecentFiles() {
    // Return a defensive copy.
    return _loadRecentFiles().slice();
  }
```

- [ ] **Step 2: Record a recent file when a tab opens**

In `openTab` (`tab_manager.js`), immediately after the `if (!pane) return;` line (~135), add:

```javascript
    _recordRecentFile(path, name);
```

- [ ] **Step 3: Export `getRecentFiles`**

In the returned object at the bottom of the IIFE (~line 562), add `getRecentFiles: getRecentFiles,` alongside the other exports:

```javascript
    openTab: openTab,
    getRecentFiles: getRecentFiles,
    openDiffTab: openDiffTab,
```

- [ ] **Step 4: Sanity check in the browser console**

Load the editor, open a couple of files, then run `TabManager.getRecentFiles()` in the console.
Expected: an array of `{path, name}` with the most recently opened first, no duplicates, capped at 12, and no `diff://`/`__settings__` entries.

- [ ] **Step 5: Commit**

```bash
git add app/assets/javascripts/mbeditor/tab_manager.js
git commit -m "feat: track recently opened files in TabManager"
```

---

## Task 3: "Recently Opened" section in QuickOpenDialog

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/QuickOpenDialog.js:182-291`

- [ ] **Step 1: Add a recent-files render helper**

In `QuickOpenDialog.js`, after `renderRecentSection` (~line 242), add a new helper that reads from `TabManager` (in-scope global in the bundle):

```javascript
  function renderRecentFilesSection() {
    var recentFiles = (typeof TabManager !== 'undefined' && TabManager.getRecentFiles)
      ? TabManager.getRecentFiles() : [];
    if (recentFiles.length === 0) return null;
    var rows = recentFiles.map(function (entry) {
      var path = entry.path;
      var name = entry.name || (path.split('/').pop());
      return React.createElement(
        'div',
        {
          key: 'recentfile-' + path,
          className: 'quick-open-result',
          onClick: function () { onSelect(path, name); }
        },
        getQuickOpenIcon(path, name),
        React.createElement(
          'div',
          { className: 'quick-open-result-body' },
          React.createElement('div', { className: 'quick-open-result-name' }, name),
          React.createElement('div', { className: 'quick-open-result-path' }, path)
        ),
        renderStarBtn(path)
      );
    });
    return React.createElement(
      'div',
      { className: 'quick-open-section' },
      React.createElement('div', { className: 'quick-open-section-header' },
        React.createElement('i', { className: 'fas fa-clock', style: { marginRight: '6px', fontSize: '10px' } }),
        'Recently Opened'
      ),
      rows
    );
  }
```

- [ ] **Step 2: Render it in the empty state**

In the empty-state Fragment (`!query ? React.createElement(React.Fragment, null, ...)`, ~line 280), add `renderRecentFilesSection()` as the first child, before `renderFavouritesSection()`:

```javascript
        ? React.createElement(
            React.Fragment,
            null,
            renderRecentFilesSection(),
            renderFavouritesSection(),
            renderRecentSection(),
            favourites.length === 0 && recentSearches.length === 0 && React.createElement(
```

- [ ] **Step 3: Verify in the browser**

Open the editor, open two files, then press `Ctrl/Cmd+P` (empty query).
Expected: a "Recently Opened" section lists the two files, newest first; clicking one opens it; typing switches to fuzzy file-search results as before.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/QuickOpenDialog.js
git commit -m "feat: show recently opened files in quick-open empty state"
```

---

## Task 4: Title-bar search box

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/MbeditorApp.js:3182-3208` (title-bar right cluster / add a centered search box)

- [ ] **Step 1: Add a clickable search box to the title bar**

In `MbeditorApp.js`, in the `ide-titlebar` block, insert a search box between the title (`ide-titlebar-title`, ~line 3181) and the right-hand `marginLeft: "auto"` button cluster (~line 3182). Add this element:

```javascript
      React.createElement(
        'button',
        {
          type: 'button',
          className: 'ide-titlebar-search',
          title: 'Search files (Ctrl/Cmd+P)',
          onClick: function () { setQuickOpen(true); }
        },
        React.createElement('i', { className: 'fas fa-search', style: { marginRight: '6px', opacity: 0.7 } }),
        React.createElement('span', { className: 'ide-titlebar-search-text' }, 'Search files…')
      ),
```

- [ ] **Step 2: Style the search box**

Find the stylesheet that defines `ide-titlebar` (search for `.ide-titlebar` under `app/assets/stylesheets/mbeditor/`). Add:

```css
.ide-titlebar-search {
  display: flex;
  align-items: center;
  margin: 0 auto;
  min-width: 220px;
  max-width: 340px;
  padding: 3px 10px;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 4px;
  color: #aaa;
  font-size: 12px;
  cursor: pointer;
}
.ide-titlebar-search:hover { background: rgba(255, 255, 255, 0.10); }
.ide-titlebar-search-text { opacity: 0.8; }
```

(If the title bar uses flex with the title already present, `margin: 0 auto` centers the search box; verify visually and adjust to a wrapping flex container if the right cluster shifts.)

- [ ] **Step 3: Verify in the browser**

Reload the editor.
Expected: a "Search files…" box sits in the center of the title bar; clicking it opens the quick-open dialog showing recently opened files; `Ctrl/Cmd+P` still works.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/MbeditorApp.js app/assets/stylesheets/mbeditor/
git commit -m "feat: title-bar search box opens quick-open"
```

---

## Task 5: TabManager close helpers

**Files:**
- Modify: `app/assets/javascripts/mbeditor/tab_manager.js:416-433` (add helpers), returned object (`:576-577`)

- [ ] **Step 1: Add `closeOtherTabsInPane` and `closeSavedTabsInPane`**

In `tab_manager.js`, right after `closeAllTabsInPane` (~line 424), add:

```javascript
  function closeOtherTabsInPane(paneId, keepId) {
    var state = EditorStore.getState();
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    if (!pane) return;
    pane.tabs.slice().forEach(function(tab) {
      if (tab.id !== keepId) closeTab(paneId, tab.id);
    });
  }

  function closeSavedTabsInPane(paneId) {
    var state = EditorStore.getState();
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    if (!pane) return;
    pane.tabs.slice().forEach(function(tab) {
      if (!tab.dirty) closeTab(paneId, tab.id);
    });
  }
```

Note: `closeTab`'s second arg is matched against `tab.id`, so pass `tab.id` (not `tab.path`) to close diff/special tabs correctly.

- [ ] **Step 2: Export both helpers**

In the returned object (~line 576), add alongside `closeAllTabsInPane`:

```javascript
    closeAllTabsInPane: closeAllTabsInPane,
    closeOtherTabsInPane: closeOtherTabsInPane,
    closeSavedTabsInPane: closeSavedTabsInPane,
    closeAllTabs: closeAllTabs,
```

- [ ] **Step 3: Commit**

```bash
git add app/assets/javascripts/mbeditor/tab_manager.js
git commit -m "feat: add closeOtherTabsInPane and closeSavedTabsInPane"
```

---

## Task 6: Tab context-menu actions + `+` new-file button

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/MbeditorApp.js` — handlers (~after `handleCloseEditorsInGroup`, line 1617) and `renderTabBar` props (~line 3048)
- Modify: `app/assets/javascripts/mbeditor/components/TabBar.js` — menu items (~line 196-244) and `+` button (~line 194)

- [ ] **Step 1: Add close + new-file handlers in MbeditorApp**

In `MbeditorApp.js`, after `handleCloseEditorsInGroup` (~line 1617), add:

```javascript
  var handleCloseOtherTabs = function handleCloseOtherTabs(paneId, keepId) {
    var pane = state.panes.find(function (p) { return p.id === paneId; });
    if (!pane) return;
    var others = pane.tabs.filter(function (t) { return t.id !== keepId; });
    if (others.length === 0) return;
    if (!confirmBulkClose(others, "other editors")) return;
    TabManager.closeOtherTabsInPane(paneId, keepId);
    EditorStore.setStatus("Closed " + others.length + " editor" + (others.length === 1 ? "" : "s"), "info");
  };

  var handleCloseSavedTabs = function handleCloseSavedTabs(paneId) {
    var pane = state.panes.find(function (p) { return p.id === paneId; });
    if (!pane) return;
    var saved = pane.tabs.filter(function (t) { return !t.dirty; });
    if (saved.length === 0) return;
    TabManager.closeSavedTabsInPane(paneId);
    EditorStore.setStatus("Closed " + saved.length + " saved editor" + (saved.length === 1 ? "" : "s"), "info");
  };

  var handleNewFileInTabDir = function handleNewFileInTabDir(paneId) {
    var pane = state.panes.find(function (p) { return p.id === paneId; });
    var activeForPane = pane && pane.tabs.find(function (t) { return t.id === pane.activeTabId; });
    var activePath = activeForPane && activeForPane.path;
    var isReal = activePath && activePath.indexOf('://') < 0 && activePath !== '__settings__';
    var baseDir = isReal ? parentDir(activePath) : '';
    // Make sure the explorer is visible so the inline-create row shows.
    setActiveSidebarTab('explorer');
    setSidebarCollapsed(false);
    // Expand ancestors of the target dir.
    if (baseDir) {
      var parts = baseDir.split('/');
      var ancestors = {};
      for (var i = 1; i <= parts.length; i++) {
        ancestors[parts.slice(0, i).join('/')] = true;
      }
      setExpandedDirs(function (prev) { return Object.assign({}, prev, ancestors); });
    }
    setPendingRename(null);
    setPendingCreate({ type: 'file', parentPath: baseDir });
  };
```

(Confirm `setSidebarCollapsed` and `setActiveSidebarTab` are the actual setter names in this file — search for `sidebarCollapsed` / `activeSidebarTab`. If a setter differs, use the found name.)

- [ ] **Step 2: Pass new props into TabBar**

In `renderTabBar` (`MbeditorApp.js` ~line 3049), add to the `TabBar` props object (after `onRevealInExplorer`):

```javascript
      onCloseOthers: function (id) { handleCloseOtherTabs(paneId, id); },
      onCloseSaved: function () { handleCloseSavedTabs(paneId); },
      onCloseAll: function () { handleCloseEditorsInGroup(paneId); },
      onNewFile: function () { handleNewFileInTabDir(paneId); },
```

- [ ] **Step 3: Read the new props in TabBar**

In `TabBar.js`, add near the other `_ref` destructures (~line 21):

```javascript
  var onCloseOthers = _ref.onCloseOthers;
  var onCloseSaved = _ref.onCloseSaved;
  var onCloseAll = _ref.onCloseAll;
  var onNewFile = _ref.onNewFile;
```

- [ ] **Step 4: Add the four close items to the context menu**

In `TabBar.js`, inside the `tabContextMenu &&` menu (~line 196), add these four items as the **first** children of the menu (before the `onShowHistory` item), followed by a separator `div`. Each item mirrors the existing item styling:

```javascript
    React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() { setTabContextMenu(null); onClose(tabContextMenu.tab.id); }
      },
      React.createElement('i', { className: 'fas fa-times', style: { width: '14px', textAlign: 'center' } }),
      'Close'
    ),
    onCloseOthers && React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() { setTabContextMenu(null); onCloseOthers(tabContextMenu.tab.id); }
      },
      React.createElement('i', { className: 'fas fa-times-circle', style: { width: '14px', textAlign: 'center' } }),
      'Close Others'
    ),
    onCloseSaved && React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() { setTabContextMenu(null); onCloseSaved(); }
      },
      React.createElement('i', { className: 'fas fa-check', style: { width: '14px', textAlign: 'center' } }),
      'Close Saved'
    ),
    onCloseAll && React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() { setTabContextMenu(null); onCloseAll(); }
      },
      React.createElement('i', { className: 'fas fa-times', style: { width: '14px', textAlign: 'center' } }),
      'Close All'
    ),
    React.createElement('div', { style: { height: '1px', background: '#454545', margin: '4px 0' } }),
```

Leave the existing `onShowHistory` / `onRevealInExplorer` items after this separator.

- [ ] **Step 5: Add the `+` button after the last tab**

In `TabBar.js`, inside the `.tab-bar` div, add the `+` button immediately **after** the `tabs.map(...)` expression (as the next sibling child of the `tab-bar` div, ~line 194 after the closing `)` of `.map`):

```javascript
    ,
    onNewFile && React.createElement(
      'div',
      {
        className: 'tab-new-file-btn',
        title: 'New File',
        onClick: function (e) { e.stopPropagation(); onNewFile(); }
      },
      React.createElement('i', { className: 'fas fa-plus' })
    )
```

(The `.map` call is followed by `)` closing the `.tab-bar` `createElement`; insert the `, onNewFile && …` as an additional child argument before that closing paren. Verify comma placement compiles.)

- [ ] **Step 6: Style the `+` button**

In the stylesheet that defines `.tab-item` (search `app/assets/stylesheets/mbeditor/` for `.tab-bar`), add:

```css
.tab-new-file-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: 30px;
  padding: 0 8px;
  color: #888;
  cursor: pointer;
  flex: 0 0 auto;
}
.tab-new-file-btn:hover { color: #fff; background: rgba(255, 255, 255, 0.06); }
```

- [ ] **Step 7: Verify in the browser**

Reload the editor and open `app/models/user.rb`.
- Right-click the tab → menu shows Close, Close Others, Close Saved, Close All, then File History / Find in Explorer. Test each: Close Others keeps only the clicked tab; Close Saved closes non-dirty tabs; Close All (aggregate confirm if any dirty) clears the pane.
- Click the `+` after the last tab → explorer opens with an inline create input inside `app/models/`; type `new_thing.rb` + Enter → file is created and opened.

- [ ] **Step 8: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/TabBar.js app/assets/javascripts/mbeditor/components/MbeditorApp.js app/assets/stylesheets/mbeditor/
git commit -m "feat: tab context-menu close actions and + new-file button"
```

---

## Task 7: System tests

**Files:**
- Create: `test/system/mbeditor/tab_actions_test.rb`

- [ ] **Step 1: Write the failing system test**

Create `test/system/mbeditor/tab_actions_test.rb`:

```ruby
# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  class TabActionsSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_tabs_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "a.rb"), "class A; end\n")
      File.write(File.join(@workspace, "b.rb"), "class B; end\n")
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      Capybara.reset_sessions!
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    def open_file(name)
      find(".file-tree", wait: 10)
      find("span", text: name, match: :first).click
      assert_selector ".tab-item", text: name, wait: 10
    end

    test "close others leaves only the clicked tab" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      tab_a = find(".tab-item", text: "a.rb")
      tab_a.right_click
      find(".ide-tab-context-menu-item", text: "Close Others").click

      assert_selector ".tab-item", count: 1
      assert_selector ".tab-item", text: "a.rb"
    end

    test "close all clears the pane" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "b.rb").right_click
      find(".ide-tab-context-menu-item", text: "Close All").click

      assert_no_selector ".tab-item", wait: 10
    end

    test "plus button creates a new file in the active file's directory" do
      visit "/mbeditor"
      open_file("user.rb") # under app/models
      find(".tab-new-file-btn").click

      input = find(".tree-item-inline-create input", wait: 10)
      input.set("helper.rb")
      input.send_keys(:enter)

      assert_selector ".tab-item", text: "helper.rb", wait: 10
      assert File.exist?(File.join(@workspace, "app", "models", "helper.rb"))
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail (before implementation) or pass (after)**

If Tasks 5-6 are already implemented, run:

```bash
rbenv exec bundle exec rails test test/system/mbeditor/tab_actions_test.rb
```

Expected before Tasks 5-6: FAIL (menu items / `+` button not found). After: PASS. If run in a subagent-driven flow where this task follows implementation, expect PASS. Adjust selectors (`.tree-item-inline-create input`) to match FileTree's actual inline-create markup — verify against `FileTree.js` (`tree-item-inline-create` class exists at line ~346) and the file-tree row markup for clicking a file (the `open_file` helper's `span` selector may need to target the tree row text element).

- [ ] **Step 3: Fix selectors until green, then commit**

```bash
git add test/system/mbeditor/tab_actions_test.rb
git commit -m "test: system tests for tab close actions and new-file button"
```

---

## Task 8: Changelog + docs

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a changelog entry**

Add an unreleased entry to `CHANGELOG.md` (match existing format) summarizing: inline color swatches + picker for all file types; title-bar search box surfacing recently opened files; tab right-click menu (Close / Close Others / Close Saved / Close All); `+` new-file button after the last tab.

- [ ] **Step 2: Run the full suite**

```bash
rbenv exec bundle exec rake test
```

Expected: all tests pass (existing 495+ plus the new system tests).

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for VSCode-style UX features"
```

---

## Self-Review Notes

- **Spec coverage:** Color swatches all-files → Task 1. Title-bar search + recent files → Tasks 2-4. Tab context menu (4 actions) → Tasks 5-6. `+` new-file → Task 6. Testing → Task 7. All spec sections covered.
- **Dirty-tab handling:** Reuses the codebase's existing `confirmBulkClose` aggregate-confirm pattern (already used by `handleCloseEditorsInGroup`) rather than inventing a per-tab queue — Close Others/All prompt once if unsaved tabs are affected; Close Saved only touches clean tabs. This intentionally refines the spec's looser "follow closeTab dirty-check" wording to match the established pattern in `MbeditorApp.js:1582-1617`.
- **Type consistency:** `getRecentFiles()` returns `[{path, name}]` (Task 2) consumed identically in Task 3. `closeOtherTabsInPane(paneId, keepId)` / `closeSavedTabsInPane(paneId)` signatures match their callers in Task 6. `onCloseOthers`/`onCloseSaved`/`onCloseAll`/`onNewFile` props defined in Task 6 Step 2 match those read in Step 3.
- **Assumptions to verify during implementation (flagged inline):** exact setter names `setSidebarCollapsed`/`setActiveSidebarTab` (Task 6 Step 1); the FileTree row click selector and inline-create input selector (Task 7); comma placement when inserting the `+` button child (Task 6 Step 5).
```
