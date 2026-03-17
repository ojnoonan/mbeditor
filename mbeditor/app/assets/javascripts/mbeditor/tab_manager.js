var TabManager = (function () {
  function openTab(path, name, line, forcePaneId) {
    var state = EditorStore.getState();
    var paneId = forcePaneId || state.focusedPaneId;
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    
    var existing = pane.tabs.find(function(t) { return t.path === path; });

    if (existing) {
      if (line) _updateTab(paneId, path, { gotoLine: line });
      switchTab(paneId, path);
      return;
    }

    // Create placeholder then load
    var newTab = { id: path, path: path, name: name, dirty: false, content: "", viewState: null };
    if (line) newTab.gotoLine = line;

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: path });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: path });

    FileService.getFile(path).then(function(data) {
      _updateTab(paneId, path, { content: data.content });
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

    // Determine what happens to global activeTabId if we closed it
    var focusedPane = newPanes.find(function(p) { return p.id === state.focusedPaneId; });
    var maybeNewGlobalActiveTab = focusedPane ? focusedPane.activeTabId : null;

    EditorStore.setState({ panes: newPanes, activeTabId: maybeNewGlobalActiveTab });
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
