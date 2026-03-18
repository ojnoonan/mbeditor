const { useState, useEffect, useRef } = React;

const SIDEBAR_MIN_WIDTH = 240;
const SIDEBAR_MAX_WIDTH = 560;
const EDITOR_MIN_WIDTH = 320;
const GIT_PANEL_MIN_WIDTH = 280;
const PANE_MIN_WIDTH_PERCENT = 20;
const PANE_MAX_WIDTH_PERCENT = 80;

const MbeditorApp = () => {
  const [state, setState] = useState(EditorStore.getState());
  const [quickOpen, setQuickOpen] = useState(false);
  const [treeData, setTreeData] = useState([]);
  const [projectRootName, setProjectRootName] = useState("");
  const [selectedTreeNode, setSelectedTreeNode] = useState(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [activeSidebarTab, setActiveSidebarTab] = useState("explorer");
  const [markers, setMarkers] = useState({}); // { tabId: [] }
  const [loading, setLoading] = useState({});
  const [closingTabId, setClosingTabId] = useState(null);
  const [closingPaneId, setClosingPaneId] = useState(null);
  const [sidebarWidth, setSidebarWidth] = useState(SIDEBAR_MIN_WIDTH);
  const [pane1Width, setPane1Width] = useState(50); // percentage
  const [activeResizeMode, setActiveResizeMode] = useState(null);
  const [draggedTab, setDraggedTab] = useState(null);
  const [dragOverPaneId, setDragOverPaneId] = useState(null);
  const [showGitPanel, setShowGitPanel] = useState(false);
  const [collapsedSections, setCollapsedSections] = useState({
    openEditors: false,
    projects: false
  });
  const [expandedDirs, setExpandedDirs] = useState({});
  const [pendingCreate, setPendingCreate] = useState(null);
  const [pendingRename, setPendingRename] = useState(null);
  const [contextMenu, setContextMenu] = useState(null);
  const resizeSessionRef = useRef(null);

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  const normalizeRelativePath = (input) => {
    return (input || "")
      .replace(/\\/g, "/")
      .trim()
      .replace(/^\/+/, "")
      .replace(/\/+$/, "")
      .replace(/\/+/g, "/");
  };

  const parentDir = (path) => {
    if (!path) return "";
    const idx = path.lastIndexOf("/");
    return idx > 0 ? path.slice(0, idx) : "";
  };

  const deriveProjectRootName = () => {
    if (projectRootName) return projectRootName;
    const railsRoot = document && document.body && document.body.dataset ? document.body.dataset.railsRoot : "";
    if (!railsRoot) return "PROJECT";
    const parts = railsRoot.split("/").filter(Boolean);
    return parts.length ? parts[parts.length - 1] : "PROJECT";
  };

  const refreshProjectTree = () => {
    return FileService.getTree().then((data) => {
      setTreeData(data || []);
      SearchService.buildIndex(data || []);
      return data || [];
    }).catch((err) => {
      EditorStore.setStatus("Failed to refresh files: " + ((err && err.message) || "Unknown error"), "error");
      return [];
    });
  };

  const isRubyPath = (path) => {
    return path && (path.endsWith('.rb') || path.endsWith('.gemspec') || path.endsWith('Rakefile') || path.endsWith('Gemfile'));
  };

  const applyMarkersForTab = (paneId, tabId, nextMarkers) => {
    const currentPane = EditorStore.getState().panes.find(p => p.id === paneId);
    const current = currentPane ? currentPane.tabs.find(t => t.id === tabId) : null;
    if (current) current.markers = nextMarkers;
    setMarkers(prev => ({ ...prev, [tabId]: nextMarkers }));
  };

  const runRubyLint = (tab, paneId, options = {}) => {
    if (!tab || !isRubyPath(tab.path)) return Promise.resolve(null);

    if (options.showLoading) {
      setLoading(prev => ({ ...prev, lint: true }));
    }
    if (options.showStatus) {
      EditorStore.setStatus('Linting...', 'info');
    }

    return FileService.lintFile(tab.path, tab.content).then(res => {
      const nextMarkers = res.markers || [];
      applyMarkersForTab(paneId, tab.id, nextMarkers);

      if (options.showStatus) {
        const count = (res.summary && res.summary.offense_count) || 0;
        EditorStore.setStatus(count === 0 ? 'No RuboCop offenses!' : `Found ${count} offenses`, count === 0 ? 'success' : 'warning');
      }

      return res;
    }).catch(err => {
      if (options.showStatus) {
        EditorStore.setStatus('Lint failed: ' + err.message, 'error');
      }
      return null;
    }).finally(() => {
      if (options.showLoading) {
        setLoading(prev => ({ ...prev, lint: false }));
      }
    });
  };

  const _debouncedAutoLint = useRef(window._.debounce((tab, paneId) => {
    if (!tab) return;
    if (isRubyPath(tab.path)) {
      runRubyLint(tab, paneId);
      return;
    }

    const ext = tab.path.split('.').pop().toLowerCase();
    const formatMap = {
      'js': 'babel', 'jsx': 'babel',
      'json': 'json',
      'css': 'css', 'scss': 'scss',
      'html': 'html', 'md': 'markdown'
    };
    const parserName = formatMap[ext];

    if (parserName && window.prettier && window.prettierPlugins) {
      window.prettier.format(tab.content, {
        parser: parserName,
        plugins: Object.values(window.prettierPlugins),
        tabWidth: 4,
        useTabs: false
      }).then(() => {
      }).then(() => {
        const currentPane = EditorStore.getState().panes.find(p => p.id === paneId);
        const current = currentPane ? currentPane.tabs.find(t => t.id === tab.id) : null;
        if (current) current.markers = [];
        setMarkers(prev => ({ ...prev, [tab.id]: [] })); 
      }).catch(err => {
        let newMarkers = [];
        if (err && err.loc && err.loc.start) {
          newMarkers.push({
            severity: "error",
            message: err.message.split("\n")[0] || "Syntax error",
            startLine: err.loc.start.line,
            startCol: err.loc.start.column,
            endLine: err.loc.end ? err.loc.end.line : err.loc.start.line,
            endCol: err.loc.end ? err.loc.end.column : err.loc.start.column + 1
          });
        }
        const currentPane = EditorStore.getState().panes.find(p => p.id === paneId);
        const current = currentPane ? currentPane.tabs.find(t => t.id === tab.id) : null;
        if (current) current.markers = newMarkers;
        setMarkers(prev => ({ ...prev, [tab.id]: newMarkers }));
      });
    }
  }, 600)).current;

  // Persist state when openTabs or activeTabId changes
  useEffect(() => {
    // Subscribe to EditorStore
    const unsubscribe = EditorStore.subscribe(setState);

    // Initial load
    Promise.all([
      FileService.getWorkspace().catch(() => null),
      refreshProjectTree()
    ]).then(([workspace]) => {
      if (workspace && workspace.rootName) {
        setProjectRootName(workspace.rootName);
      }
    });
    GitService.fetchStatus();
    
    // Load persisted state
    FileService.getState().then(savedState => {
      let panesToLoad = savedState && savedState.panes;
      if (savedState && savedState.openTabs) {
        panesToLoad = [{ id: 1, tabs: savedState.openTabs, activeTabId: savedState.activeTabId }, { id: 2, tabs: [], activeTabId: null }];
      }
      if (panesToLoad && panesToLoad.length > 0) {
        const allTabs = panesToLoad.flatMap(p => p.tabs);
        Promise.all(allTabs.map((t) => {
          const sourcePath = (t.isPreview || /::preview$/.test(t.path || ''))
            ? (t.previewFor || (t.path || '').replace(/::preview$/, ''))
            : t.path;
          return FileService.getFile(sourcePath).catch(() => ({ content: '' }));
        }))
          .then(results => {
            let resIdx = 0;
            const restoredPanes = panesToLoad.map(p => ({
              ...p,
              tabs: p.tabs.map(t => ({ ...t, content: results[resIdx++].content }))
            }));
            EditorStore.setState({ ...savedState, panes: restoredPanes, openTabs: undefined });
            // Restore collapsedSections UI state
            if (savedState.collapsedSections) {
              setCollapsedSections(savedState.collapsedSections);
            }
            if (savedState.expandedDirs) {
              setExpandedDirs(savedState.expandedDirs);
            }
          });
      }
    });

    // Hotkeys setup
    const onKeyDown = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'p') {
        e.preventDefault();
        setQuickOpen(true);
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        e.preventDefault();
        const st = EditorStore.getState();
        const focusedPane = st.panes.find(p => p.id === st.focusedPaneId) || st.panes[0];
        if (focusedPane && focusedPane.activeTabId) {
          const tab = focusedPane.tabs.find(t => t.id === focusedPane.activeTabId);
          if (tab && tab.dirty) handleSave(focusedPane.id, tab);
        }
      }
      if (e.key === 'Escape') {
        setContextMenu(null);
      }
    };

    const handleMouseMove = (e) => {
      const session = resizeSessionRef.current;
      if (!session) return;

      if (session.mode === 'pane') {
        const container = document.getElementById('ide-main-split-container');
        if (!container) return;

        const rect = container.getBoundingClientRect();
        const nextWidth = ((e.clientX - rect.left) / rect.width) * 100;
        setPane1Width(clamp(nextWidth, PANE_MIN_WIDTH_PERCENT, PANE_MAX_WIDTH_PERCENT));
      }

      if (session.mode === 'sidebar') {
        const body = document.getElementById('ide-body-container');
        if (!body) return;

        const rect = body.getBoundingClientRect();
        const reservedRight = EDITOR_MIN_WIDTH + (showGitPanel ? GIT_PANEL_MIN_WIDTH : 0);
        const maxSidebarWidth = Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, rect.width - reservedRight));
        const nextWidth = e.clientX - rect.left;
        setSidebarWidth(clamp(nextWidth, SIDEBAR_MIN_WIDTH, maxSidebarWidth));
      }
    };
    
    const handleMouseUp = () => {
      if (!resizeSessionRef.current) return;

      resizeSessionRef.current = null;
      setActiveResizeMode(null);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      unsubscribe();
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };
  }, [showGitPanel]);

  const handleSelectFile = (path, name, line) => {
    TabManager.openTab(path, name, line);
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
    setQuickOpen(false);
  };

  // Single-click in explorer: soft (preview) open — replaces any existing soft tab
  const handleSoftOpenFile = (path, name) => {
    TabManager.openTab(path, name, null, null, true);
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
  };

  // Double-click in explorer or on tab: harden the tab (remove italic/preview)
  const handleHardOpenFile = (path, name) => {
    const st = EditorStore.getState();
    const targetPane = st.panes.find(p => p.tabs.some(t => t.path === path));
    if (targetPane) {
      TabManager.hardenTab(targetPane.id, path);
      TabManager.switchTab(targetPane.id, path);
    } else {
      TabManager.openTab(path, name, null, null, false);
    }
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
  };

  const requestCloseTab = (paneId, id) => {
    const pane = state.panes.find(p => p.id === paneId) || state.panes[0];
    const tab = pane.tabs.find(t => t.id === id);
    if (tab && tab.dirty) {
      setClosingPaneId(paneId);
      setClosingTabId(id);
    } else {
      TabManager.closeTab(paneId, id);
    }
  };

  const confirmCloseTab = (save) => {
    const pane = state.panes.find(p => p.id === closingPaneId);
    const tab = pane ? pane.tabs.find(t => t.id === closingTabId) : null;
    if (!tab) {
      setClosingTabId(null);
      setClosingPaneId(null);
      return;
    }
    
    if (save) {
      setLoading(prev => ({ ...prev, save: true }));
      EditorStore.setStatus(`Saving ${tab.name}...`, "info");
      FileService.saveFile(tab.path, tab.content).then(() => {
        EditorStore.setStatus("Saved", "success");
        GitService.fetchStatus();
        TabManager.closeTab(closingPaneId, tab.id);
      }).catch(err => {
        EditorStore.setStatus("Save failed: " + err.message, "error");
      }).finally(() => {
        setLoading(prev => ({ ...prev, save: false }));
        setClosingTabId(null);
        setClosingPaneId(null);
      });
    } else {
      TabManager.closeTab(closingPaneId, tab.id);
      setClosingTabId(null);
      setClosingPaneId(null);
    }
  };

  // Persist state when panes, focusedPaneId, or collapsedSections changes
  useEffect(() => {
    // debounce explicitly using setTimeout to avoid spamming the backend
    const timeoutId = setTimeout(() => {
      const st = EditorStore.getState();
      const lightweightPanes = st.panes.map(p => ({
        id: p.id,
        activeTabId: p.activeTabId,
        tabs: p.tabs.map(t => ({
          id: t.id,
          path: t.path,
          name: t.name,
          dirty: t.dirty,
          viewState: t.viewState,
          isPreview: !!t.isPreview,
          previewFor: t.previewFor || null
        }))
      }));
      FileService.saveState({ panes: lightweightPanes, focusedPaneId: st.focusedPaneId, collapsedSections, expandedDirs });
    }, 1000);
    return () => clearTimeout(timeoutId);
  }, [state.panes, state.focusedPaneId, collapsedSections, expandedDirs]);

  const focusedPane = state.panes.find(p => p.id === state.focusedPaneId) || state.panes[0];
  const activeTab = focusedPane.tabs.find(t => t.id === focusedPane.activeTabId);

  useEffect(() => {
    if (!activeTab || typeof activeTab.content !== 'string') return;

    _debouncedAutoLint(activeTab, focusedPane.id);

    return () => {
      _debouncedAutoLint.cancel();
    };
  }, [focusedPane.id, activeTab ? activeTab.id : null, activeTab ? activeTab.content : null]);

  const handleSave = (paneId, tab) => {
    setLoading(prev => ({ ...prev, save: true }));
    EditorStore.setStatus(`Saving ${tab.name}...`, "info");
    FileService.saveFile(tab.path, tab.content)
      .then(() => {
        const newPanes = EditorStore.getState().panes.map(p => {
          if (p.id === paneId) {
            return { ...p, tabs: p.tabs.map(t => t.id === tab.id ? { ...t, dirty: false } : t) };
          }
          return p;
        });
        EditorStore.setState({ panes: newPanes });
        EditorStore.setStatus("Saved", "success");
        GitService.fetchStatus();
      })
      .catch(err => {
        EditorStore.setStatus("Save failed: " + err.message, "error");
      })
      .finally(() => setLoading(prev => ({ ...prev, save: false })));
  };

  const handleSaveAll = () => {
    const dirtyTabs = state.panes.flatMap(p => p.tabs).filter(t => t.dirty);
    if (dirtyTabs.length === 0) return;
    
    setLoading(prev => ({ ...prev, saveAll: true }));
    EditorStore.setStatus(`Saving ${dirtyTabs.length} files...`, "info");
    const promises = dirtyTabs.map(tab => FileService.saveFile(tab.path, tab.content));
    Promise.all(promises).then(() => {
      const newPanes = EditorStore.getState().panes.map(p => ({
        ...p, tabs: p.tabs.map(t => ({ ...t, dirty: false }))
      }));
      EditorStore.setState({ panes: newPanes });
      EditorStore.setStatus("All files saved", "success");
      GitService.fetchStatus();
    }).catch(err => {
      EditorStore.setStatus("Failed to save some files", "error");
    }).finally(() => setLoading(prev => ({ ...prev, saveAll: false })));
  };

  const handleTabDragStart = (sourcePaneId, tabId) => {
    const pane2 = EditorStore.getState().panes.find(p => p.id === 2);
    if (!pane2 || pane2.tabs.length === 0) {
      setPane1Width(50);
    }
    setDraggedTab({ sourcePaneId, tabId });
  };

  const clearDragState = () => {
    setDraggedTab(null);
    setDragOverPaneId(null);
  };

  const moveDraggedTabToPane = (targetPaneId) => {
    if (!draggedTab) return;
    TabManager.moveTabToPane(draggedTab.sourcePaneId, targetPaneId, draggedTab.tabId);
    clearDragState();
  };

  const handleFormat = () => {
    if (!activeTab) return;
    
    const isRubyLang = activeTab.path.endsWith('.rb') || activeTab.path.endsWith('.gemspec') || activeTab.path.endsWith("Rakefile") || activeTab.path.endsWith("Gemfile");
    
    if (activeTab.dirty) handleSave(focusedPane.id, activeTab); // save first

    if (isRubyLang) {
      setLoading(prev => ({ ...prev, format: true }));
      EditorStore.setStatus("Formatting...", "info");
      FileService.formatFile(activeTab.path).then(res => {
        if (res.content) {
          // Update content without marking dirty
          const newPanes = EditorStore.getState().panes.map(p => {
             if (p.id === focusedPane.id) return { ...p, tabs: p.tabs.map(t => t.id === activeTab.id ? { ...t, content: res.content, dirty: false } : t) };
             return p;
          });
          EditorStore.setState({ panes: newPanes });
        }
        EditorStore.setStatus("Formatted successfully", "success");
        setMarkers(prev => ({ ...prev, [activeTab.id]: [] })); // clear lint markers
        GitService.fetchStatus();
      }).catch(err => EditorStore.setStatus("Format failed: " + err.message, "error"))
        .finally(() => setLoading(prev => ({ ...prev, format: false })));
      return;
    }

    // Attempt Prettier Formatting
    const ext = activeTab.path.split('.').pop().toLowerCase();
    const formatMap = {
      'js': 'babel', 'jsx': 'babel',
      'json': 'json',
      'css': 'css', 'scss': 'scss',
      'html': 'html', 'md': 'markdown'
    };
    const parserName = formatMap[ext];

    if (parserName && window.prettier && window.prettierPlugins) {
      setLoading(prev => ({ ...prev, format: true }));
      EditorStore.setStatus("Formatting with Prettier...", "info");
      window.prettier.format(activeTab.content, {
        parser: parserName,
        plugins: Object.values(window.prettierPlugins),
        tabWidth: 4,
        useTabs: false
      }).then(formatted => {
        const newPanes = EditorStore.getState().panes.map(p => {
           if (p.id === focusedPane.id) return { ...p, tabs: p.tabs.map(t => t.id === activeTab.id ? { ...t, content: formatted, dirty: true } : t) };
           return p;
        });
        EditorStore.setState({ panes: newPanes });
        EditorStore.setStatus("Formatted (Unsaved)", "success");
        GitService.fetchStatus();
      }).catch(err => {
        EditorStore.setStatus("Prettier Formatter failed: " + err.message, "error");
      }).finally(() => {
        setLoading(prev => ({ ...prev, format: false }));
      });
    }
  };

  const handleReloadRails = () => {
    setLoading(prev => ({ ...prev, reload: true }));
    EditorStore.setStatus("Reloading Rails...", "info");
    FileService.reloadRails()
      .then(() => EditorStore.setStatus("Rails reloaded (restart.txt touched)", "success"))
      .catch((e) => EditorStore.setStatus("Reload failed", "error"))
      .finally(() => setLoading(prev => ({ ...prev, reload: false })));
  };

  const _debouncedSearch = useRef(window._.debounce((q) => {
    if (!q.trim()) {
      EditorStore.setState({ searchResults: [] });
      return;
    }
    EditorStore.setStatus("Searching project...", "info");
    SearchService.projectSearch(q).then(res => {
      EditorStore.setStatus(`Found ${res.length} results`, "success");
    });
  }, 400)).current;

  const handleSearchChange = (e) => {
    const val = e.target.value;
    setSearchQuery(val);
    _debouncedSearch(val);
  };

  const execSearch = (e) => {
    e.preventDefault();
    _debouncedSearch(searchQuery);
  };

  const toggleGitPanel = () => {
    setShowGitPanel((prev) => {
      const next = !prev;
      if (next) GitService.fetchInfo();
      return next;
    });
  };

  const handleToggleSection = (sectionKey, isCollapsed) => {
    setCollapsedSections(prev => ({ ...prev, [sectionKey]: isCollapsed }));
  };

  const handleCollapseAll = () => setExpandedDirs({});

  const openContextMenu = (e, node) => {
    setContextMenu({ x: e.clientX, y: e.clientY, node });
    setSelectedTreeNode(node);
  };

  const closeContextMenu = () => setContextMenu(null);

  const handleContextMenuAction = (action) => {
    const node = contextMenu && contextMenu.node;
    closeContextMenu();
    if (action === 'open' && node) { handleHardOpenFile(node.path, node.name); return; }
    if (action === 'newFile') { handleCreateFile(node); return; }
    if (action === 'newFolder') { handleCreateDir(node); return; }
    if (action === 'rename') { handleRenamePath(node); return; }
    if (action === 'delete') { handleDeletePath(node); return; }
    if (action === 'copyPath' && node) {
      if (navigator.clipboard) {
        navigator.clipboard.writeText(node.path).catch(() => {});
      }
      EditorStore.setStatus('Copied: ' + node.path, 'info');
    }
  };

  const startPaneResize = (e) => {
    e.preventDefault();
    resizeSessionRef.current = { mode: 'pane' };
    setActiveResizeMode('pane');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  const startSidebarResize = (e) => {
    e.preventDefault();
    resizeSessionRef.current = { mode: 'sidebar' };
    setActiveResizeMode('sidebar');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  const openFileFromGitPanel = (path, name) => {
    if (!path) return;
    handleSelectFile(path, name || path.split('/').pop());
  };

  const pathMatchesNodeOrDescendant = (value, targetPath) => {
    if (!value || !targetPath) return false;
    return value === targetPath || value.indexOf(targetPath + '/') === 0 || value.indexOf(targetPath + '::preview') === 0;
  };

  const rewritePathAfterRename = (value, oldPath, newPath) => {
    if (!value || !oldPath || !newPath) return value;
    if (value === oldPath) return newPath;
    if (value === oldPath + '::preview') return newPath + '::preview';
    if (value.indexOf(oldPath + '/') === 0) return newPath + value.slice(oldPath.length);
    return value;
  };

  const applyRenameToOpenTabs = (oldPath, newPath) => {
    const currentState = EditorStore.getState();
    const newPanes = currentState.panes.map((pane) => {
      const renamedTabs = pane.tabs.map((tab) => {
        const nextPath = rewritePathAfterRename(tab.path, oldPath, newPath);
        const nextPreviewFor = rewritePathAfterRename(tab.previewFor, oldPath, newPath);
        if (nextPath === tab.path && nextPreviewFor === tab.previewFor) return tab;

        const defaultName = nextPath.split('/').pop();
        const previewSourceName = nextPreviewFor ? nextPreviewFor.split('/').pop() : defaultName;
        return {
          ...tab,
          id: nextPath,
          path: nextPath,
          name: tab.isPreview ? (previewSourceName + '-preview') : defaultName,
          previewFor: nextPreviewFor
        };
      });

      return {
        ...pane,
        tabs: renamedTabs,
        activeTabId: rewritePathAfterRename(pane.activeTabId, oldPath, newPath)
      };
    });

    EditorStore.setState({
      panes: newPanes,
      activeTabId: rewritePathAfterRename(currentState.activeTabId, oldPath, newPath)
    });
  };

  const removeDeletedPathFromOpenTabs = (targetPath) => {
    const currentState = EditorStore.getState();
    const removedTabIds = [];

    const newPanes = currentState.panes.map((pane) => {
      const keptTabs = pane.tabs.filter((tab) => {
        const removeTab = pathMatchesNodeOrDescendant(tab.path, targetPath) || pathMatchesNodeOrDescendant(tab.previewFor, targetPath);
        if (removeTab) {
          removedTabIds.push(tab.id);
        }
        return !removeTab;
      });

      let nextActiveTabId = pane.activeTabId;
      const activeStillExists = keptTabs.some((tab) => tab.id === nextActiveTabId);
      if (!activeStillExists) {
        nextActiveTabId = keptTabs.length ? keptTabs[keptTabs.length - 1].id : null;
      }

      return {
        ...pane,
        tabs: keptTabs,
        activeTabId: nextActiveTabId
      };
    });

    let nextFocusedPaneId = currentState.focusedPaneId;
    const focusedPane = newPanes.find((pane) => pane.id === nextFocusedPaneId);
    if (!focusedPane || focusedPane.tabs.length === 0) {
      const paneWithTabs = newPanes.find((pane) => pane.tabs.length > 0);
      nextFocusedPaneId = paneWithTabs ? paneWithTabs.id : 1;
    }

    const activePane = newPanes.find((pane) => pane.id === nextFocusedPaneId);
    EditorStore.setState({
      panes: newPanes,
      focusedPaneId: nextFocusedPaneId,
      activeTabId: activePane ? activePane.activeTabId : null
    });

    if (removedTabIds.length) {
      setMarkers((prev) => {
        const next = { ...prev };
        removedTabIds.forEach((tabId) => delete next[tabId]);
        return next;
      });
    }
  };

  const handleCreateFile = (targetNode) => {
    const node = targetNode !== undefined ? targetNode : selectedTreeNode;
    const baseDir = node
      ? (node.type === 'folder' ? node.path : parentDir(node.path))
      : '';
    // Ensure the target folder is expanded so the inline row is visible
    if (baseDir) setExpandedDirs(prev => Object.assign({}, prev, { [baseDir]: true }));
    setPendingRename(null);
    setPendingCreate({ type: 'file', parentPath: baseDir });
  };

  const handleCreateDir = (targetNode) => {
    const node = targetNode !== undefined ? targetNode : selectedTreeNode;
    const baseDir = node
      ? (node.type === 'folder' ? node.path : parentDir(node.path))
      : '';
    if (baseDir) setExpandedDirs(prev => Object.assign({}, prev, { [baseDir]: true }));
    setPendingRename(null);
    setPendingCreate({ type: 'folder', parentPath: baseDir });
  };

  const handleCreateConfirm = (name) => {
    if (!pendingCreate || !name) return;
    const { type, parentPath } = pendingCreate;
    const path = normalizeRelativePath(parentPath ? (parentPath + '/' + name) : name);
    setPendingCreate(null);

    if (type === 'file') {
      setLoading((prev) => ({ ...prev, createFile: true }));
      FileService.createFile(path, '').then((res) => {
        const createdPath = (res && res.path) || path;
        const createdName = createdPath.split('/').pop();
        setSelectedTreeNode({ path: createdPath, name: createdName, type: 'file' });
        EditorStore.setStatus('Created file: ' + createdName, 'success');
        return refreshProjectTree().then(() => {
          handleSelectFile(createdPath, createdName);
          GitService.fetchStatus();
        });
      }).catch((err) => {
        const message = (err && err.response && err.response.data && err.response.data.error) || err.message;
        EditorStore.setStatus('Create file failed: ' + message, 'error');
      }).finally(() => setLoading((prev) => ({ ...prev, createFile: false })));
    } else {
      setLoading((prev) => ({ ...prev, createDir: true }));
      FileService.createDir(path).then((res) => {
        const createdPath = (res && res.path) || path;
        setSelectedTreeNode({ path: createdPath, name: createdPath.split('/').pop(), type: 'folder' });
        EditorStore.setStatus('Created folder: ' + createdPath, 'success');
        return refreshProjectTree().then(() => GitService.fetchStatus());
      }).catch((err) => {
        const message = (err && err.response && err.response.data && err.response.data.error) || err.message;
        EditorStore.setStatus('Create folder failed: ' + message, 'error');
      }).finally(() => setLoading((prev) => ({ ...prev, createDir: false })));
    }
  };

  const handleCreateCancel = () => setPendingCreate(null);

  const handleRenamePath = (targetNode) => {
    const node = targetNode !== undefined ? targetNode : selectedTreeNode;
    if (!node || !node.path) {
      EditorStore.setStatus('Select a file or folder to rename first.', 'warning');
      return;
    }

    const itemPath = node.path;
    const parentPath = parentDir(itemPath);
    if (parentPath) {
      setExpandedDirs(prev => Object.assign({}, prev, { [parentPath]: true }));
    }
    setPendingCreate(null);
    setPendingRename({
      path: itemPath,
      parentPath: parentPath,
      type: node.type,
      currentName: node.name || itemPath.split('/').pop()
    });
  };

  const handleRenameConfirm = (name, renameTarget) => {
    const target = renameTarget || pendingRename;
    if (!target || !name) return;

    const oldPath = target.path;
    const currentName = target.currentName || oldPath.split('/').pop();
    const nextName = name.trim();
    setPendingRename(null);

    if (!nextName || nextName === currentName) return;

    const nextPath = normalizeRelativePath(parentDir(oldPath) ? (parentDir(oldPath) + '/' + nextName) : nextName);
    if (!nextPath || nextPath === oldPath) return;

    setLoading((prev) => ({ ...prev, renamePath: true }));
    FileService.renamePath(oldPath, nextPath).then((res) => {
      const renamedPath = (res && res.path) || nextPath;
      applyRenameToOpenTabs(oldPath, renamedPath);
      setSelectedTreeNode((prev) => prev ? { ...prev, path: renamedPath, name: renamedPath.split('/').pop() } : prev);
      EditorStore.setStatus('Renamed to: ' + renamedPath, 'success');
      return refreshProjectTree().then(() => {
        GitService.fetchStatus();
      });
    }).catch((err) => {
      const message = (err && err.response && err.response.data && err.response.data.error) || err.message;
      EditorStore.setStatus('Rename failed: ' + message, 'error');
    }).finally(() => {
      setLoading((prev) => ({ ...prev, renamePath: false }));
    });
  };

  const handleRenameCancel = () => setPendingRename(null);

  const handleDeletePath = (targetNode) => {
    const node = targetNode !== undefined ? targetNode : selectedTreeNode;
    if (!node || !node.path) {
      EditorStore.setStatus('Select a file or folder to delete first.', 'warning');
      return;
    }

    const targetPath = node.path;
    const confirmed = window.confirm('Delete ' + targetPath + '? This cannot be undone.');
    if (!confirmed) return;

    setLoading((prev) => ({ ...prev, deletePath: true }));
    FileService.deletePath(targetPath).then(() => {
      removeDeletedPathFromOpenTabs(targetPath);
      setSelectedTreeNode(null);
      EditorStore.setStatus('Deleted: ' + targetPath, 'success');
      return refreshProjectTree().then(() => {
        GitService.fetchStatus();
      });
    }).catch((err) => {
      const message = (err && err.response && err.response.data && err.response.data.error) || err.message;
      EditorStore.setStatus('Delete failed: ' + message, 'error');
    }).finally(() => {
      setLoading((prev) => ({ ...prev, deletePath: false }));
    });
  };

  const projectSectionTitle = deriveProjectRootName().toUpperCase();
  const selectedTreePath = selectedTreeNode ? selectedTreeNode.path : null;
  const isRuby = activeTab && isRubyPath(activeTab.path);
  const supportedPrettierExts = ['js', 'jsx', 'json', 'css', 'scss', 'html', 'md'];
  const isPrettierable = activeTab && supportedPrettierExts.includes(activeTab.path.split('.').pop().toLowerCase());
  const canLintAndFormat = activeTab && (isRuby || isPrettierable);
  const hasGitBranch = !!(state.gitBranch && state.gitBranch.trim());

  return (
    <div className="ide-shell">
      {/* TITLE BAR */}
      <div className="ide-titlebar">
        <i className="fas fa-layer-group ide-titlebar-icon"></i>
        <div className="ide-titlebar-title">Mini Browser Editor — {window.location.host}</div>
        <div style={{ marginLeft: "auto", display: "flex", gap: "4px", height: "100%", alignItems: "center" }}>
          <button className="statusbar-btn" onClick={() => activeTab && handleSave(focusedPane.id, activeTab)} disabled={loading.save || !activeTab || !activeTab.dirty}>
            <i className={loading.save ? "fas fa-spinner fa-spin" : "fas fa-save"}></i> Save {(activeTab && activeTab.dirty) ? "●" : ""}
          </button>
          <button className="statusbar-btn" onClick={handleSaveAll} disabled={loading.saveAll || !state.panes.flatMap(p => p.tabs).some(t => t.dirty)}>
            <i className={loading.saveAll ? "fas fa-spinner fa-spin" : "fas fa-save"} style={loading.saveAll ? {} : { position: 'relative' }}>
              {!loading.saveAll && <i className="fas fa-save" style={{ position: 'absolute', top: '-2px', left: '3px', fontSize: '9px', opacity: 0.8 }}></i>}
            </i> Save All
          </button>
          <div className="statusbar-sep"></div>
          <button className="statusbar-btn" onClick={handleFormat} disabled={loading.format || !canLintAndFormat}>
            <i className={loading.format ? "fas fa-spinner fa-spin" : "fas fa-magic"}></i> Format
          </button>
          <div className="statusbar-sep"></div>
          <button className="statusbar-btn" onClick={handleReloadRails} disabled={loading.reload}>
            <i className={loading.reload ? "fas fa-spinner fa-spin" : "fas fa-sync-alt"}></i> Reload Rails
          </button>
          {hasGitBranch && (
            <React.Fragment>
              <div className="statusbar-sep"></div>
              <button type="button" className="statusbar-btn titlebar-git-btn" onClick={toggleGitPanel}>
                <i className="fas fa-code-branch"></i> Git
              </button>
            </React.Fragment>
          )}
        </div>
      </div>

      <div className="ide-body" id="ide-body-container">
        {/* SIDEBAR */}
        <div className="ide-sidebar" style={{ width: `${sidebarWidth}px` }}>
          <div className="ide-sidebar-tabs">
            <button type="button" className={`ide-sidebar-tab ${activeSidebarTab === 'explorer' ? 'active' : ''}`} onClick={() => setActiveSidebarTab('explorer')}>EXPLORER</button>
            <button type="button" className={`ide-sidebar-tab ${activeSidebarTab === 'search' ? 'active' : ''}`} onClick={() => setActiveSidebarTab('search')}>SEARCH</button>
          </div>
          
          {activeSidebarTab === 'explorer' && (
            <div className="ide-sidebar-content">
              {state.panes.flatMap(p => p.tabs).length > 0 && (
                <CollapsibleSection 
                  title="OPEN EDITORS"
                  isCollapsed={collapsedSections.openEditors}
                  onToggle={(isCollapsed) => handleToggleSection('openEditors', isCollapsed)}
                >
                  <div style={{ marginBottom: "12px" }}>
                    {state.panes.map(pane => {
                      if (pane.tabs.length === 0) return null;
                      const isPane2 = pane.id === 2;
                      return (
                        <div key={pane.id} style={{ marginBottom: pane.id === 1 && state.panes[1].tabs.length > 0 ? "10px" : "0" }}>
                          {state.panes[1].tabs.length > 0 && <div className="ide-sidebar-header" style={{ fontSize: '10px', opacity: 0.7, paddingLeft: '8px', marginBottom: '4px' }}>GROUP {pane.id}</div>}
                          <div className="file-tree">
                            {pane.tabs.map(tab => (
                              <div 
                                key={tab.id} 
                                className={`tree-item ${pane.activeTabId === tab.id && state.focusedPaneId === pane.id ? "active" : ""}`}
                                onClick={() => { TabManager.focusPane(pane.id); TabManager.switchTab(pane.id, tab.id); }}
                              >
                                <i className={`tree-item-icon ${window.getFileIcon ? window.getFileIcon(tab.name) : 'far fa-file-code'} tree-file-icon`}></i>
                                <div className="tree-item-name" style={{ display: 'flex', alignItems: 'center' }}>
                                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{tab.name}</span>
                                  {tab.dirty && <i className="fas fa-circle" style={{ fontSize: '5px', color: '#e3d286', marginLeft: '6px', marginTop: '1px' }}></i>}
                                </div>
                                <div className="tab-actions" style={{ display: 'flex', position: 'absolute', right: '4px', top: 0, height: '100%', alignItems: 'center' }}>
                                  <div className="tab-split" onClick={(e) => { e.stopPropagation(); TabManager.moveTabToPane(pane.id, pane.id === 1 ? 2 : 1, tab.id); }} style={{ padding: '0 4px', cursor: 'pointer', opacity: 0.6 }} title={`Move to Group ${pane.id === 1 ? 2 : 1}`}>
                                    <i className={isPane2 ? "fas fa-chevron-left" : "fas fa-chevron-right"}></i>
                                  </div>
                                  <div className="tab-close" onClick={(e) => { e.stopPropagation(); requestCloseTab(pane.id, tab.id); }} style={{ padding: '0 4px', cursor: 'pointer', opacity: 0.6 }}>
                                    <i className="fas fa-times"></i>
                                  </div>
                                </div>
                              </div>
                            ))}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </CollapsibleSection>
              )}
              <CollapsibleSection
                title={projectSectionTitle}
                isCollapsed={collapsedSections.projects}
                onToggle={(isCollapsed) => handleToggleSection('projects', isCollapsed)}
                  actions={(
                  <div className="project-actions" role="toolbar" aria-label="Project actions">
                    <button
                      type="button"
                      className="project-action-btn"
                      title="Collapse all folders"
                      onClick={handleCollapseAll}
                    >
                      <i className="fas fa-compress-alt"></i>
                    </button>
                    <button
                      type="button"
                      className="project-action-btn"
                      title="New file"
                      onClick={() => handleCreateFile()}
                      disabled={!!loading.createFile}
                    >
                      <i className={loading.createFile ? 'fas fa-spinner fa-spin' : 'far fa-file'}></i>
                    </button>
                    <button
                      type="button"
                      className="project-action-btn"
                      title="New folder"
                      onClick={() => handleCreateDir()}
                      disabled={!!loading.createDir}
                    >
                      <i className={loading.createDir ? 'fas fa-spinner fa-spin' : 'far fa-folder'}></i>
                    </button>
                    <button
                      type="button"
                      className="project-action-btn"
                      title="Rename selected"
                      onClick={() => handleRenamePath()}
                      disabled={!!loading.renamePath || !selectedTreePath}
                    >
                      <i className={loading.renamePath ? 'fas fa-spinner fa-spin' : 'fas fa-pen'}></i>
                    </button>
                    <button
                      type="button"
                      className="project-action-btn danger"
                      title="Delete selected"
                      onClick={() => handleDeletePath()}
                      disabled={!!loading.deletePath || !selectedTreePath}
                    >
                      <i className={loading.deletePath ? 'fas fa-spinner fa-spin' : 'far fa-trash-alt'}></i>
                    </button>
                  </div>
                )}
              >
                <FileTree
                  items={treeData}
                  onSelect={handleSoftOpenFile}
                  activePath={activeTab && activeTab.path}
                  selectedPath={selectedTreePath}
                  onNodeSelect={setSelectedTreeNode}
                  gitFiles={state.gitFiles}
                  expandedDirs={expandedDirs}
                  onExpandedDirsChange={setExpandedDirs}
                  onFileDoubleClick={handleHardOpenFile}
                  onContextMenu={openContextMenu}
                  pendingCreate={pendingCreate}
                  onCreateConfirm={handleCreateConfirm}
                  onCreateCancel={handleCreateCancel}
                  pendingRename={pendingRename}
                  onRenameConfirm={handleRenameConfirm}
                  onRenameCancel={handleRenameCancel}
                />
              </CollapsibleSection>
            </div>
          )}

          {activeSidebarTab === 'search' && (
            <form className="search-panel" onSubmit={execSearch}>
              <div className="search-input-wrap">
                <input 
                  className="search-input" 
                  placeholder="Find in files..." 
                  value={searchQuery}
                  onChange={handleSearchChange}
                />
                <button type="submit" className="search-btn"><i className="fas fa-search"></i></button>
              </div>
              <div className="search-results">
                {state.searchResults.map((res, i) => (
                  <div key={i} className="search-result-item" onClick={() => handleSelectFile(res.file, res.file.split('/').pop(), res.line)}>
                    <div className="search-result-file">{res.file} <span className="search-result-line-num">:{res.line}</span></div>
                    <div className="search-result-text">{res.text}</div>
                  </div>
                ))}
              </div>
            </form>
          )}
        </div>

        <div
          className={`panel-divider sidebar-divider ${activeResizeMode === 'sidebar' ? 'active' : ''}`}
          onMouseDown={startSidebarResize}
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize explorer panel"
        ></div>

        {/* EDITOR AREA */}
        <div
          id="ide-main-split-container"
          className="ide-main"
          style={{ display: 'flex', flexDirection: 'row', width: '100%', height: '100%', cursor: activeResizeMode === 'pane' ? 'col-resize' : 'default', userSelect: activeResizeMode ? 'none' : 'auto' }}
          onDragOverCapture={(e) => {
            if (!draggedTab) return;
            e.preventDefault();

            const rect = e.currentTarget.getBoundingClientRect();
            const splitAtX = rect.left + (rect.width * (pane1Width / 100));
            const hoverPaneId = e.clientX >= splitAtX ? 2 : 1;
            const nextDropPane = hoverPaneId === draggedTab.sourcePaneId ? null : hoverPaneId;

            e.dataTransfer.dropEffect = nextDropPane ? 'move' : 'none';
            if (dragOverPaneId !== nextDropPane) setDragOverPaneId(nextDropPane);
          }}
          onDropCapture={(e) => {
            if (!draggedTab) return;
            e.preventDefault();

            const rect = e.currentTarget.getBoundingClientRect();
            const splitAtX = rect.left + (rect.width * (pane1Width / 100));
            const targetPaneId = e.clientX >= splitAtX ? 2 : 1;

            if (targetPaneId !== draggedTab.sourcePaneId) {
              moveDraggedTabToPane(targetPaneId);
            } else {
              clearDragState();
            }
          }}
        >
           {state.panes.map((pane, idx) => {
             if (pane.id === 2 && pane.tabs.length === 0 && !draggedTab) return null; // Show pane 2 while dragging to allow drop-to-split
             
             // Dynamic width distribution
             const isSplit = state.panes[1].tabs.length > 0 || !!draggedTab;
             let flexBasis = '100%';
             if (isSplit) flexBasis = pane.id === 1 ? `${pane1Width}%` : `${100 - pane1Width}%`;

             const isFocused = state.focusedPaneId === pane.id;
             const pActiveTab = pane.tabs.find(t => t.id === pane.activeTabId);
             const canAcceptDrop = !!draggedTab && draggedTab.sourcePaneId !== pane.id;
             const isDropTarget = canAcceptDrop && dragOverPaneId === pane.id;
             
             return (
               <React.Fragment key={pane.id}>
                 {idx === 1 && isSplit && (
                   <div 
                     className={`panel-divider pane-divider ${activeResizeMode === 'pane' ? 'active' : ''}`}
                     onMouseDown={startPaneResize}
                   ></div>
                 )}
                 <div
                   className={`ide-pane ${isFocused ? 'focused' : ''} ${isDropTarget ? 'drop-target' : ''}`}
                   style={{ flexBasis: flexBasis, flexShrink: 0, flexGrow: 0, display: 'flex', flexDirection: 'column', minWidth: 0 }}
                   onClickCapture={() => TabManager.focusPane(pane.id)}
                   onDragOver={(e) => {
                     if (!canAcceptDrop) return;
                     e.preventDefault();
                     e.dataTransfer.dropEffect = 'move';
                     if (dragOverPaneId !== pane.id) setDragOverPaneId(pane.id);
                   }}
                   onDragEnter={(e) => {
                     if (!canAcceptDrop) return;
                     e.preventDefault();
                     if (dragOverPaneId !== pane.id) setDragOverPaneId(pane.id);
                   }}
                   onDragLeave={(e) => {
                     if (dragOverPaneId !== pane.id) return;
                     if (!e.currentTarget.contains(e.relatedTarget)) {
                       setDragOverPaneId(null);
                     }
                   }}
                   onDrop={(e) => {
                     if (!canAcceptDrop) return;
                     e.preventDefault();
                     moveDraggedTabToPane(pane.id);
                   }}
                 >
                   {pane.tabs.length > 0 ? (
                      <React.Fragment>
                        <TabBar 
                          tabs={pane.tabs} 
                          activeId={pane.activeTabId} 
                          onSelect={(id) => TabManager.switchTab(pane.id, id)}
                          onClose={(id) => requestCloseTab(pane.id, id)}
                          onTabDragStart={(id) => handleTabDragStart(pane.id, id)}
                          onTabDragEnd={clearDragState}
                          onHardenTab={(tabId) => TabManager.hardenTab(pane.id, tabId)}
                        />
                        <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', visibility: activeResizeMode === 'pane' ? 'hidden' : 'visible' }}>
                          <EditorPanel
                            key={pActiveTab.id}
                            tab={pActiveTab}
                            paneId={pane.id}
                            markers={markers[pActiveTab.id] || []}
                            onContentChange={(val) => {
                              TabManager.markDirty(pane.id, pActiveTab.id, val);
                            }}
                          />
                        </div>
                      </React.Fragment>
                    ) : (
                      <div className="tab-welcome">
                        {canAcceptDrop ? (
                          <React.Fragment>
                            <i className="fas fa-columns"></i>
                            <h2>Drop Tab Here</h2>
                            <p>Release to move this file into Group {pane.id}.</p>
                          </React.Fragment>
                        ) : (
                          pane.id === 1 ? (
                            <React.Fragment>
                              <i className="fas fa-code"></i>
                              <h2>Mini Browser Editor</h2>
                              <p>Welcome to the development environment.</p>
                              <p>Open a file from the explorer or press <kbd>Ctrl+P</kbd> to quick-open.</p>
                            </React.Fragment>
                          ) : null
                        )}
                      </div>
                    )}
                 </div>
               </React.Fragment>
             );
          })}
        </div>

        {showGitPanel && (
          <GitPanel
            gitInfo={state.gitInfo}
            error={state.gitInfoError}
            onRefresh={() => GitService.fetchInfo()}
            onClose={() => setShowGitPanel(false)}
            onOpenFile={openFileFromGitPanel}
          />
        )}
      </div>

      {/* STATUS BAR */}
      <div className="ide-statusbar">
        {hasGitBranch && (
          <div className="statusbar-branch">
            <i className="fas fa-code-branch"></i> {state.gitBranch}
          </div>
        )}
        
        <div className={`statusbar-msg ${state.statusMessage.kind}`}>
          {state.statusMessage.text}
        </div>
      </div>

      {quickOpen && <QuickOpenDialog onSelect={handleSelectFile} onClose={() => setQuickOpen(false)} />}

      {/* Right-click context menu */}
      {contextMenu && (
        <React.Fragment>
          <div
            style={{ position: 'fixed', inset: 0, zIndex: 9998 }}
            onClick={closeContextMenu}
            onContextMenu={(e) => { e.preventDefault(); closeContextMenu(); }}
          />
          <div
            className="context-menu"
            style={{ left: contextMenu.x, top: contextMenu.y }}
            onClick={(e) => e.stopPropagation()}
          >
            {contextMenu.node && contextMenu.node.type === 'file' && (
              <div className="context-menu-item" onClick={() => handleContextMenuAction('open')}>
                <i className="far fa-file-code context-menu-icon"></i> Open
              </div>
            )}
            <div className="context-menu-item" onClick={() => handleContextMenuAction('newFile')}>
              <i className="far fa-file context-menu-icon"></i> New File
            </div>
            <div className="context-menu-item" onClick={() => handleContextMenuAction('newFolder')}>
              <i className="far fa-folder context-menu-icon"></i> New Folder
            </div>
            <div className="context-menu-divider"></div>
            <div className="context-menu-item" onClick={() => handleContextMenuAction('rename')}>
              <i className="fas fa-pen context-menu-icon"></i> Rename
            </div>
            <div className="context-menu-item context-menu-item-danger" onClick={() => handleContextMenuAction('delete')}>
              <i className="far fa-trash-alt context-menu-icon"></i> Delete
            </div>
            <div className="context-menu-divider"></div>
            <div className="context-menu-item" onClick={() => handleContextMenuAction('copyPath')}>
              <i className="fas fa-copy context-menu-icon"></i> Copy Path
            </div>
          </div>
        </React.Fragment>
      )}

      {closingTabId && (
        <div className="quick-open-overlay" style={{ zIndex: 10001 }}>
          <div className="quick-open-box" style={{ width: '400px', padding: '20px', background: '#252526', border: '1px solid #454545' }}>
            <h3 style={{ marginTop: 0, fontSize: '14px', color: '#fff' }}>Unsaved Changes</h3>
            <p style={{ color: '#ccc', margin: '16px 0', fontSize: '13px' }}>
              Do you want to save the changes you made to <strong>{(state.panes.flatMap(p => p.tabs).find(t => t.id === closingTabId) || {}).name}</strong>?
            </p>
            <p style={{ color: '#888', marginBottom: '24px', fontSize: '12px' }}>
              Your changes will be lost if you don't save them.
            </p>
            <div style={{ display: 'flex', gap: '8px', justifyContent: 'flex-end' }}>
              <button 
                onClick={() => confirmCloseTab(true)} 
                style={{ padding: '6px 16px', background: '#0e639c', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}>
                Save
              </button>
              <button 
                onClick={() => confirmCloseTab(false)} 
                style={{ padding: '6px 16px', background: 'transparent', color: '#ccc', border: '1px solid #666', borderRadius: '4px', cursor: 'pointer' }}>
                Don't Save
              </button>
              <button 
                onClick={() => setClosingTabId(null)} 
                style={{ padding: '6px 16px', background: 'transparent', color: '#888', border: 'none', cursor: 'pointer' }}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

window.MbeditorApp = MbeditorApp;
