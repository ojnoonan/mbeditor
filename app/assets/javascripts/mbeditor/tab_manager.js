var TabManager = (function () {
  var MAX_MODELS = 15;

  // Evict the least-recently-used Monaco model that is not currently open in
  // any pane. Call this before creating a new model entry.
  function _evictLruModel() {
    if (!window.__mbeditorModels) return;
    var keys = Object.keys(window.__mbeditorModels);
    if (keys.length < MAX_MODELS) return; // room available — evict one to make room for one new entry

    // Collect the set of paths currently open in any pane.
    var state = EditorStore.getState();
    var openPaths = {};
    state.panes.forEach(function(pane) {
      pane.tabs.forEach(function(tab) {
        openPaths[tab.path] = true;
      });
    });

    // Find the eviction candidate: oldest lastAccessed that is not open.
    var candidate = null;
    var candidateTime = Infinity;
    keys.forEach(function(path) {
      if (openPaths[path]) return; // skip currently-open files
      var entry = window.__mbeditorModels[path];
      var t = entry.lastAccessed || 0; // || 0 treats pre-existing entries (no lastAccessed) as oldest, so they evict first
      if (t < candidateTime) {
        candidateTime = t;
        candidate = path;
      }
    });

    // If every cached model is currently open in a pane, skip eviction — never evict an active file.
    // The cache may temporarily exceed MAX_MODELS; this is acceptable.
    if (candidate) {
      var entry = window.__mbeditorModels[candidate];
      if (entry.model && !entry.model.isDisposed()) {
        entry.model.dispose();
      }
      delete window.__mbeditorModels[candidate];
    }
  }

  function _isImagePath(path) {
    return /\.(png|jpe?g|gif|svg|ico|webp|bmp|avif)$/i.test(path || "");
  }

  function _isMarkdownPath(path) {
    return /\.(md|markdown)$/i.test(path || "");
  }

  function _previewPath(path) {
    return path + "::preview";
  }

  function _previewName(name) {
    return (name || "preview") + "-preview";
  }

  function _ensureMarkdownPreview(sourcePaneId, sourcePath, sourceName, sourceContent) {
    var state = EditorStore.getState();
    var targetPaneId = sourcePaneId === 1 ? 2 : 1;
    var previewPath = _previewPath(sourcePath);
    var targetPane = state.panes.find(function(p) { return p.id === targetPaneId; });
    if (!targetPane) return;

    var existing = targetPane.tabs.find(function(t) { return t.path === previewPath; });
    if (existing) {
      _updateTab(targetPaneId, previewPath, {
        name: _previewName(sourceName),
        isPreview: true,
        previewFor: sourcePath,
        content: typeof sourceContent === 'string' ? sourceContent : existing.content
      });
      return;
    }

    var previewTab = {
      id: previewPath,
      path: previewPath,
      name: _previewName(sourceName),
      dirty: false,
      content: typeof sourceContent === 'string' ? sourceContent : "",
      viewState: null,
      isPreview: true,
      previewFor: sourcePath
    };

    var newPanes = state.panes.map(function(p) {
      if (p.id === targetPaneId) {
        return Object.assign({}, p, {
          tabs: p.tabs.concat(previewTab),
          activeTabId: previewPath
        });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: sourcePaneId, activeTabId: sourcePath });
  }

  function _syncMarkdownPreviewContent(sourcePath, sourceContent) {
    var state = EditorStore.getState();
    var previewPath = _previewPath(sourcePath);

    state.panes.forEach(function(pane) {
      var previewTab = pane.tabs.find(function(tab) {
        return tab.path === previewPath || (tab.isPreview && tab.previewFor === sourcePath);
      });

      if (previewTab) {
        _updateTab(pane.id, previewTab.path, {
          content: sourceContent,
          previewFor: sourcePath,
          isPreview: true
        });
      }
    });
  }

  function openTab(path, name, line, forcePaneId, isSoftOpen) {
    var state = EditorStore.getState();
    var paneId = forcePaneId || state.focusedPaneId;
    var pane = state.panes.find(function(p) { return p.id === paneId; });

    // If pane 2 is currently empty/hidden, prefer opening new tabs in pane 1.
    if (!forcePaneId && paneId === 2 && (!pane || pane.tabs.length === 0)) {
      var primaryPane = state.panes.find(function(p) { return p.id === 1; });
      if (primaryPane && primaryPane.tabs.length > 0) {
        paneId = 1;
        pane = primaryPane;
      }
    }

    if (!pane) return;

    var existing = pane.tabs.find(function(t) { return t.path === path; });

    if (existing) {
      if (line) _updateTab(paneId, path, { gotoLine: line });
      switchTab(paneId, path);
      if (_isMarkdownPath(path)) {
        _ensureMarkdownPreview(paneId, path, existing.name || name, existing.content || "");
      }
      return;
    }

    // For soft-opens, discard any existing non-dirty soft tab so this one replaces it.
    var tabsList = pane.tabs;
    if (isSoftOpen) {
      tabsList = pane.tabs.filter(function(t) { return !t.isSoftOpen || t.dirty; });
    }

    // Create placeholder then load
    var newTab = {
      id: path,
      path: path,
      name: name,
      dirty: false,
      content: "",
      viewState: null,
      isImage: _isImagePath(path),
      isSoftOpen: isSoftOpen ? true : false,
      loading: true
    };
    if (line) newTab.gotoLine = line;

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: tabsList.concat(newTab), activeTabId: path });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: path });

    // Virtual paths (diff://, combined-diff://) should never hit the file endpoint
    if (path.indexOf('diff://') === 0 || path.indexOf('combined-diff://') === 0) {
      return;
    }

    // Use a prefetched result if available (hover-prefetch hit), otherwise fetch normally.
    var prefetchPromise = FileService.getPrefetched(path);
    var filePromise = prefetchPromise || FileService.getFile(path, { allowMissing: true });

    filePromise.then(function(data) {
      // getPrefetched can resolve to null if the in-flight request failed/was aborted.
      // In that case fall back to a fresh fetch.
      if (!data) return FileService.getFile(path, { allowMissing: true });
      return data;
    }).then(function(data) {
      if (!data) { closeTab(paneId, path); return; }
      var loadedContent = typeof data.content === 'string' ? data.content : "";
      var fileNotFound = data && data.missing === true;
      _updateTab(paneId, path, {
        content: loadedContent,
        cleanContent: loadedContent,
        externalContentVersion: 1,
        isImage: data.image === true ? true : _isImagePath(path),
        fileNotFound: fileNotFound,
        dirty: false,
        loading: false
      });
      if (!fileNotFound && _isMarkdownPath(path)) {
        _ensureMarkdownPreview(paneId, path, name, loadedContent);
        _syncMarkdownPreviewContent(path, typeof data.content === 'string' ? data.content : "");
      }
    }).catch(function(err) {
      if (path.startsWith('diff://')) return; // diff tabs handle their own loading
      EditorStore.setStatus("Failed to load file: " + ((err.response && err.response.data && err.response.data.error) || err.message), "error");
      closeTab(paneId, path);
    });
  }

  function openDiffTab(repoPath, name, baseSha, headSha, paneIdOverride) {
    var state = EditorStore.getState();
    var paneId = paneIdOverride || state.focusedPaneId;
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    if (!pane) return;

    // diff://[base]..[head]/path
    var baseStr = baseSha || 'HEAD';
    var headStr = headSha || 'WORKING';
    var diffId = 'diff://' + baseStr + '..' + headStr + '/' + repoPath;

    var existing = pane.tabs.find(function(t) { return t.id === diffId; });
    if (existing) {
      switchTab(paneId, diffId);
      return;
    }

    var newTab = {
      id: diffId,
      path: diffId,        // use diffId as path so markdown-preview logic never fires
      repoPath: repoPath,  // original file path kept for reference
      name: name + ' \u2195 Diff',
      dirty: false,
      content: "Loading diff...",
      viewState: null,
      isImage: false,
      isSoftOpen: false,
      isDiff: true,
      diffOriginal: "",
      diffModified: "",
      diffBaseSha: baseSha,
      diffHeadSha: headSha
    };

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: diffId });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: diffId });

    GitService.fetchDiff(repoPath, baseSha, headSha).then(function(data) {
      _updateTab(paneId, diffId, {
        content: "Diff loaded",
        diffOriginal: data.original || "",
        diffModified: data.modified || ""
      });
    }).catch(function(err) {
      var msg = err.response && err.response.data && err.response.data.error || err.message;
      EditorStore.setStatus("Failed to load diff: " + msg, "error");
      _updateTab(paneId, diffId, {
        content: "Error: " + msg,
        diffOriginal: "Error loading diff",
        diffModified: "Error loading diff"
      });
    });
  }

  function openCombinedDiffTab(scope, label) {
    var tabId = 'combined-diff://' + (scope || 'local');
    var state = EditorStore.getState();
    var paneId = state.focusedPaneId;
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    if (!pane) return;

    // Re-activate existing tab if present
    var existing = pane.tabs.find(function(t) { return t.id === tabId; });
    if (existing) {
      switchTab(paneId, tabId);
      return;
    }

    var newTab = {
      id: tabId,
      path: tabId,
      name: label || 'All Changes',
      dirty: false,
      content: '',
      viewState: null,
      isImage: false,
      isSoftOpen: false,
      isCombinedDiff: true,
      combinedDiffText: '',
      combinedDiffLabel: label || 'All Changes',
      combinedDiffLoaded: false
    };

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: tabId });
      }
      return p;
    });
    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: tabId });

    axios.get(window.mbeditorBasePath() + '/git/combined_diff', { params: { scope: scope || 'local' } })
      .then(function(res) {
        var data = res.data;
        _updateTab(paneId, tabId, {
          combinedDiffText: typeof data === 'string' ? data : (data && data.diff) || '',
          combinedDiffLoaded: true
        });
      })
      .catch(function(err) {
        _updateTab(paneId, tabId, {
          combinedDiffText: '# Error loading diff: ' + (err.message || 'unknown error'),
          combinedDiffLoaded: true
        });
      });
  }

  function closeTab(paneId, path) {
    var state = EditorStore.getState();
    var newPanes = state.panes.map(function(pane) {
      if (pane.id === paneId) {
        // Match by t.id so diff tabs (id = 'diff://...') are closed correctly
        var newTabs = pane.tabs.filter(function(t) { return t.id !== path; });
        var newActive = pane.activeTabId;
        if (pane.activeTabId === path) {
          newActive = newTabs.length > 0 ? newTabs[newTabs.length - 1].id : null;
        }
        return Object.assign({}, pane, { tabs: newTabs, activeTabId: newActive });
      }
      return pane;
    });

    var nextFocusedPaneId = state.focusedPaneId;
    var focusedPane = newPanes.find(function(p) { return p.id === nextFocusedPaneId; });

    // If the currently focused pane became empty, move focus to a pane that still has tabs.
    if (!focusedPane || focusedPane.tabs.length === 0) {
      var paneWithTabs = newPanes.find(function(p) { return p.tabs.length > 0; });
      nextFocusedPaneId = paneWithTabs ? paneWithTabs.id : 1;
      focusedPane = newPanes.find(function(p) { return p.id === nextFocusedPaneId; });
    }

    // If pane 1 is now empty and pane 2 has tabs, migrate pane 2 tabs into pane 1.
    var pane1AfterClose = newPanes.find(function(p) { return p.id === 1; });
    var pane2AfterClose = newPanes.find(function(p) { return p.id === 2; });
    if (pane1AfterClose && pane1AfterClose.tabs.length === 0 && pane2AfterClose && pane2AfterClose.tabs.length > 0) {
      newPanes = newPanes.map(function(p) {
        if (p.id === 1) return Object.assign({}, p, { tabs: pane2AfterClose.tabs, activeTabId: pane2AfterClose.activeTabId });
        if (p.id === 2) return Object.assign({}, p, { tabs: [], activeTabId: null });
        return p;
      });
      nextFocusedPaneId = 1;
      focusedPane = newPanes.find(function(p) { return p.id === 1; });
    }

    var maybeNewGlobalActiveTab = focusedPane ? focusedPane.activeTabId : null;

    EditorStore.setState({
      panes: newPanes,
      focusedPaneId: nextFocusedPaneId,
      activeTabId: maybeNewGlobalActiveTab
    });

    // Dispose the cached Monaco model for this path if it is no longer open in
    // any pane. This keeps the model registry clean and frees memory.
    if (window.__mbeditorModels && window.__mbeditorModels[path]) {
      var _stillOpen = newPanes.some(function(p) {
        return p.tabs.some(function(t) { return t.path === path; });
      });
      if (!_stillOpen) {
        var _entry = window.__mbeditorModels[path];
        if (_entry.model && !_entry.model.isDisposed()) {
          _entry.model.dispose();
        }
        delete window.__mbeditorModels[path];
      }
    }
  }

  function closeAllTabsInPane(paneId) {
    var state = EditorStore.getState();
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    if (!pane || pane.tabs.length === 0) return;

    pane.tabs.slice().forEach(function(tab) {
      closeTab(paneId, tab.path);
    });
  }

  function closeAllTabs() {
    var state = EditorStore.getState();
    var paneIds = state.panes.map(function(p) { return p.id; }).sort(function(a, b) { return b - a; });

    paneIds.forEach(function(paneId) {
      closeAllTabsInPane(paneId);
    });
  }

  function switchTab(paneId, path) {
    var state = EditorStore.getState();
    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) return Object.assign({}, p, { activeTabId: path });
      return p;
    });
    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: path });
  }

  function focusPane(paneId) {
    var state = EditorStore.getState();
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    var newActive = pane ? pane.activeTabId : null;
    EditorStore.setState({ focusedPaneId: paneId, activeTabId: newActive });
  }

  function markDirty(paneId, path, content) {
    // Auto-harden any soft-open tab on first edit.
    var st = EditorStore.getState();
    var paneForTab = st.panes.find(function(p) { return p.id === paneId; });
    var existingTab = paneForTab && paneForTab.tabs.find(function(t) { return t.path === path; });
    var updates = { content: content, dirty: true };
    if (existingTab && existingTab.isSoftOpen) {
      updates.isSoftOpen = false;
    }
    _updateTab(paneId, path, updates);
    if (_isMarkdownPath(path)) {
      _syncMarkdownPreviewContent(path, content);
    }
  }

  function markClean(paneId, path, content) {
    _updateTab(paneId, path, { content: content, dirty: false });
  }

  function hardenTab(paneId, path) {
    _updateTab(paneId, path, { isSoftOpen: false });
  }

  function saveTabViewState(paneIdOrPath, pathOrViewState, maybeViewState) {
    var paneId = paneIdOrPath;
    var path = pathOrViewState;
    var viewState = maybeViewState;

    // Backward-compatible signature: saveTabViewState(path, viewState)
    if (typeof maybeViewState === 'undefined') {
      var state = EditorStore.getState();
      path = paneIdOrPath;
      viewState = pathOrViewState;
      var containingPane = state.panes.find(function(p) {
        return p.tabs.some(function(t) { return t.path === path; });
      });
      if (!containingPane) return;
      paneId = containingPane.id;
    }

    _updateTab(paneId, path, { viewState: viewState });
  }

  function reorderTabInPane(paneId, tabId, insertBeforeTabId) {
    var state = EditorStore.getState();
    var newPanes = state.panes.map(function(p) {
      if (p.id !== paneId) return p;
      var tab = p.tabs.find(function(t) { return t.id === tabId; });
      if (!tab) return p;
      var without = p.tabs.filter(function(t) { return t.id !== tabId; });
      var insertIdx = insertBeforeTabId
        ? without.findIndex(function(t) { return t.id === insertBeforeTabId; })
        : -1;
      var reordered;
      if (insertIdx === -1) {
        reordered = without.concat(tab);
      } else {
        reordered = without.slice(0, insertIdx).concat(tab).concat(without.slice(insertIdx));
      }
      return Object.assign({}, p, { tabs: reordered });
    });
    EditorStore.setState({ panes: newPanes });
  }

  function moveTabToPane(sourcePaneId, targetPaneId, path) {
    if (sourcePaneId === targetPaneId) return;

    var state = EditorStore.getState();
    var sourcePane = state.panes.find(function(p) { return p.id === sourcePaneId; });
    var targetPane = state.panes.find(function(p) { return p.id === targetPaneId; });
    if (!sourcePane || !targetPane) return;

    var tabToMove = sourcePane.tabs.find(function(t) { return t.path === path; });
    if (!tabToMove) return;

    var targetHasTab = targetPane.tabs.some(function(t) { return t.path === path; });

    var newPanes = state.panes.map(function(p) {
      if (p.id === sourcePaneId) {
        var newTabs = p.tabs.filter(function(t) { return t.path !== path; });
        var newActive = p.activeTabId === path ? (newTabs.length > 0 ? newTabs[newTabs.length - 1].id : null) : p.activeTabId;
        return Object.assign({}, p, { tabs: newTabs, activeTabId: newActive });
      }
      if (p.id === targetPaneId) {
        return Object.assign({}, p, { tabs: targetHasTab ? p.tabs : p.tabs.concat(tabToMove), activeTabId: path });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: targetPaneId, activeTabId: path });
  }

  function _updateTab(paneId, path, updates) {
    var state = EditorStore.getState();
    var newPanes = state.panes.map(function(pane) {
      if (pane.id === paneId) {
        var newTabs = pane.tabs.map(function(t) {
          // Match by t.id so diff tabs (where id !== path) are found correctly
          return t.id === path ? Object.assign({}, t, updates) : t;
        });
        return Object.assign({}, pane, { tabs: newTabs });
      }
      return pane;
    });
    EditorStore.setState({ panes: newPanes });
  }

  function clearGotoLine(paneId, path) {
    _updateTab(paneId, path, { gotoLine: null });
  }

  return {
    openTab: openTab,
    openDiffTab: openDiffTab,
    openCombinedDiffTab: openCombinedDiffTab,
    closeTab: closeTab,
    switchTab: switchTab,
    focusPane: focusPane,
    markDirty: markDirty,
    markClean: markClean,
    hardenTab: hardenTab,
    saveTabViewState: saveTabViewState,
    reorderTabInPane: reorderTabInPane,
    moveTabToPane: moveTabToPane,
    clearGotoLine: clearGotoLine,
    closeAllTabsInPane: closeAllTabsInPane,
    closeAllTabs: closeAllTabs,
    syncMarkdownPreview: _syncMarkdownPreviewContent,
    evictLruModel: _evictLruModel
  };
})();
