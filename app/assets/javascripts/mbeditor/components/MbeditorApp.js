"use strict";

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i["return"]) _i["return"](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError("Invalid attempt to destructure non-iterable instance"); } }; })();

var _extends = Object.assign || function (target) { for (var i = 1; i < arguments.length; i++) { var source = arguments[i]; for (var key in source) { if (Object.prototype.hasOwnProperty.call(source, key)) { target[key] = source[key]; } } } return target; };

function _defineProperty(obj, key, value) { if (key in obj) { Object.defineProperty(obj, key, { value: value, enumerable: true, configurable: true, writable: true }); } else { obj[key] = value; } return obj; }

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var SIDEBAR_MIN_WIDTH = 240;
var SIDEBAR_MAX_WIDTH = 560;
var EDITOR_MIN_WIDTH = 320;
var GIT_PANEL_MIN_WIDTH = 280;
var PANE_MIN_WIDTH_PERCENT = 20;
var PANE_MAX_WIDTH_PERCENT = 80;

var SidebarActionButton = function SidebarActionButton(_ref) {
  var title = _ref.title;
  var iconClass = _ref.iconClass;
  var onClick = _ref.onClick;
  var _ref$disabled = _ref.disabled;
  var disabled = _ref$disabled === undefined ? false : _ref$disabled;
  var _ref$danger = _ref.danger;
  var danger = _ref$danger === undefined ? false : _ref$danger;
  var _ref$ariaLabel = _ref.ariaLabel;
  var ariaLabel = _ref$ariaLabel === undefined ? null : _ref$ariaLabel;

  return React.createElement(
    "button",
    {
      type: "button",
      className: "project-action-btn" + (danger ? " danger" : ""),
      title: title,
      "aria-label": ariaLabel || title,
      onClick: onClick,
      disabled: !!disabled
    },
    React.createElement("i", { className: iconClass })
  );
};

var SectionActionGroup = function SectionActionGroup(_ref2) {
  var ariaLabel = _ref2.ariaLabel;
  var children = _ref2.children;
  var _ref2$className = _ref2.className;
  var className = _ref2$className === undefined ? "" : _ref2$className;

  return React.createElement(
    "div",
    {
      className: "project-actions" + (className ? " " + className : ""),
      role: "toolbar",
      "aria-label": ariaLabel
    },
    children
  );
};

var MbeditorApp = function MbeditorApp() {
  var _useState = useState(EditorStore.getState());

  var _useState2 = _slicedToArray(_useState, 2);

  var state = _useState2[0];
  var setState = _useState2[1];

  var _useState3 = useState(false);

  var _useState32 = _slicedToArray(_useState3, 2);

  var quickOpen = _useState32[0];
  var setQuickOpen = _useState32[1];

  var _useState4 = useState([]);

  var _useState42 = _slicedToArray(_useState4, 2);

  var treeData = _useState42[0];
  var setTreeData = _useState42[1];

  var _useState5 = useState("");

  var _useState52 = _slicedToArray(_useState5, 2);

  var projectRootName = _useState52[0];
  var setProjectRootName = _useState52[1];

  var _useState6 = useState(null);

  var _useState62 = _slicedToArray(_useState6, 2);

  var selectedTreeNode = _useState62[0];
  var setSelectedTreeNode = _useState62[1];

  var _useState7 = useState("");

  var _useState72 = _slicedToArray(_useState7, 2);

  var searchQuery = _useState72[0];
  var setSearchQuery = _useState72[1];

  var _useState8 = useState("explorer");

  var _useState82 = _slicedToArray(_useState8, 2);

  var activeSidebarTab = _useState82[0];
  var setActiveSidebarTab = _useState82[1];

  var _useState9 = useState({});

  var _useState92 = _slicedToArray(_useState9, 2);

  var markers = _useState92[0];
  var setMarkers = _useState92[1];
  // { tabId: [] }

  var _useState10 = useState({});

  var _useState102 = _slicedToArray(_useState10, 2);

  var loading = _useState102[0];
  var setLoading = _useState102[1];

  var _useState11 = useState(null);

  var _useState112 = _slicedToArray(_useState11, 2);

  var closingTabId = _useState112[0];
  var setClosingTabId = _useState112[1];

  var _useState12 = useState(null);

  var _useState122 = _slicedToArray(_useState12, 2);

  var closingPaneId = _useState122[0];
  var setClosingPaneId = _useState122[1];

  var _useState13 = useState(SIDEBAR_MIN_WIDTH);

  var _useState132 = _slicedToArray(_useState13, 2);

  var sidebarWidth = _useState132[0];
  var setSidebarWidth = _useState132[1];

  var _useState14 = useState(50);

  var _useState142 = _slicedToArray(_useState14, 2);

  var pane1Width = _useState142[0];
  var setPane1Width = _useState142[1];
  // percentage

  var _useState15 = useState(null);

  var _useState152 = _slicedToArray(_useState15, 2);

  var activeResizeMode = _useState152[0];
  var setActiveResizeMode = _useState152[1];

  var _useState16 = useState(null);

  var _useState162 = _slicedToArray(_useState16, 2);

  var draggedTab = _useState162[0];
  var setDraggedTab = _useState162[1];

  var _useState17 = useState(null);

  var _useState172 = _slicedToArray(_useState17, 2);

  var dragOverPaneId = _useState172[0];
  var setDragOverPaneId = _useState172[1];

  var _useState18 = useState(false);

  var _useState182 = _slicedToArray(_useState18, 2);

  var showGitPanel = _useState182[0];
  var setShowGitPanel = _useState182[1];

  var _useState18h = useState(false);

  var _useState18h2 = _slicedToArray(_useState18h, 2);

  var showHelp = _useState18h2[0];
  var setShowHelp = _useState18h2[1];

  var _useState18b = useState(true);

  var _useState18b2 = _slicedToArray(_useState18b, 2);

  var serverOnline = _useState18b2[0];
  var setServerOnline = _useState18b2[1];

  var _useState18c = useState(false);

  var _useState18c2 = _slicedToArray(_useState18c, 2);

  var rubocopAvailable = _useState18c2[0];
  var setRubocopAvailable = _useState18c2[1];

  var _useState18d = useState(false);

  var _useState18d2 = _slicedToArray(_useState18d, 2);

  var hamlLintAvailable = _useState18d2[0];
  var setHamlLintAvailable = _useState18d2[1];

  var _useState19 = useState({
    openEditors: false,
    projects: false
  });

  var _useState192 = _slicedToArray(_useState19, 2);

  var collapsedSections = _useState192[0];
  var setCollapsedSections = _useState192[1];

  var _useState20 = useState({});

  var _useState202 = _slicedToArray(_useState20, 2);

  var expandedDirs = _useState202[0];
  var setExpandedDirs = _useState202[1];

  var _useState21 = useState(null);

  var _useState212 = _slicedToArray(_useState21, 2);

  var pendingCreate = _useState212[0];
  var setPendingCreate = _useState212[1];

  var _useState22 = useState(null);

  var _useState222 = _slicedToArray(_useState22, 2);

  var pendingRename = _useState222[0];
  var setPendingRename = _useState222[1];

  var _useState23 = useState(null);

  var _useState232 = _slicedToArray(_useState23, 2);

  var contextMenu = _useState232[0];
  var setContextMenu = _useState232[1];

  var resizeSessionRef = useRef(null);
  var resizeRafRef = useRef(null);

  var clamp = function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  };

  var normalizeRelativePath = function normalizeRelativePath(input) {
    return (input || "").replace(/\\/g, "/").trim().replace(/^\/+/, "").replace(/\/+$/, "").replace(/\/+/g, "/");
  };

  var parentDir = function parentDir(path) {
    if (!path) return "";
    var idx = path.lastIndexOf("/");
    return idx > 0 ? path.slice(0, idx) : "";
  };

  var deriveProjectRootName = function deriveProjectRootName() {
    if (projectRootName) return projectRootName;
    var railsRoot = document && document.body && document.body.dataset ? document.body.dataset.railsRoot : "";
    if (!railsRoot) return "PROJECT";
    var parts = railsRoot.split("/").filter(Boolean);
    return parts.length ? parts[parts.length - 1] : "PROJECT";
  };

  var refreshProjectTree = function refreshProjectTree() {
    return FileService.getTree().then(function (data) {
      setTreeData(data || []);
      SearchService.buildIndex(data || []);
      return data || [];
    })["catch"](function (err) {
      EditorStore.setStatus("Failed to refresh files: " + (err && err.message || "Unknown error"), "error");
      return [];
    });
  };

  var isRubyPath = function isRubyPath(path) {
    return path && (path.endsWith('.rb') || path.endsWith('.gemspec') || path.endsWith('Rakefile') || path.endsWith('Gemfile'));
  };

  var applyMarkersForTab = function applyMarkersForTab(paneId, tabId, nextMarkers) {
    var currentPane = EditorStore.getState().panes.find(function (p) {
      return p.id === paneId;
    });
    var current = currentPane ? currentPane.tabs.find(function (t) {
      return t.id === tabId;
    }) : null;
    if (current) current.markers = nextMarkers;
    setMarkers(function (prev) {
      return _extends({}, prev, _defineProperty({}, tabId, nextMarkers));
    });
  };

  var runRubyLint = function runRubyLint(tab, paneId) {
    var options = arguments.length <= 2 || arguments[2] === undefined ? {} : arguments[2];

    if (!tab || (!isRubyPath(tab.path) && !tab.path.endsWith('.haml'))) return Promise.resolve(null);

    if (options.showLoading) {
      setLoading(function (prev) {
        return _extends({}, prev, { lint: true });
      });
    }
    if (options.showStatus) {
      EditorStore.setStatus('Linting...', 'info');
    }

    return FileService.lintFile(tab.path, tab.content).then(function (res) {
      var nextMarkers = res.markers || [];
      applyMarkersForTab(paneId, tab.id, nextMarkers);

      if (options.showStatus) {
        var count = res.summary && res.summary.offense_count || 0;
        EditorStore.setStatus(count === 0 ? 'No RuboCop offenses!' : "Found " + count + " offenses", count === 0 ? 'success' : 'warning');
      }

      return res;
    })["catch"](function (err) {
      if (options.showStatus) {
        EditorStore.setStatus('Lint failed: ' + err.message, 'error');
      }
      return null;
    })["finally"](function () {
      if (options.showLoading) {
        setLoading(function (prev) {
          return _extends({}, prev, { lint: false });
        });
      }
    });
  };

  var _debouncedAutoLint = useRef(window._.debounce(function (tab, paneId) {
    if (!tab) return;
    if (isRubyPath(tab.path)) {
      runRubyLint(tab, paneId);
      return;
    }
    if (tab.path.endsWith('.haml')) {
      runRubyLint(tab, paneId);
      return;
    }

    var ext = tab.path.split('.').pop().toLowerCase();
    var formatMap = {
      'js': 'babel', 'jsx': 'babel',
      'json': 'json',
      'css': 'css', 'scss': 'scss',
      'html': 'html', 'md': 'markdown'
    };
    var parserName = formatMap[ext];

    if (parserName && window.prettier && window.prettierPlugins) {
      window.prettier.format(tab.content, {
        parser: parserName,
        plugins: Object.values(window.prettierPlugins),
        tabWidth: 4,
        useTabs: false
      }).then(function () {}).then(function () {
        var currentPane = EditorStore.getState().panes.find(function (p) {
          return p.id === paneId;
        });
        var current = currentPane ? currentPane.tabs.find(function (t) {
          return t.id === tab.id;
        }) : null;
        if (current) current.markers = [];
        setMarkers(function (prev) {
          return _extends({}, prev, _defineProperty({}, tab.id, []));
        });
      })["catch"](function (err) {
        var newMarkers = [];
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
        var currentPane = EditorStore.getState().panes.find(function (p) {
          return p.id === paneId;
        });
        var current = currentPane ? currentPane.tabs.find(function (t) {
          return t.id === tab.id;
        }) : null;
        if (current) current.markers = newMarkers;
        setMarkers(function (prev) {
          return _extends({}, prev, _defineProperty({}, tab.id, newMarkers));
        });
      });
    }
  }, 600)).current;

  // Persist state when openTabs or activeTabId changes
  useEffect(function () {
    // Subscribe to EditorStore
    var unsubscribe = EditorStore.subscribe(setState);

    // Initial load
    Promise.all([FileService.getWorkspace()["catch"](function () {
      return null;
    }), refreshProjectTree()]).then(function (_ref) {
      var _ref2 = _slicedToArray(_ref, 1);

      var workspace = _ref2[0];

      if (workspace && workspace.rootName) {
        setProjectRootName(workspace.rootName);
      }
      if (workspace && typeof workspace.rubocopAvailable === 'boolean') {
        setRubocopAvailable(workspace.rubocopAvailable);
      }
      if (workspace && typeof workspace.hamlLintAvailable === 'boolean') {
        setHamlLintAvailable(workspace.hamlLintAvailable);
      }
    });
    GitService.fetchStatus();

    // Load persisted state
    FileService.getState().then(function (savedState) {
      var panesToLoad = savedState && savedState.panes;
      if (savedState && savedState.openTabs) {
        panesToLoad = [{ id: 1, tabs: savedState.openTabs, activeTabId: savedState.activeTabId }, { id: 2, tabs: [], activeTabId: null }];
      }
      if (panesToLoad && panesToLoad.length > 0) {
        var allTabs = panesToLoad.flatMap(function (p) {
          return p.tabs;
        });
        Promise.all(allTabs.map(function (t) {
          var sourcePath = t.isPreview || /::preview$/.test(t.path || '') ? t.previewFor || (t.path || '').replace(/::preview$/, '') : t.path;
          return FileService.getFile(sourcePath)["catch"](function () {
            return { content: '' };
          });
        })).then(function (results) {
          var resIdx = 0;
          var restoredPanes = panesToLoad.map(function (p) {
            return _extends({}, p, {
              tabs: p.tabs.map(function (t) {
                return _extends({}, t, { content: results[resIdx++].content });
              })
            });
          });
          EditorStore.setState(_extends({}, savedState, { panes: restoredPanes, openTabs: undefined }));
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
    var onKeyDown = function onKeyDown(e) {
      if ((e.ctrlKey || e.metaKey) && e.key === 'p') {
        e.preventDefault();
        setQuickOpen(true);
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        (function () {
          e.preventDefault();
          var st = EditorStore.getState();
          var focusedPane = st.panes.find(function (p) {
            return p.id === st.focusedPaneId;
          }) || st.panes[0];
          if (focusedPane && focusedPane.activeTabId) {
            var tab = focusedPane.tabs.find(function (t) {
              return t.id === focusedPane.activeTabId;
            });
            if (tab && tab.dirty) handleSave(focusedPane.id, tab);
          }
        })();
      }
      if (e.key === 'Escape') {
        setContextMenu(null);
        setShowHelp(false);
      }
    };

    var handleMouseMove = function handleMouseMove(e) {
      var session = resizeSessionRef.current;
      if (!session) return;

      // Throttle via rAF — skip if a frame is already queued to avoid paint thrashing
      if (resizeRafRef.current) return;
      var clientX = e.clientX;
      resizeRafRef.current = requestAnimationFrame(function () {
        resizeRafRef.current = null;
        var s = resizeSessionRef.current;
        if (!s) return;

        if (s.mode === 'pane') {
          var container = document.getElementById('ide-main-split-container');
          if (!container) return;

          var rect = container.getBoundingClientRect();
          var nextWidth = (clientX - rect.left) / rect.width * 100;
          setPane1Width(clamp(nextWidth, PANE_MIN_WIDTH_PERCENT, PANE_MAX_WIDTH_PERCENT));
        }

        if (s.mode === 'sidebar') {
          var body = document.getElementById('ide-body-container');
          if (!body) return;

          var rect = body.getBoundingClientRect();
          var reservedRight = EDITOR_MIN_WIDTH + (showGitPanel ? GIT_PANEL_MIN_WIDTH : 0);
          var maxSidebarWidth = Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, rect.width - reservedRight));
          var nextWidth = clientX - rect.left;
          setSidebarWidth(clamp(nextWidth, SIDEBAR_MIN_WIDTH, maxSidebarWidth));
        }
      });
    };

    var handleMouseUp = function handleMouseUp() {
      if (!resizeSessionRef.current) return;

      if (resizeRafRef.current) {
        cancelAnimationFrame(resizeRafRef.current);
        resizeRafRef.current = null;
      }
      resizeSessionRef.current = null;
      setActiveResizeMode(null);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return function () {
      unsubscribe();
      if (resizeRafRef.current) {
        cancelAnimationFrame(resizeRafRef.current);
        resizeRafRef.current = null;
      }
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };
  }, [showGitPanel]);

  // Heartbeat — poll /ping every 5s and reflect connectivity in the status bar
  useEffect(function () {
    var wasOnline = true;
    var interval = setInterval(function () {
      FileService.ping().then(function () {
        if (!wasOnline) {
          wasOnline = true;
          setServerOnline(true);
        }
      }).catch(function () {
        if (wasOnline) {
          wasOnline = false;
          setServerOnline(false);
        }
      });
    }, 5000);
    return function () { clearInterval(interval); };
  }, []);

  var handleSelectFile = function handleSelectFile(path, name, line) {
    TabManager.openTab(path, name, line);
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
    setQuickOpen(false);
  };

  // Single-click in explorer: soft (preview) open — replaces any existing soft tab
  var handleSoftOpenFile = function handleSoftOpenFile(path, name) {
    TabManager.openTab(path, name, null, null, true);
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
  };

  // Double-click in explorer or on tab: harden the tab (remove italic/preview)
  var handleHardOpenFile = function handleHardOpenFile(path, name) {
    var st = EditorStore.getState();
    var targetPane = st.panes.find(function (p) {
      return p.tabs.some(function (t) {
        return t.path === path;
      });
    });
    if (targetPane) {
      TabManager.hardenTab(targetPane.id, path);
      TabManager.switchTab(targetPane.id, path);
    } else {
      TabManager.openTab(path, name, null, null, false);
    }
    setSelectedTreeNode({ path: path, name: name || path.split('/').pop(), type: 'file' });
  };

  var requestCloseTab = function requestCloseTab(paneId, id) {
    var pane = state.panes.find(function (p) {
      return p.id === paneId;
    }) || state.panes[0];
    var tab = pane.tabs.find(function (t) {
      return t.id === id;
    });
    if (tab && tab.dirty) {
      setClosingPaneId(paneId);
      setClosingTabId(id);
    } else {
      TabManager.closeTab(paneId, id);
    }
  };

  var confirmCloseTab = function confirmCloseTab(save) {
    var pane = state.panes.find(function (p) {
      return p.id === closingPaneId;
    });
    var tab = pane ? pane.tabs.find(function (t) {
      return t.id === closingTabId;
    }) : null;
    if (!tab) {
      setClosingTabId(null);
      setClosingPaneId(null);
      return;
    }

    if (save) {
      setLoading(function (prev) {
        return _extends({}, prev, { save: true });
      });
      EditorStore.setStatus("Saving " + tab.name + "...", "info");
      FileService.saveFile(tab.path, tab.content).then(function () {
        EditorStore.setStatus("Saved", "success");
        GitService.fetchStatus();
        TabManager.closeTab(closingPaneId, tab.id);
      })["catch"](function (err) {
        EditorStore.setStatus("Save failed: " + err.message, "error");
      })["finally"](function () {
        setLoading(function (prev) {
          return _extends({}, prev, { save: false });
        });
        setClosingTabId(null);
        setClosingPaneId(null);
      });
    } else {
      TabManager.closeTab(closingPaneId, tab.id);
      setClosingTabId(null);
      setClosingPaneId(null);
    }
  };

  var confirmBulkClose = function confirmBulkClose(tabs, scopeLabel) {
    var dirtyCount = tabs.filter(function (tab) {
      return tab.dirty;
    }).length;

    if (dirtyCount === 0) return true;

    var dirtyLabel = dirtyCount === 1 ? "1 unsaved editor has changes." : dirtyCount + " unsaved editors have changes.";
    return window.confirm(dirtyLabel + " Close " + scopeLabel + " without saving?");
  };

  var handleCloseAllEditors = function handleCloseAllEditors() {
    var allTabs = state.panes.flatMap(function (pane) {
      return pane.tabs;
    });
    if (allTabs.length === 0) return;
    if (!confirmBulkClose(allTabs, "all editors")) return;

    TabManager.closeAllTabs();
    setClosingTabId(null);
    setClosingPaneId(null);
    EditorStore.setStatus("Closed " + allTabs.length + " editor" + (allTabs.length === 1 ? "" : "s"), "info");
  };

  var handleCloseEditorsInGroup = function handleCloseEditorsInGroup(paneId) {
    var pane = state.panes.find(function (p) {
      return p.id === paneId;
    });
    if (!pane || pane.tabs.length === 0) return;
    if (!confirmBulkClose(pane.tabs, "all editors in Group " + paneId)) return;

    TabManager.closeAllTabsInPane(paneId);
    setClosingTabId(null);
    setClosingPaneId(null);
    EditorStore.setStatus("Closed " + pane.tabs.length + " editor" + (pane.tabs.length === 1 ? "" : "s") + " in Group " + paneId, "info");
  };

  // Persist state when panes, focusedPaneId, or collapsedSections changes
  useEffect(function () {
    // debounce explicitly using setTimeout to avoid spamming the backend
    var timeoutId = setTimeout(function () {
      var st = EditorStore.getState();
      var lightweightPanes = st.panes.map(function (p) {
        return {
          id: p.id,
          activeTabId: p.activeTabId,
          tabs: p.tabs.map(function (t) {
            return {
              id: t.id,
              path: t.path,
              name: t.name,
              dirty: t.dirty,
              viewState: t.viewState,
              isPreview: !!t.isPreview,
              previewFor: t.previewFor || null
            };
          })
        };
      });
      FileService.saveState({ panes: lightweightPanes, focusedPaneId: st.focusedPaneId, collapsedSections: collapsedSections, expandedDirs: expandedDirs });
    }, 1000);
    return function () {
      return clearTimeout(timeoutId);
    };
  }, [state.panes, state.focusedPaneId, collapsedSections, expandedDirs]);

  var focusedPane = state.panes.find(function (p) {
    return p.id === state.focusedPaneId;
  }) || state.panes[0];
  var activeTab = focusedPane.tabs.find(function (t) {
    return t.id === focusedPane.activeTabId;
  });

  useEffect(function () {
    if (!activeTab || typeof activeTab.content !== 'string') return;
    if (isRubyPath(activeTab.path) && !rubocopAvailable) return;
    if (activeTab.path.endsWith('.haml') && !hamlLintAvailable) return;

    _debouncedAutoLint(activeTab, focusedPane.id);

    return function () {
      _debouncedAutoLint.cancel();
    };
  }, [focusedPane.id, activeTab ? activeTab.id : null, activeTab ? activeTab.content : null, rubocopAvailable, hamlLintAvailable]);

  var handleSave = function handleSave(paneId, tab) {
    setLoading(function (prev) {
      return _extends({}, prev, { save: true });
    });
    EditorStore.setStatus("Saving " + tab.name + "...", "info");
    FileService.saveFile(tab.path, tab.content).then(function () {
      var newPanes = EditorStore.getState().panes.map(function (p) {
        if (p.id === paneId) {
          return _extends({}, p, { tabs: p.tabs.map(function (t) {
              return t.id === tab.id ? _extends({}, t, { dirty: false, cleanContent: tab.content }) : t;
            }) });
        }
        return p;
      });
      EditorStore.setState({ panes: newPanes });
      EditorStore.setStatus("Saved", "success");
      GitService.fetchStatus();
    })["catch"](function (err) {
      EditorStore.setStatus("Save failed: " + err.message, "error");
    })["finally"](function () {
      return setLoading(function (prev) {
        return _extends({}, prev, { save: false });
      });
    });
  };

  var handleSaveAll = function handleSaveAll() {
    var dirtyTabs = state.panes.flatMap(function (p) {
      return p.tabs;
    }).filter(function (t) {
      return t.dirty;
    });
    if (dirtyTabs.length === 0) return;

    setLoading(function (prev) {
      return _extends({}, prev, { saveAll: true });
    });
    EditorStore.setStatus("Saving " + dirtyTabs.length + " files...", "info");
    var promises = dirtyTabs.map(function (tab) {
      return FileService.saveFile(tab.path, tab.content);
    });
    Promise.all(promises).then(function () {
      var newPanes = EditorStore.getState().panes.map(function (p) {
        return _extends({}, p, { tabs: p.tabs.map(function (t) {
            return _extends({}, t, { dirty: false, cleanContent: t.content });
          })
        });
      });
      EditorStore.setState({ panes: newPanes });
      EditorStore.setStatus("All files saved", "success");
      GitService.fetchStatus();
    })["catch"](function (err) {
      EditorStore.setStatus("Failed to save some files", "error");
    })["finally"](function () {
      return setLoading(function (prev) {
        return _extends({}, prev, { saveAll: false });
      });
    });
  };

  var handleTabDragStart = function handleTabDragStart(sourcePaneId, tabId) {
    var pane2 = EditorStore.getState().panes.find(function (p) {
      return p.id === 2;
    });
    if (!pane2 || pane2.tabs.length === 0) {
      setPane1Width(50);
    }
    setDraggedTab({ sourcePaneId: sourcePaneId, tabId: tabId });
  };

  var clearDragState = function clearDragState() {
    setDraggedTab(null);
    setDragOverPaneId(null);
  };

  var moveDraggedTabToPane = function moveDraggedTabToPane(targetPaneId) {
    if (!draggedTab) return;
    TabManager.moveTabToPane(draggedTab.sourcePaneId, targetPaneId, draggedTab.tabId);
    clearDragState();
  };

  var handleFormat = function handleFormat() {
    if (!activeTab) return;

    var isRubyLang = activeTab.path.endsWith('.rb') || activeTab.path.endsWith('.gemspec') || activeTab.path.endsWith("Rakefile") || activeTab.path.endsWith("Gemfile");

    if (isRubyLang && !rubocopAvailable) {
      EditorStore.setStatus("RuboCop is not available for this workspace.", "warning");
      return;
    }

    if (activeTab.dirty) handleSave(focusedPane.id, activeTab); // save first

    if (isRubyLang) {
      setLoading(function (prev) {
        return _extends({}, prev, { format: true });
      });
      EditorStore.setStatus("Formatting...", "info");
      FileService.formatFile(activeTab.path).then(function (res) {
        if (res.content) {
          // Update content without marking dirty
          var newPanes = EditorStore.getState().panes.map(function (p) {
            if (p.id === focusedPane.id) return _extends({}, p, { tabs: p.tabs.map(function (t) {
                return t.id === activeTab.id ? _extends({}, t, { content: res.content, dirty: false }) : t;
              }) });
            return p;
          });
          EditorStore.setState({ panes: newPanes });
        }
        EditorStore.setStatus("Formatted successfully", "success");
        setMarkers(function (prev) {
          return _extends({}, prev, _defineProperty({}, activeTab.id, []));
        }); // clear lint markers
        GitService.fetchStatus();
      })["catch"](function (err) {
        return EditorStore.setStatus("Format failed: " + err.message, "error");
      })["finally"](function () {
        return setLoading(function (prev) {
          return _extends({}, prev, { format: false });
        });
      });
      return;
    }

    // Attempt Prettier Formatting
    var ext = activeTab.path.split('.').pop().toLowerCase();
    var formatMap = {
      'js': 'babel', 'jsx': 'babel',
      'json': 'json',
      'css': 'css', 'scss': 'scss',
      'html': 'html', 'md': 'markdown'
    };
    var parserName = formatMap[ext];

    if (parserName && window.prettier && window.prettierPlugins) {
      setLoading(function (prev) {
        return _extends({}, prev, { format: true });
      });
      EditorStore.setStatus("Formatting with Prettier...", "info");
      window.prettier.format(activeTab.content, {
        parser: parserName,
        plugins: Object.values(window.prettierPlugins),
        tabWidth: 4,
        useTabs: false
      }).then(function (formatted) {
        var newPanes = EditorStore.getState().panes.map(function (p) {
          if (p.id === focusedPane.id) return _extends({}, p, { tabs: p.tabs.map(function (t) {
              return t.id === activeTab.id ? _extends({}, t, { content: formatted, dirty: true }) : t;
            }) });
          return p;
        });
        EditorStore.setState({ panes: newPanes });
        EditorStore.setStatus("Formatted (Unsaved)", "success");
        GitService.fetchStatus();
      })["catch"](function (err) {
        EditorStore.setStatus("Prettier Formatter failed: " + err.message, "error");
      })["finally"](function () {
        setLoading(function (prev) {
          return _extends({}, prev, { format: false });
        });
      });
    }
  };

  var _debouncedSearch = useRef(window._.debounce(function (q) {
    if (!q.trim()) {
      EditorStore.setState({ searchResults: [] });
      return;
    }
    EditorStore.setStatus("Searching project...", "info");
    SearchService.projectSearch(q).then(function (res) {
      EditorStore.setStatus("Found " + res.length + " results", "success");
    });
  }, 400)).current;

  var handleSearchChange = function handleSearchChange(e) {
    var val = e.target.value;
    setSearchQuery(val);
    _debouncedSearch(val);
  };

  var execSearch = function execSearch(e) {
    e.preventDefault();
    _debouncedSearch(searchQuery);
  };

  var toggleGitPanel = function toggleGitPanel() {
    setShowGitPanel(function (prev) {
      var next = !prev;
      if (next) GitService.fetchInfo();
      return next;
    });
  };

  var handleToggleSection = function handleToggleSection(sectionKey, isCollapsed) {
    setCollapsedSections(function (prev) {
      return _extends({}, prev, _defineProperty({}, sectionKey, isCollapsed));
    });
  };

  var handleCollapseAll = function handleCollapseAll() {
    return setExpandedDirs({});
  };

  var openContextMenu = function openContextMenu(e, node) {
    setContextMenu({ x: e.clientX, y: e.clientY, node: node });
    setSelectedTreeNode(node);
  };

  var closeContextMenu = function closeContextMenu() {
    return setContextMenu(null);
  };

  var handleContextMenuAction = function handleContextMenuAction(action) {
    var node = contextMenu && contextMenu.node;
    closeContextMenu();
    if (action === 'open' && node) {
      handleHardOpenFile(node.path, node.name);return;
    }
    if (action === 'newFile') {
      handleCreateFile(node);return;
    }
    if (action === 'newFolder') {
      handleCreateDir(node);return;
    }
    if (action === 'rename') {
      handleRenamePath(node);return;
    }
    if (action === 'delete') {
      handleDeletePath(node);return;
    }
    if (action === 'copyPath' && node) {
      if (navigator.clipboard) {
        navigator.clipboard.writeText(node.path)["catch"](function () {});
      }
      EditorStore.setStatus('Copied: ' + node.path, 'info');
    }
  };

  var startPaneResize = function startPaneResize(e) {
    e.preventDefault();
    resizeSessionRef.current = { mode: 'pane' };
    setActiveResizeMode('pane');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  var startSidebarResize = function startSidebarResize(e) {
    e.preventDefault();
    resizeSessionRef.current = { mode: 'sidebar' };
    setActiveResizeMode('sidebar');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  var openFileFromGitPanel = function openFileFromGitPanel(path, name) {
    if (!path) return;
    handleSelectFile(path, name || path.split('/').pop());
  };

  var pathMatchesNodeOrDescendant = function pathMatchesNodeOrDescendant(value, targetPath) {
    if (!value || !targetPath) return false;
    return value === targetPath || value.indexOf(targetPath + '/') === 0 || value.indexOf(targetPath + '::preview') === 0;
  };

  var rewritePathAfterRename = function rewritePathAfterRename(value, oldPath, newPath) {
    if (!value || !oldPath || !newPath) return value;
    if (value === oldPath) return newPath;
    if (value === oldPath + '::preview') return newPath + '::preview';
    if (value.indexOf(oldPath + '/') === 0) return newPath + value.slice(oldPath.length);
    return value;
  };

  var applyRenameToOpenTabs = function applyRenameToOpenTabs(oldPath, newPath) {
    var currentState = EditorStore.getState();
    var newPanes = currentState.panes.map(function (pane) {
      var renamedTabs = pane.tabs.map(function (tab) {
        var nextPath = rewritePathAfterRename(tab.path, oldPath, newPath);
        var nextPreviewFor = rewritePathAfterRename(tab.previewFor, oldPath, newPath);
        if (nextPath === tab.path && nextPreviewFor === tab.previewFor) return tab;

        var defaultName = nextPath.split('/').pop();
        var previewSourceName = nextPreviewFor ? nextPreviewFor.split('/').pop() : defaultName;
        return _extends({}, tab, {
          id: nextPath,
          path: nextPath,
          name: tab.isPreview ? previewSourceName + '-preview' : defaultName,
          previewFor: nextPreviewFor
        });
      });

      return _extends({}, pane, {
        tabs: renamedTabs,
        activeTabId: rewritePathAfterRename(pane.activeTabId, oldPath, newPath)
      });
    });

    EditorStore.setState({
      panes: newPanes,
      activeTabId: rewritePathAfterRename(currentState.activeTabId, oldPath, newPath)
    });
  };

  var removeDeletedPathFromOpenTabs = function removeDeletedPathFromOpenTabs(targetPath) {
    var currentState = EditorStore.getState();
    var removedTabIds = [];

    var newPanes = currentState.panes.map(function (pane) {
      var keptTabs = pane.tabs.filter(function (tab) {
        var removeTab = pathMatchesNodeOrDescendant(tab.path, targetPath) || pathMatchesNodeOrDescendant(tab.previewFor, targetPath);
        if (removeTab) {
          removedTabIds.push(tab.id);
        }
        return !removeTab;
      });

      var nextActiveTabId = pane.activeTabId;
      var activeStillExists = keptTabs.some(function (tab) {
        return tab.id === nextActiveTabId;
      });
      if (!activeStillExists) {
        nextActiveTabId = keptTabs.length ? keptTabs[keptTabs.length - 1].id : null;
      }

      return _extends({}, pane, {
        tabs: keptTabs,
        activeTabId: nextActiveTabId
      });
    });

    var nextFocusedPaneId = currentState.focusedPaneId;
    var focusedPane = newPanes.find(function (pane) {
      return pane.id === nextFocusedPaneId;
    });
    if (!focusedPane || focusedPane.tabs.length === 0) {
      var paneWithTabs = newPanes.find(function (pane) {
        return pane.tabs.length > 0;
      });
      nextFocusedPaneId = paneWithTabs ? paneWithTabs.id : 1;
    }

    var activePane = newPanes.find(function (pane) {
      return pane.id === nextFocusedPaneId;
    });
    EditorStore.setState({
      panes: newPanes,
      focusedPaneId: nextFocusedPaneId,
      activeTabId: activePane ? activePane.activeTabId : null
    });

    if (removedTabIds.length) {
      setMarkers(function (prev) {
        var next = _extends({}, prev);
        removedTabIds.forEach(function (tabId) {
          return delete next[tabId];
        });
        return next;
      });
    }
  };

  var handleCreateFile = function handleCreateFile(targetNode) {
    var node = targetNode !== undefined ? targetNode : selectedTreeNode;
    var baseDir = node ? node.type === 'folder' ? node.path : parentDir(node.path) : '';
    // Ensure the target folder is expanded so the inline row is visible
    if (baseDir) setExpandedDirs(function (prev) {
      return Object.assign({}, prev, _defineProperty({}, baseDir, true));
    });
    setPendingRename(null);
    setPendingCreate({ type: 'file', parentPath: baseDir });
  };

  var handleCreateDir = function handleCreateDir(targetNode) {
    var node = targetNode !== undefined ? targetNode : selectedTreeNode;
    var baseDir = node ? node.type === 'folder' ? node.path : parentDir(node.path) : '';
    if (baseDir) setExpandedDirs(function (prev) {
      return Object.assign({}, prev, _defineProperty({}, baseDir, true));
    });
    setPendingRename(null);
    setPendingCreate({ type: 'folder', parentPath: baseDir });
  };

  var handleCreateConfirm = function handleCreateConfirm(name) {
    if (!pendingCreate || !name) return;
    var type = pendingCreate.type;
    var parentPath = pendingCreate.parentPath;

    var path = normalizeRelativePath(parentPath ? parentPath + '/' + name : name);
    setPendingCreate(null);

    if (type === 'file') {
      setLoading(function (prev) {
        return _extends({}, prev, { createFile: true });
      });
      FileService.createFile(path, '').then(function (res) {
        var createdPath = res && res.path || path;
        var createdName = createdPath.split('/').pop();
        setSelectedTreeNode({ path: createdPath, name: createdName, type: 'file' });
        EditorStore.setStatus('Created file: ' + createdName, 'success');
        return refreshProjectTree().then(function () {
          handleSelectFile(createdPath, createdName);
          GitService.fetchStatus();
        });
      })["catch"](function (err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Create file failed: ' + message, 'error');
      })["finally"](function () {
        return setLoading(function (prev) {
          return _extends({}, prev, { createFile: false });
        });
      });
    } else {
      setLoading(function (prev) {
        return _extends({}, prev, { createDir: true });
      });
      FileService.createDir(path).then(function (res) {
        var createdPath = res && res.path || path;
        setSelectedTreeNode({ path: createdPath, name: createdPath.split('/').pop(), type: 'folder' });
        EditorStore.setStatus('Created folder: ' + createdPath, 'success');
        return refreshProjectTree().then(function () {
          return GitService.fetchStatus();
        });
      })["catch"](function (err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Create folder failed: ' + message, 'error');
      })["finally"](function () {
        return setLoading(function (prev) {
          return _extends({}, prev, { createDir: false });
        });
      });
    }
  };

  var handleCreateCancel = function handleCreateCancel() {
    return setPendingCreate(null);
  };

  var handleRenamePath = function handleRenamePath(targetNode) {
    var node = targetNode !== undefined ? targetNode : selectedTreeNode;
    if (!node || !node.path) {
      EditorStore.setStatus('Select a file or folder to rename first.', 'warning');
      return;
    }

    var itemPath = node.path;

    // Expand all ancestor folders so the rename inline input is always visible
    var parts = itemPath.split('/');
    if (parts.length > 1) {
      var ancestors = {};
      for (var i = 1; i < parts.length; i++) {
        ancestors[parts.slice(0, i).join('/')] = true;
      }
      setExpandedDirs(function (prev) {
        return Object.assign({}, prev, ancestors);
      });
    }

    setPendingCreate(null);
    setPendingRename({
      path: itemPath,
      parentPath: parentDir(itemPath),
      type: node.type,
      currentName: node.name || itemPath.split('/').pop()
    });
  };

  var handleRenameConfirm = function handleRenameConfirm(name, renameTarget) {
    var target = renameTarget || pendingRename;
    if (!target || !name) return;

    var oldPath = target.path;
    var currentName = target.currentName || oldPath.split('/').pop();
    var nextName = name.trim();
    setPendingRename(null);

    if (!nextName || nextName === currentName) return;

    var nextPath = normalizeRelativePath(parentDir(oldPath) ? parentDir(oldPath) + '/' + nextName : nextName);
    if (!nextPath || nextPath === oldPath) return;

    setLoading(function (prev) {
      return _extends({}, prev, { renamePath: true });
    });
    FileService.renamePath(oldPath, nextPath).then(function (res) {
      var renamedPath = res && res.path || nextPath;
      applyRenameToOpenTabs(oldPath, renamedPath);
      setSelectedTreeNode(function (prev) {
        return prev ? _extends({}, prev, { path: renamedPath, name: renamedPath.split('/').pop() }) : prev;
      });
      EditorStore.setStatus('Renamed to: ' + renamedPath, 'success');
      return refreshProjectTree().then(function () {
        GitService.fetchStatus();
      });
    })["catch"](function (err) {
      var message = err && err.response && err.response.data && err.response.data.error || err.message;
      EditorStore.setStatus('Rename failed: ' + message, 'error');
    })["finally"](function () {
      setLoading(function (prev) {
        return _extends({}, prev, { renamePath: false });
      });
    });
  };

  var handleRenameCancel = function handleRenameCancel() {
    return setPendingRename(null);
  };

  var handleDeletePath = function handleDeletePath(targetNode) {
    var node = targetNode !== undefined ? targetNode : selectedTreeNode;
    if (!node || !node.path) {
      EditorStore.setStatus('Select a file or folder to delete first.', 'warning');
      return;
    }

    var targetPath = node.path;
    var confirmed = window.confirm('Delete ' + targetPath + '? This cannot be undone.');
    if (!confirmed) return;

    setLoading(function (prev) {
      return _extends({}, prev, { deletePath: true });
    });
    FileService.deletePath(targetPath).then(function () {
      removeDeletedPathFromOpenTabs(targetPath);
      setSelectedTreeNode(null);
      EditorStore.setStatus('Deleted: ' + targetPath, 'success');
      return refreshProjectTree().then(function () {
        GitService.fetchStatus();
      });
    })["catch"](function (err) {
      var message = err && err.response && err.response.data && err.response.data.error || err.message;
      EditorStore.setStatus('Delete failed: ' + message, 'error');
    })["finally"](function () {
      setLoading(function (prev) {
        return _extends({}, prev, { deletePath: false });
      });
    });
  };

  var projectSectionTitle = deriveProjectRootName().toUpperCase();
  var selectedTreePath = selectedTreeNode ? selectedTreeNode.path : null;
  var isRuby = activeTab && isRubyPath(activeTab.path);
  var isHaml = activeTab && activeTab.path.endsWith('.haml');
  var supportedPrettierExts = ['js', 'jsx', 'json', 'css', 'scss', 'html', 'md'];
  var isPrettierable = activeTab && supportedPrettierExts.includes(activeTab.path.split('.').pop().toLowerCase());
  var canLintAndFormat = activeTab && (isPrettierable || isRuby && rubocopAvailable || isHaml && hamlLintAvailable);
  var hasGitBranch = !!(state.gitBranch && state.gitBranch.trim());

  return React.createElement(
    "div",
    { className: "ide-shell" },
    React.createElement(
      "div",
      { className: "ide-titlebar" },
      React.createElement("i", { className: "fas fa-layer-group ide-titlebar-icon" }),
      React.createElement(
        "div",
        { className: "ide-titlebar-title" },
        "Mini Browser Editor — ",
        window.location.host
      ),
      React.createElement(
        "div",
        { style: { marginLeft: "auto", display: "flex", gap: "4px", height: "100%", alignItems: "center" } },
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: function () {
              return activeTab && handleSave(focusedPane.id, activeTab);
            }, disabled: loading.save || !activeTab || !activeTab.dirty },
          React.createElement("i", { className: loading.save ? "fas fa-spinner fa-spin" : "fas fa-save" }),
          " Save ",
          activeTab && activeTab.dirty ? "●" : ""
        ),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleSaveAll, disabled: loading.saveAll || !state.panes.flatMap(function (p) {
              return p.tabs;
            }).some(function (t) {
              return t.dirty;
            }) },
          React.createElement(
            "i",
            { className: loading.saveAll ? "fas fa-spinner fa-spin" : "fas fa-save", style: loading.saveAll ? {} : { position: 'relative' } },
            !loading.saveAll && React.createElement("i", { className: "fas fa-save", style: { position: 'absolute', top: '-2px', left: '3px', fontSize: '9px', opacity: 0.8 } })
          ),
          " Save All"
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleFormat, disabled: loading.format || !canLintAndFormat },
          React.createElement("i", { className: loading.format ? "fas fa-spinner fa-spin" : "fas fa-magic" }),
          " Format"
        ),
        hasGitBranch && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            { type: "button", className: "statusbar-btn titlebar-git-btn", onClick: toggleGitPanel },
            React.createElement("i", { className: "fas fa-code-branch" }),
            " Git"
          )
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { type: "button", className: "statusbar-btn", onClick: function () { return setShowHelp(true); }, title: "Keyboard shortcuts & help" },
          React.createElement("i", { className: "fas fa-keyboard" }),
          " Help"
        )
      )
    ),
    showHelp && React.createElement(ShortcutHelp, { onClose: function () { return setShowHelp(false); } }),
    React.createElement(
      "div",
      { className: "ide-body", id: "ide-body-container" },
      React.createElement(
        "div",
        { className: "ide-sidebar", style: { width: sidebarWidth + "px" } },
        React.createElement(
          "div",
          { className: "ide-sidebar-tabs" },
          React.createElement(
            "button",
            { type: "button", className: "ide-sidebar-tab " + (activeSidebarTab === 'explorer' ? 'active' : ''), onClick: function () {
                return setActiveSidebarTab('explorer');
              } },
            "EXPLORER"
          ),
          React.createElement(
            "button",
            { type: "button", className: "ide-sidebar-tab " + (activeSidebarTab === 'search' ? 'active' : ''), onClick: function () {
                return setActiveSidebarTab('search');
              } },
            "SEARCH"
          )
        ),
        activeSidebarTab === 'explorer' && React.createElement(
          "div",
          { className: "ide-sidebar-content" },
          state.panes.flatMap(function (p) {
            return p.tabs;
          }).length > 0 && React.createElement(
            CollapsibleSection,
            {
              title: "OPEN EDITORS",
              isCollapsed: collapsedSections.openEditors,
              onToggle: function (isCollapsed) {
                return handleToggleSection('openEditors', isCollapsed);
              },
              actions: React.createElement(
                SectionActionGroup,
                { ariaLabel: "Open editor actions" },
                React.createElement(SidebarActionButton, {
                  title: "Close all editors",
                  ariaLabel: "Close all open editors",
                  iconClass: "far fa-window-close",
                  onClick: handleCloseAllEditors
                })
              )
            },
            React.createElement(
              "div",
              { style: { marginBottom: "12px" } },
              state.panes.map(function (pane) {
                if (pane.tabs.length === 0) return null;
                var isPane2 = pane.id === 2;
                return React.createElement(
                  "div",
                  {
                    key: pane.id,
                    className: "open-editors-group",
                    style: { marginBottom: pane.id === 1 && state.panes[1].tabs.length > 0 ? "10px" : "0" }
                  },
                  React.createElement(
                    "div",
                    { className: "ide-sidebar-header open-editors-group-header" },
                    React.createElement(
                      "span",
                      { className: "open-editors-group-title" },
                      "GROUP ",
                      pane.id
                    ),
                    React.createElement(
                      SectionActionGroup,
                      { ariaLabel: "Group " + pane.id + " actions", className: "collapsible-actions open-editors-group-actions" },
                      React.createElement(SidebarActionButton, {
                        title: "Close all editors in Group " + pane.id,
                        ariaLabel: "Close all editors in Group " + pane.id,
                        iconClass: "far fa-window-close",
                        onClick: function (e) {
                          e.stopPropagation();handleCloseEditorsInGroup(pane.id);
                        }
                      })
                    )
                  ),
                  React.createElement(
                    "div",
                    { className: "file-tree" },
                    pane.tabs.map(function (tab) {
                      return React.createElement(
                        "div",
                        {
                          key: tab.id,
                          className: "tree-item " + (pane.activeTabId === tab.id && state.focusedPaneId === pane.id ? "active" : ""),
                          onClick: function () {
                            TabManager.focusPane(pane.id);TabManager.switchTab(pane.id, tab.id);
                          }
                        },
                        React.createElement("i", { className: "tree-item-icon " + (window.getFileIcon ? window.getFileIcon(tab.name) : 'far fa-file-code') + " tree-file-icon" }),
                        React.createElement(
                          "div",
                          { className: "tree-item-name", style: { display: 'flex', alignItems: 'center' } },
                          React.createElement(
                            "span",
                            { style: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } },
                            tab.name
                          ),
                          tab.dirty && React.createElement("i", { className: "fas fa-circle", style: { fontSize: '5px', color: '#e3d286', marginLeft: '6px', marginTop: '1px' } })
                        ),
                        React.createElement(
                          "div",
                          { className: "tab-actions", style: { display: 'flex', position: 'absolute', right: '4px', top: 0, height: '100%', alignItems: 'center' } },
                          React.createElement(
                            "div",
                            { className: "tab-split", onClick: function (e) {
                                e.stopPropagation();TabManager.moveTabToPane(pane.id, pane.id === 1 ? 2 : 1, tab.id);
                              }, style: { padding: '0 4px', cursor: 'pointer', opacity: 0.6 }, title: "Move to Group " + (pane.id === 1 ? 2 : 1) },
                            React.createElement("i", { className: isPane2 ? "fas fa-chevron-left" : "fas fa-chevron-right" })
                          ),
                          React.createElement(
                            "div",
                            { className: "tab-close", onClick: function (e) {
                                e.stopPropagation();requestCloseTab(pane.id, tab.id);
                              }, style: { padding: '0 4px', cursor: 'pointer', opacity: 0.6 } },
                            React.createElement("i", { className: "fas fa-times" })
                          )
                        )
                      );
                    })
                  )
                );
              })
            )
          ),
          React.createElement(
            CollapsibleSection,
            {
              title: projectSectionTitle,
              isCollapsed: collapsedSections.projects,
              onToggle: function (isCollapsed) {
                return handleToggleSection('projects', isCollapsed);
              },
              actions: React.createElement(
                SectionActionGroup,
                { ariaLabel: "Project actions" },
                React.createElement(SidebarActionButton, {
                  title: "Collapse all folders",
                  iconClass: "fas fa-compress-alt",
                  onClick: handleCollapseAll
                }),
                React.createElement(SidebarActionButton, {
                  title: "New file",
                  iconClass: loading.createFile ? 'fas fa-spinner fa-spin' : 'far fa-file',
                  onClick: function () {
                    return handleCreateFile();
                  },
                  disabled: !!loading.createFile
                }),
                React.createElement(SidebarActionButton, {
                  title: "New folder",
                  iconClass: loading.createDir ? 'fas fa-spinner fa-spin' : 'far fa-folder',
                  onClick: function () {
                    return handleCreateDir();
                  },
                  disabled: !!loading.createDir
                }),
                React.createElement(SidebarActionButton, {
                  title: "Rename selected",
                  iconClass: loading.renamePath ? 'fas fa-spinner fa-spin' : 'fas fa-pen',
                  onClick: function () {
                    return handleRenamePath();
                  },
                  disabled: !!loading.renamePath || !selectedTreePath
                }),
                React.createElement(SidebarActionButton, {
                  title: "Delete selected",
                  iconClass: loading.deletePath ? 'fas fa-spinner fa-spin' : 'far fa-trash-alt',
                  onClick: function () {
                    return handleDeletePath();
                  },
                  disabled: !!loading.deletePath || !selectedTreePath,
                  danger: true
                })
              )
            },
            React.createElement(FileTree, {
              items: treeData,
              onSelect: handleSoftOpenFile,
              activePath: activeTab && activeTab.path,
              selectedPath: selectedTreePath,
              onNodeSelect: setSelectedTreeNode,
              gitFiles: state.gitFiles,
              expandedDirs: expandedDirs,
              onExpandedDirsChange: setExpandedDirs,
              onFileDoubleClick: handleHardOpenFile,
              onContextMenu: openContextMenu,
              pendingCreate: pendingCreate,
              onCreateConfirm: handleCreateConfirm,
              onCreateCancel: handleCreateCancel,
              pendingRename: pendingRename,
              onRenameConfirm: handleRenameConfirm,
              onRenameCancel: handleRenameCancel
            })
          )
        ),
        activeSidebarTab === 'search' && React.createElement(
          "form",
          { className: "search-panel", onSubmit: execSearch },
          React.createElement(
            "div",
            { className: "search-input-wrap" },
            React.createElement("input", {
              className: "search-input",
              placeholder: "Find in files...",
              value: searchQuery,
              onChange: handleSearchChange
            }),
            React.createElement(
              "button",
              { type: "submit", className: "search-btn" },
              React.createElement("i", { className: "fas fa-search" })
            )
          ),
          React.createElement(
            "div",
            { className: "search-results" },
            searchQuery && state.searchResults.length > 0 && React.createElement(
              "div",
              { className: "search-results-meta" },
              state.searchResults.length,
              " result" + (state.searchResults.length !== 1 ? "s" : ""),
              state.searchResults.length >= 30 && React.createElement(
                "span",
                { className: "search-results-capped" },
                " — refine query to see more"
              )
            ),
            searchQuery && state.searchResults.length === 0 && React.createElement(
              "div",
              { className: "search-results-empty" },
              "No results"
            ),
            state.searchResults.map(function (res, i) {
              return React.createElement(
                "div",
                { key: i, className: "search-result-item", onClick: function () {
                    return handleSelectFile(res.file, res.file.split('/').pop(), res.line);
                  } },
                React.createElement(
                  "div",
                  { className: "search-result-file" },
                  res.file,
                  " ",
                  React.createElement(
                    "span",
                    { className: "search-result-line-num" },
                    ":",
                    res.line
                  )
                ),
                React.createElement(
                  "div",
                  { className: "search-result-text" },
                  res.text
                )
              );
            })
          )
        )
      ),
      React.createElement("div", {
        className: "panel-divider sidebar-divider " + (activeResizeMode === 'sidebar' ? 'active' : ''),
        onMouseDown: startSidebarResize,
        role: "separator",
        "aria-orientation": "vertical",
        "aria-label": "Resize explorer panel"
      }),
      React.createElement(
        "div",
        {
          id: "ide-main-split-container",
          className: "ide-main",
          style: { display: 'flex', flexDirection: 'row', width: '100%', height: '100%', cursor: activeResizeMode === 'pane' ? 'col-resize' : 'default', userSelect: activeResizeMode ? 'none' : 'auto' },
          onDragOverCapture: function (e) {
            if (!draggedTab) return;
            e.preventDefault();

            var rect = e.currentTarget.getBoundingClientRect();
            var splitAtX = rect.left + rect.width * (pane1Width / 100);
            var hoverPaneId = e.clientX >= splitAtX ? 2 : 1;
            var nextDropPane = hoverPaneId === draggedTab.sourcePaneId ? null : hoverPaneId;

            e.dataTransfer.dropEffect = nextDropPane ? 'move' : 'none';
            if (dragOverPaneId !== nextDropPane) setDragOverPaneId(nextDropPane);
          },
          onDropCapture: function (e) {
            if (!draggedTab) return;
            e.preventDefault();

            var rect = e.currentTarget.getBoundingClientRect();
            var splitAtX = rect.left + rect.width * (pane1Width / 100);
            var targetPaneId = e.clientX >= splitAtX ? 2 : 1;

            if (targetPaneId !== draggedTab.sourcePaneId) {
              moveDraggedTabToPane(targetPaneId);
            } else {
              clearDragState();
            }
          }
        },
        state.panes.map(function (pane, idx) {
          if (pane.id === 2 && pane.tabs.length === 0 && !draggedTab) return null; // Show pane 2 while dragging to allow drop-to-split

          // Dynamic width distribution
          var isSplit = state.panes[1].tabs.length > 0 || !!draggedTab;
          var flexBasis = '100%';
          if (isSplit) flexBasis = pane.id === 1 ? pane1Width + "%" : 100 - pane1Width + "%";

          var isFocused = state.focusedPaneId === pane.id;
          var pActiveTab = pane.tabs.find(function (t) {
            return t.id === pane.activeTabId;
          });
          var canAcceptDrop = !!draggedTab && draggedTab.sourcePaneId !== pane.id;
          var isDropTarget = canAcceptDrop && dragOverPaneId === pane.id;

          return React.createElement(
            React.Fragment,
            { key: pane.id },
            idx === 1 && isSplit && React.createElement("div", {
              className: "panel-divider pane-divider " + (activeResizeMode === 'pane' ? 'active' : ''),
              onMouseDown: startPaneResize
            }),
            React.createElement(
              "div",
              {
                className: "ide-pane " + (isFocused ? 'focused' : '') + " " + (isDropTarget ? 'drop-target' : ''),
                style: { flexBasis: flexBasis, flexShrink: 0, flexGrow: 0, display: 'flex', flexDirection: 'column', minWidth: 0 },
                onClickCapture: function () {
                  return TabManager.focusPane(pane.id);
                },
                onDragOver: function (e) {
                  if (!canAcceptDrop) return;
                  e.preventDefault();
                  e.dataTransfer.dropEffect = 'move';
                  if (dragOverPaneId !== pane.id) setDragOverPaneId(pane.id);
                },
                onDragEnter: function (e) {
                  if (!canAcceptDrop) return;
                  e.preventDefault();
                  if (dragOverPaneId !== pane.id) setDragOverPaneId(pane.id);
                },
                onDragLeave: function (e) {
                  if (dragOverPaneId !== pane.id) return;
                  if (!e.currentTarget.contains(e.relatedTarget)) {
                    setDragOverPaneId(null);
                  }
                },
                onDrop: function (e) {
                  if (!canAcceptDrop) return;
                  e.preventDefault();
                  moveDraggedTabToPane(pane.id);
                }
              },
              pane.tabs.length > 0 ? React.createElement(
                React.Fragment,
                null,
                React.createElement(TabBar, {
                  tabs: pane.tabs,
                  activeId: pane.activeTabId,
                  onSelect: function (id) {
                    return TabManager.switchTab(pane.id, id);
                  },
                  onClose: function (id) {
                    return requestCloseTab(pane.id, id);
                  },
                  onTabDragStart: function (id) {
                    return handleTabDragStart(pane.id, id);
                  },
                  onTabDragEnd: clearDragState,
                  onHardenTab: function (tabId) {
                    return TabManager.hardenTab(pane.id, tabId);
                  }
                }),
                React.createElement(
                  "div",
                  { style: { flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', visibility: activeResizeMode === 'pane' ? 'hidden' : 'visible' } },
                  React.createElement(EditorPanel, {
                    key: pActiveTab.id,
                    tab: pActiveTab,
                    paneId: pane.id,
                    markers: markers[pActiveTab.id] || [],
                    onContentChange: function (val) {
                      var st = EditorStore.getState();
                      var cp = st.panes.find(function(p) { return p.id === pane.id; });
                      var ct = cp && cp.tabs.find(function(t) { return t.id === pActiveTab.id; });
                      var cleanNorm = ((ct && ct.cleanContent) || '').replace(/\r\n/g, '\n');
                      var valNorm = val.replace(/\r\n/g, '\n');
                      if (valNorm === cleanNorm) {
                        TabManager.markClean(pane.id, pActiveTab.id, val);
                      } else {
                        TabManager.markDirty(pane.id, pActiveTab.id, val);
                      }
                    }
                  })
                )
              ) : React.createElement(
                "div",
                { className: "tab-welcome" },
                canAcceptDrop ? React.createElement(
                  React.Fragment,
                  null,
                  React.createElement("i", { className: "fas fa-columns" }),
                  React.createElement(
                    "h2",
                    null,
                    "Drop Tab Here"
                  ),
                  React.createElement(
                    "p",
                    null,
                    "Release to move this file into Group ",
                    pane.id,
                    "."
                  )
                ) : pane.id === 1 ? React.createElement(
                  React.Fragment,
                  null,
                  React.createElement("i", { className: "fas fa-code" }),
                  React.createElement("h2", null, "Mini Browser Editor"),
                  React.createElement("p", { className: "welcome-intro" }, "Open a file from the explorer to start editing."),
                  React.createElement(
                    "div",
                    { className: "welcome-shortcuts" },
                    React.createElement(
                      "div",
                      { className: "welcome-section" },
                      React.createElement("h3", null, "Keyboard shortcuts"),
                      React.createElement(
                        "table",
                        { className: "shortcut-table" },
                        React.createElement(
                          "tbody",
                          null,
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+P")),
                            React.createElement("td", null, "Quick-open any file by name")
                          ),
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+S")),
                            React.createElement("td", null, "Save the active file")
                          ),
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+Z\u00a0/\u00a0Ctrl+Y")),
                            React.createElement("td", null, "Undo / Redo")
                          )
                        )
                      )
                    ),
                    React.createElement(
                      "div",
                      { className: "welcome-section" },
                      React.createElement("h3", null, "Sidebar panels"),
                      React.createElement(
                        "ul",
                        { className: "welcome-tips" },
                        React.createElement("li", null, React.createElement("i", { className: "fas fa-folder-open" }), "\u00a0Explorer \u2014 browse and manage project files"),
                        React.createElement("li", null, React.createElement("i", { className: "fas fa-search" }), "\u00a0Search \u2014 full-text search across all files"),
                        React.createElement("li", null, React.createElement("i", { className: "fas fa-code-branch" }), "\u00a0Git panel \u2014 branch status and changed files (top-right icon)")
                      )
                    ),
                    React.createElement(
                      "div",
                      { className: "welcome-section" },
                      React.createElement("h3", null, "Editor tips"),
                      React.createElement(
                        "ul",
                        { className: "welcome-tips" },
                        React.createElement("li", null, "Drag any tab to the right half to open a split pane"),
                        React.createElement("li", null, "Right-click a file in the explorer to rename or delete it"),
                        React.createElement("li", null, "Ruby files auto-lint with RuboCop when installed"),
                        React.createElement("li", null, "JS, CSS, HTML and Markdown auto-format with Prettier")
                      )
                    )
                  )
                ) : null
              )
            )
          );
        })
      ),
      showGitPanel && React.createElement(GitPanel, {
        gitInfo: state.gitInfo,
        error: state.gitInfoError,
        onRefresh: function () {
          return GitService.fetchInfo();
        },
        onClose: function () {
          return setShowGitPanel(false);
        },
        onOpenFile: openFileFromGitPanel
      })
    ),
    React.createElement(
      "div",
      { className: "ide-statusbar" },
      hasGitBranch && React.createElement(
        "div",
        { className: "statusbar-branch" },
        React.createElement("i", { className: "fas fa-code-branch" }),
        " ",
        state.gitBranch
      ),
      !serverOnline && React.createElement(
        "div",
        { className: "statusbar-offline" },
        React.createElement("i", { className: "fas fa-exclamation-triangle" }),
        " Server offline"
      ),
      React.createElement(
        "div",
        { className: "statusbar-msg " + state.statusMessage.kind },
        state.statusMessage.text
      )
    ),
    quickOpen && React.createElement(QuickOpenDialog, { onSelect: handleSelectFile, onClose: function () {
        return setQuickOpen(false);
      } }),
    contextMenu && React.createElement(
      React.Fragment,
      null,
      React.createElement("div", {
        style: { position: 'fixed', inset: 0, zIndex: 9998 },
        onClick: closeContextMenu,
        onContextMenu: function (e) {
          e.preventDefault();closeContextMenu();
        }
      }),
      React.createElement(
        "div",
        {
          className: "context-menu",
          style: { left: contextMenu.x, top: contextMenu.y },
          onClick: function (e) {
            return e.stopPropagation();
          }
        },
        contextMenu.node && contextMenu.node.type === 'file' && React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('open');
            } },
          React.createElement("i", { className: "far fa-file-code context-menu-icon" }),
          " Open"
        ),
        React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('newFile');
            } },
          React.createElement("i", { className: "far fa-file context-menu-icon" }),
          " New File"
        ),
        React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('newFolder');
            } },
          React.createElement("i", { className: "far fa-folder context-menu-icon" }),
          " New Folder"
        ),
        React.createElement("div", { className: "context-menu-divider" }),
        React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('rename');
            } },
          React.createElement("i", { className: "fas fa-pen context-menu-icon" }),
          " Rename"
        ),
        React.createElement(
          "div",
          { className: "context-menu-item context-menu-item-danger", onClick: function () {
              return handleContextMenuAction('delete');
            } },
          React.createElement("i", { className: "far fa-trash-alt context-menu-icon" }),
          " Delete"
        ),
        React.createElement("div", { className: "context-menu-divider" }),
        React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('copyPath');
            } },
          React.createElement("i", { className: "fas fa-copy context-menu-icon" }),
          " Copy Path"
        )
      )
    ),
    closingTabId && React.createElement(
      "div",
      { className: "quick-open-overlay", style: { zIndex: 10001 } },
      React.createElement(
        "div",
        { className: "quick-open-box", style: { width: '400px', padding: '20px', background: '#252526', border: '1px solid #454545' } },
        React.createElement(
          "h3",
          { style: { marginTop: 0, fontSize: '14px', color: '#fff' } },
          "Unsaved Changes"
        ),
        React.createElement(
          "p",
          { style: { color: '#ccc', margin: '16px 0', fontSize: '13px' } },
          "Do you want to save the changes you made to ",
          React.createElement(
            "strong",
            null,
            (state.panes.flatMap(function (p) {
              return p.tabs;
            }).find(function (t) {
              return t.id === closingTabId;
            }) || {}).name
          ),
          "?"
        ),
        React.createElement(
          "p",
          { style: { color: '#888', marginBottom: '24px', fontSize: '12px' } },
          "Your changes will be lost if you don't save them."
        ),
        React.createElement(
          "div",
          { style: { display: 'flex', gap: '8px', justifyContent: 'flex-end' } },
          React.createElement(
            "button",
            {
              onClick: function () {
                return confirmCloseTab(true);
              },
              style: { padding: '6px 16px', background: '#0e639c', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' } },
            "Save"
          ),
          React.createElement(
            "button",
            {
              onClick: function () {
                return confirmCloseTab(false);
              },
              style: { padding: '6px 16px', background: 'transparent', color: '#ccc', border: '1px solid #666', borderRadius: '4px', cursor: 'pointer' } },
            "Don't Save"
          ),
          React.createElement(
            "button",
            {
              onClick: function () {
                return setClosingTabId(null);
              },
              style: { padding: '6px 16px', background: 'transparent', color: '#888', border: 'none', cursor: 'pointer' } },
            "Cancel"
          )
        )
      )
    )
  );
};

window.MbeditorApp = MbeditorApp;
/* TITLE BAR */ /* SIDEBAR */ /* EDITOR AREA */ /* STATUS BAR */ /* Right-click context menu */