var TabManager = (function () {
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

  function openTab(path, name, line, forcePaneId) {
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

    // Create placeholder then load
    var newTab = {
      id: path,
      path: path,
      name: name,
      dirty: false,
      content: "",
      viewState: null,
      isImage: _isImagePath(path)
    };
    if (line) newTab.gotoLine = line;

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: path });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: path });

    if (_isMarkdownPath(path)) {
      _ensureMarkdownPreview(paneId, path, name, "");
    }

    FileService.getFile(path).then(function(data) {
      _updateTab(paneId, path, {
        content: typeof data.content === 'string' ? data.content : "",
        isImage: data.image === true ? true : _isImagePath(path)
      });
      if (_isMarkdownPath(path)) {
        _syncMarkdownPreviewContent(path, typeof data.content === 'string' ? data.content : "");
      }
    }).catch(function(err) {
      EditorStore.setStatus("Failed to load file: " + ((err.response && err.response.data && err.response.data.error) || err.message), "error");
      closeTab(paneId, path);
    });
  }

  function closeTab(paneId, path) {
    var state = EditorStore.getState();
    var newPanes = state.panes.map(function(pane) {
      if (pane.id === paneId) {
        var newTabs = pane.tabs.filter(function(t) { return t.path !== path; });
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

    var maybeNewGlobalActiveTab = focusedPane ? focusedPane.activeTabId : null;

    EditorStore.setState({
      panes: newPanes,
      focusedPaneId: nextFocusedPaneId,
      activeTabId: maybeNewGlobalActiveTab
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
    _updateTab(paneId, path, { content: content, dirty: true });
    if (_isMarkdownPath(path)) {
      _syncMarkdownPreviewContent(path, content);
    }
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
          return t.path === path ? Object.assign({}, t, updates) : t;
        });
        return Object.assign({}, pane, { tabs: newTabs });
      }
      return pane;
    });
    EditorStore.setState({ panes: newPanes });
  }

  return {
    openTab: openTab,
    closeTab: closeTab,
    switchTab: switchTab,
    focusPane: focusPane,
    markDirty: markDirty,
    saveTabViewState: saveTabViewState,
    moveTabToPane: moveTabToPane
  };
})();
