"use strict";

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i["return"]) _i["return"](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError("Invalid attempt to destructure non-iterable instance"); } }; })();

var _extends = Object.assign || function (target) { for (var i = 1; i < arguments.length; i++) { var source = arguments[i]; for (var key in source) { if (Object.prototype.hasOwnProperty.call(source, key)) { target[key] = source[key]; } } } return target; };

function _defineProperty(obj, key, value) { if (key in obj) { Object.defineProperty(obj, key, { value: value, enumerable: true, configurable: true, writable: true }); } else { obj[key] = value; } return obj; }

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var SIDEBAR_MIN_WIDTH = 280;
var SIDEBAR_MAX_WIDTH = 560;
var EDITOR_MIN_WIDTH = 320;
var GIT_PANEL_MIN_WIDTH = 280;
var PANE_MIN_WIDTH_PERCENT = 20;
var PANE_MAX_WIDTH_PERCENT = 80;
var SIDEBAR_COLLAPSED_WIDTH = 48;
var SUPPORTED_PRETTIER_EXTS = ['js', 'jsx', 'json', 'css', 'scss', 'html', 'md'];

var DEFAULT_EDITOR_PREFS = {
  theme: 'vs-dark',
  fontSize: 13,
  fontFamily: "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
  lineHeight: 0,
  letterSpacing: 0,
  tabSize: 4,
  insertSpaces: false,
  wordWrap: 'off',
  lineNumbers: 'on',
  renderWhitespace: 'none',
  scrollBeyondLastLine: false,
  minimap: false,
  bracketPairColorization: true,
  renderLineHighlight: 'none',
  cursorStyle: 'line',
  cursorBlinking: 'blink',
  folding: true,
  smoothScrolling: false,
  mouseWheelZoom: false,
  autoClosingBrackets: 'always',
  autoClosingQuotes: 'always',
  autoIndent: 'full',
  formatOnPaste: true,
  formatOnType: true,
  quickSuggestions: true,
  wordBasedSuggestions: 'matchingDocuments',
  acceptSuggestionOnEnter: 'on',
  autoRevealInExplorer: true,
  toolbarIconOnly: false,
  rubocopLintEnabled: true,
  prettierPrintWidth: 80,
  prettierTabWidth: 2,
  prettierUseTabs: false,
  prettierSemi: true,
  prettierSingleQuote: false,
  prettierTrailingComma: 'all',
  prettierBracketSpacing: true,
  vimMode: false,
  fileTreeTypeahead: true,
  quickOpenShowFolders: false,
  tabDisplayMode: 'scroll',
  persistFindState: true,
  showDotFiles: false
};

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
  var _ref$ariaBusy = _ref.ariaBusy;
  var ariaBusy = _ref$ariaBusy === undefined ? false : _ref$ariaBusy;

  return React.createElement(
    "button",
    {
      type: "button",
      className: "project-action-btn" + (danger ? " danger" : ""),
      title: title,
      "aria-label": ariaLabel || title,
      "aria-busy": !!ariaBusy,
      onClick: onClick,
      disabled: !!disabled
    },
    !ariaBusy && React.createElement("i", { className: iconClass })
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
      role: "group",
      "aria-label": ariaLabel
    },
    children
  );
};

function FileReloadBanner(_ref) {
  var pendingReloads = _ref.pendingReloads;
  var onSaveAndReload = _ref.onSaveAndReload;
  var onDiscardAndReload = _ref.onDiscardAndReload;
  var onKeepMine = _ref.onKeepMine;
  if (!pendingReloads || pendingReloads.length === 0) return null;
  return React.createElement(
    'div', { className: 'mb-file-reload-banner' },
    pendingReloads.map(function (r) {
      return React.createElement(
        'div', { key: r.paneId + ':' + r.tabId, className: 'mb-file-reload-item' },
        React.createElement(
          'span', { className: 'mb-file-reload-msg' },
          React.createElement('i', { className: 'fas fa-sync-alt' }),
          '  ',
          React.createElement('strong', null, r.name),
          '  was updated externally'
        ),
        React.createElement(
          'div', { className: 'mb-file-reload-actions' },
          React.createElement('button', {
            className: 'mb-btn mb-btn-sm mb-btn-primary',
            onClick: function () { onSaveAndReload(r); }
          }, 'Save & Reload'),
          React.createElement('button', {
            className: 'mb-btn mb-btn-sm mb-btn-warning',
            onClick: function () { onDiscardAndReload(r); }
          }, 'Discard & Reload'),
          React.createElement('button', {
            className: 'mb-btn mb-btn-sm',
            onClick: function () { onKeepMine(r); }
          }, 'Keep Mine')
        )
      );
    })
  );
}

var MbeditorApp = function MbeditorApp() {
  var _useState = useState(EditorStore.getState());

  var _useState2 = _slicedToArray(_useState, 2);

  var state = _useState2[0];
  var setState = _useState2[1];

  var _useState21 = useState(null);
  var _useState22 = _slicedToArray(_useState21, 2);
  var historyPanelPath = _useState22[0];
  var setHistoryPanelPath = _useState22[1];

  var _useState23 = useState(false);
  var _useState24 = _slicedToArray(_useState23, 2);
  var isNavigating = _useState24[0];
  var setIsNavigating = _useState24[1];

  var _useState25 = useState(false);
  var _useState26 = _slicedToArray(_useState25, 2);
  var isReviewOpen = _useState26[0];
  var setIsReviewOpen = _useState26[1];

  var _useState27 = useState(null);
  var _useState28 = _slicedToArray(_useState27, 2);
  var selectedCommit = _useState28[0];
  var setSelectedCommit = _useState28[1];

  var _useState29 = useState(null);
  var _useState30 = _slicedToArray(_useState29, 2);
  var commitDetailFiles = _useState30[0];
  var setCommitDetailFiles = _useState30[1];

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

  var _useStateSP = useState(new Set());
  var _useStateSP2 = _slicedToArray(_useStateSP, 2);
  var selectedPaths = _useStateSP2[0];
  var setSelectedPaths = _useStateSP2[1];

  var _useState7 = useState("");

  var _useState72 = _slicedToArray(_useState7, 2);

  var searchQuery = _useState72[0];
  var setSearchQuery = _useState72[1];

  var _useState33 = useState(false);
  var _useState332 = _slicedToArray(_useState33, 2);
  var searchLoading = _useState332[0];
  var setSearchLoading = _useState332[1];

  var searchRequestIdRef = useRef(0);

  var _useState33h = useState(false);
  var _useState33h2 = _slicedToArray(_useState33h, 2);
  var searchHasMore = _useState33h2[0];
  var setSearchHasMore = _useState33h2[1];

  var _useState33tc = useState(0);
  var _useState33tc2 = _slicedToArray(_useState33tc, 2);
  var searchTotalCount = _useState33tc2[0];
  var setSearchTotalCount = _useState33tc2[1];

  var searchHasMoreRef      = useRef(false);
  var searchOffsetRef       = useRef(0);
  var searchLoadingMoreRef  = useRef(false);

  var _useStateRx = useState(false);
  var _useStateRx2 = _slicedToArray(_useStateRx, 2);
  var searchUseRegex = _useStateRx2[0];
  var setSearchUseRegex = _useStateRx2[1];

  var _useStateMC = useState(false);
  var _useStateMC2 = _slicedToArray(_useStateMC, 2);
  var searchMatchCase = _useStateMC2[0];
  var setSearchMatchCase = _useStateMC2[1];

  var _useStateWW = useState(false);
  var _useStateWW2 = _slicedToArray(_useStateWW, 2);
  var searchWholeWord = _useStateWW2[0];
  var setSearchWholeWord = _useStateWW2[1];

  var searchQueryRef = useRef('');
  var searchUseRegexRef = useRef(false);
  var searchMatchCaseRef = useRef(false);
  var searchWholeWordRef = useRef(false);
  var searchResultsContainerRef = useRef(null);

  var _useStateRM = useState(false);
  var _useStateRM2 = _slicedToArray(_useStateRM, 2);
  var replaceMode = _useStateRM2[0];
  var setReplaceMode = _useStateRM2[1];

  var _useStateRQ = useState('');
  var _useStateRQ2 = _slicedToArray(_useStateRQ, 2);
  var replaceQuery = _useStateRQ2[0];
  var setReplaceQuery = _useStateRQ2[1];

  var _useStateRL = useState(false);
  var _useStateRL2 = _slicedToArray(_useStateRL, 2);
  var replaceLoading = _useStateRL2[0];
  var setReplaceLoading = _useStateRL2[1];

  var _useState8 = useState("explorer");

  var _useState82 = _slicedToArray(_useState8, 2);

  var activeSidebarTab = _useState82[0];
  var setActiveSidebarTab = _useState82[1];

  var _useStateSC = useState(false);
  var _useStateSC2 = _slicedToArray(_useStateSC, 2);
  var sidebarCollapsed = _useStateSC2[0];
  var setSidebarCollapsed = _useStateSC2[1];

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

  var dragSplitWidthRef = useRef(pane1Width);

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
  var showGitPanelRef = useRef(showGitPanel);
  showGitPanelRef.current = showGitPanel;

  var _useState18g = useState(320);
  var _useState18g2 = _slicedToArray(_useState18g, 2);
  var gitPanelWidth = _useState18g2[0];
  var setGitPanelWidth = _useState18g2[1];
  var gitPanelWidthRef = useRef(gitPanelWidth);
  gitPanelWidthRef.current = gitPanelWidth;

  var _useState18h = useState(false);

  var _useState18h2 = _slicedToArray(_useState18h, 2);

  var showHelp = _useState18h2[0];
  var setShowHelp = _useState18h2[1];

  var _useStatePwa = useState(null);
  var _useStatePwa2 = _slicedToArray(_useStatePwa, 2);
  var pwaInstallPrompt = _useStatePwa2[0];
  var setPwaInstallPrompt = _useStatePwa2[1];

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

  var _useState18e = useState(false);
  var _useState18e2 = _slicedToArray(_useState18e, 2);
  var gitAvailable = _useState18e2[0];
  var setGitAvailable = _useState18e2[1];

  var _useState18f = useState(false);
  var _useState18f2 = _slicedToArray(_useState18f, 2);
  var redmineEnabled = _useState18f2[0];
  var setRedmineEnabled = _useState18f2[1];

  var _useState18rc = useState(null);
  var _useState18rc2 = _slicedToArray(_useState18rc, 2);
  var rubocopConfigPath = _useState18rc2[0];
  var setRubocopConfigPath = _useState18rc2[1];

  var _useState18t = useState(false);
  var _useState18t2 = _slicedToArray(_useState18t, 2);
  var testAvailable = _useState18t2[0];
  var setTestAvailable = _useState18t2[1];

  var _useState18u = useState(null);
  var _useState18u2 = _slicedToArray(_useState18u, 2);
  var testResult = _useState18u2[0];
  var setTestResult = _useState18u2[1];

  var _useState18v = useState(false);
  var _useState18v2 = _slicedToArray(_useState18v, 2);
  var testLoading = _useState18v2[0];
  var setTestLoading = _useState18v2[1];

  var _useState18w = useState(true);
  var _useState18w2 = _slicedToArray(_useState18w, 2);
  var testInlineVisible = _useState18w2[0];
  var setTestInlineVisible = _useState18w2[1];

  var _useState18x = useState(null);
  var _useState18x2 = _slicedToArray(_useState18x, 2);
  var testPanelFile = _useState18x2[0];
  var setTestPanelFile = _useState18x2[1];

  var _useState18y = useState(false);
  var _useState18y2 = _slicedToArray(_useState18y, 2);
  var testPanelOpen = _useState18y2[0];
  var setTestPanelOpen = _useState18y2[1];

  var _useState18p = useState(DEFAULT_EDITOR_PREFS);
  var _useState18p2 = _slicedToArray(_useState18p, 2);
  var editorPrefs = _useState18p2[0];
  var setEditorPrefs = _useState18p2[1];

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

  var _useState24 = useState(140);
  var _useState242 = _slicedToArray(_useState24, 2);
  var openEditorsHeight = _useState242[0];
  var setOpenEditorsHeight = _useState242[1];

  var resizeSessionRef = useRef(null);
  var resizeRafRef = useRef(null);
  var prevGitBranchRef = useRef(null);
  var isSwitchingBranchRef = useRef(false);
  var stateRestoredRef = useRef(false);

  // ── Draft backup helpers ─────────────────────────────────────────────────
  var draftWriteTimerRef = useRef({});
  var serverOnlineRef = useRef(true);

  var _draftKey = function _draftKey(path) {
    var base = typeof window.mbeditorBasePath === 'function' ? window.mbeditorBasePath() : '';
    return 'mbeditor_draft\x00' + base + '\x00' + path;
  };
  var _saveDraftNow = function _saveDraftNow(path, content) {
    try { localStorage.setItem(_draftKey(path), JSON.stringify({ content: content, ts: Date.now() })); } catch (e) {}
  };
  var _clearDraft = function _clearDraft(path) {
    try { localStorage.removeItem(_draftKey(path)); } catch (e) {}
  };
  var _loadDraft = function _loadDraft(path) {
    try { return JSON.parse(localStorage.getItem(_draftKey(path))); } catch (e) { return null; }
  };
  var _scheduleDraftWrite = function _scheduleDraftWrite(path, content) {
    if (draftWriteTimerRef.current[path]) clearTimeout(draftWriteTimerRef.current[path]);
    draftWriteTimerRef.current[path] = setTimeout(function () {
      delete draftWriteTimerRef.current[path];
      _saveDraftNow(path, content);
    }, 500);
  };

  var _useState_dro = useState(null);
  var _useState_dro2 = _slicedToArray(_useState_dro, 2);
  var draftRestoreOffer = _useState_dro2[0];
  var setDraftRestoreOffer = _useState_dro2[1];

  var _useStateMR = useState(false);
  var _useStateMR2 = _slicedToArray(_useStateMR, 2);
  var monacoReady = _useStateMR2[0];
  var setMonacoReady = _useStateMR2[1];

  var _useStateZen = useState(false);
  var _useStateZen2 = _slicedToArray(_useStateZen, 2);
  var zenMode = _useStateZen2[0];
  var setZenMode = _useStateZen2[1];

  var clamp = function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  };

  var filterDotFiles = function filterDotFiles(nodes) {
    return nodes.filter(function(n) { return n.name[0] !== '.'; }).map(function(n) {
      return n.children ? Object.assign({}, n, { children: filterDotFiles(n.children) }) : n;
    });
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

  // Optimistically insert a new node into the in-memory treeData at the given parentPath.
  // This avoids the visual "disappear then reappear" flash while waiting for refreshProjectTree.
  var insertNodeIntoTree = function insertNodeIntoTree(tree, parentPath, node) {
    if (!parentPath) {
      return tree.concat(node);
    }
    return tree.map(function (item) {
      if (item.path === parentPath && item.type === 'folder') {
        return Object.assign({}, item, { children: (item.children || []).concat(node) });
      }
      if (item.type === 'folder' && item.children) {
        return Object.assign({}, item, { children: insertNodeIntoTree(item.children, parentPath, node) });
      }
      return item;
    });
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
      var prefs = EditorStore.getState().editorPrefs || DEFAULT_EDITOR_PREFS;
      window.prettier.format(tab.content, {
        parser: parserName,
        plugins: Object.values(window.prettierPlugins),
        printWidth: prefs.prettierPrintWidth != null ? prefs.prettierPrintWidth : 80,
        tabWidth: prefs.tabSize != null ? prefs.tabSize : 2,
        useTabs: !(prefs.insertSpaces),
        semi: prefs.prettierSemi !== false,
        singleQuote: !!prefs.prettierSingleQuote,
        trailingComma: prefs.prettierTrailingComma || 'all',
        bracketSpacing: prefs.prettierBracketSpacing !== false
      }).then(function () {
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
        if (err && err.loc) {
          // Prettier 3 (Babel parser) raises errors with err.loc = { line, column }
          // Older Prettier used err.loc = { start: { line, column }, end: {...} }
          var loc = err.loc.start ? err.loc.start : err.loc;
          var endLoc = err.loc.end || null;
          newMarkers.push({
            severity: "error",
            message: err.message.split("\n")[0] || "Syntax error",
            startLine: loc.line,
            startCol: loc.column,
            endLine: endLoc ? endLoc.line : loc.line,
            endCol: endLoc ? endLoc.column : loc.column + 1
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

  var setQuickOpen = function setQuickOpen(visible) {
    EditorStore.setState({ isQuickOpenVisible: visible });
  };

  // Persist state when openTabs or activeTabId changes
  useEffect(function () {
    // Subscribe to EditorStore
    var unsubscribe = EditorStore.subscribe(setState);

    // Resolve monacoReady when the __monacoReady promise settles.
    // This lets EditorPanel defer monaco.editor.create() until Monaco is loaded
    // while the rest of the UI (file tree, tabs, sidebar) renders immediately.
    var _mrMounted = true;
    if (window.__monacoReady && typeof window.__monacoReady.then === 'function') {
      window.__monacoReady.then(function() { if (_mrMounted) setMonacoReady(true); });
    } else {
      // Fallback: Monaco was already loaded synchronously (e.g. tests / old path).
      setMonacoReady(true);
    }

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
        window.MBEDITOR_RUBOCOP_AVAILABLE = workspace.rubocopAvailable;
      }
      if (workspace && workspace.rubocopConfigPath) {
        setRubocopConfigPath(workspace.rubocopConfigPath);
      }
      if (workspace && typeof workspace.hamlLintAvailable === 'boolean') {
        setHamlLintAvailable(workspace.hamlLintAvailable);
      }
      if (workspace && typeof workspace.gitAvailable === 'boolean') {
        setGitAvailable(workspace.gitAvailable);
      }
      if (workspace && typeof workspace.redmineEnabled === 'boolean') {
        setRedmineEnabled(workspace.redmineEnabled);
      }
      if (workspace && typeof workspace.testAvailable === 'boolean') {
        setTestAvailable(workspace.testAvailable);
      }
      if (workspace && typeof workspace.actionCableEnabled === 'boolean') {
        WebSocketService.connect(workspace.actionCableEnabled);
      }
    });

    // Helper: load tab content for a set of panes and restore them into EditorStore
    function loadPaneState(panesToLoad, focusedPaneId) {
      if (!panesToLoad || panesToLoad.length === 0) return Promise.resolve();
      var allTabs = panesToLoad.flatMap(function (p) { return p.tabs; });
      return Promise.all(allTabs.map(function (t) {
        if (t.isSettings || t.path === '__settings__') {
          return Promise.resolve({ content: '' });
        }
        if (t.isDiff && t.repoPath) {
          return GitService.fetchDiff(t.repoPath, t.diffBaseSha, t.diffHeadSha)
            .then(function (d) { return { content: 'Diff loaded', diffOriginal: d.original || '', diffModified: d.modified || '', _isDiffResult: true }; })
            ["catch"](function () { return { content: '', diffOriginal: '', diffModified: '', _isDiffResult: true }; });
        }
        if (t.isCombinedDiff || (t.path || '').startsWith('combined-diff://') || (t.path || '').startsWith('diff://')) {
          return Promise.resolve({ content: '' });
        }
        var sourcePath = t.isPreview || /::preview$/.test(t.path || '') ? t.previewFor || (t.path || '').replace(/::preview$/, '') : t.path;
        return FileService.getFile(sourcePath, { allowMissing: true }).then(function (data) {
          return {
            content: typeof data.content === 'string' ? data.content : '',
            fileNotFound: data && data.missing === true,
            image: data && data.image === true
          };
        })["catch"](function () { return { content: '', fileNotFound: false }; });
      })).then(function (results) {
        var resIdx = 0;
        var restoredPanes = panesToLoad.map(function (p) {
          return _extends({}, p, {
            tabs: p.tabs.map(function (t) {
              var res = results[resIdx++];
              return _extends({}, t, {
                content: res.content,
                externalContentVersion: (t.externalContentVersion || 0) + 1
              }, res._isDiffResult ? { diffOriginal: res.diffOriginal, diffModified: res.diffModified } : {},
              typeof res.fileNotFound === 'boolean' ? { fileNotFound: res.fileNotFound, dirty: res.fileNotFound ? false : t.dirty } : {},
              res.image === true ? { isImage: true } : {});
            })
          });
        });
        EditorStore.setState({ panes: restoredPanes, focusedPaneId: focusedPaneId || 1 });
      });
    }

    // Load global prefs + initial branch state concurrently
    Promise.all([
      GitService.fetchStatus()["catch"](function () { return null; }),
      FileService.getState()["catch"](function () { return {}; })
    ]).then(function (results) {
      var gitData = results[0];
      var savedState = results[1] || {};
      var branch = (gitData && gitData.branch) || EditorStore.getState().gitBranch || null;
      prevGitBranchRef.current = branch;

      // Restore global non-pane prefs
      if (savedState.editorPrefs && typeof savedState.editorPrefs === 'object') {
        setEditorPrefs(Object.assign({}, DEFAULT_EDITOR_PREFS, savedState.editorPrefs));
      }
      if (savedState.activeSidebarTab) {
        setActiveSidebarTab(savedState.activeSidebarTab);
      }
      if (savedState.sidebarCollapsed) {
        setSidebarCollapsed(true);
      }
      if (savedState.collapsedSections) {
        setCollapsedSections(savedState.collapsedSections);
      }
      if (savedState.expandedDirs) {
        setExpandedDirs(savedState.expandedDirs);
      }
      if (typeof savedState.showGitPanel === 'boolean') {
        setShowGitPanel(savedState.showGitPanel);
        if (savedState.showGitPanel) GitService.fetchInfo();
      }
      if (typeof savedState.gitPanelWidth === 'number') {
        setGitPanelWidth(savedState.gitPanelWidth);
      }
      if (typeof savedState.openEditorsHeight === 'number') {
        setOpenEditorsHeight(savedState.openEditorsHeight);
      }
      stateRestoredRef.current = true;

      // Load pane state for current branch; fall back to legacy global state panes
      var branchStatePromise = branch
        ? FileService.getBranchState(branch)["catch"](function () { return null; })
        : Promise.resolve(null);

      return branchStatePromise.then(function (branchState) {
        var hasBranchPanes = branchState && branchState.panes && branchState.panes.some(function (p) { return p.tabs && p.tabs.length > 0; });
        var panesToLoad, focusedPaneId;
        if (hasBranchPanes) {
          panesToLoad = branchState.panes;
          focusedPaneId = branchState.focusedPaneId || 1;
        } else {
          // Legacy fallback: use global state panes from mbeditor_workspace.json
          panesToLoad = savedState.panes;
          if (!panesToLoad && savedState.openTabs) {
            panesToLoad = [{ id: 1, tabs: savedState.openTabs, activeTabId: savedState.activeTabId }, { id: 2, tabs: [], activeTabId: null }];
          }
          focusedPaneId = savedState.focusedPaneId || 1;
        }
        return loadPaneState(panesToLoad, focusedPaneId);
      });
    });

    // Watch for git branch changes and swap per-branch tab state
    var unsubBranch = EditorStore.subscribeToSlice(['gitBranch'], function (st) {
      var newBranch = st.gitBranch;
      var oldBranch = prevGitBranchRef.current;
      if (!newBranch || newBranch === oldBranch) return;
      prevGitBranchRef.current = newBranch;
      if (!oldBranch || isSwitchingBranchRef.current) return;

      isSwitchingBranchRef.current = true;

      // Save pane state for old branch before switching
      var cur = EditorStore.getState();
      var lightweightPanes = cur.panes.map(function (p) {
        return {
          id: p.id,
          activeTabId: p.activeTabId,
          tabs: p.tabs.filter(function (t) { return !t.isCombinedDiff; }).map(function (t) {
            return {
              id: t.id, path: t.path, name: t.name, dirty: t.dirty, viewState: t.viewState,
              isSettings: !!t.isSettings, isPreview: !!t.isPreview, previewFor: t.previewFor || null,
              isDiff: !!t.isDiff, diffBaseSha: t.diffBaseSha || null, diffHeadSha: t.diffHeadSha || null,
              repoPath: t.repoPath || null
            };
          })
        };
      });
      FileService.saveBranchState(oldBranch, { panes: lightweightPanes, focusedPaneId: cur.focusedPaneId })["catch"](function () {});

      // Clear all open tabs for the new branch
      EditorStore.setState({
        panes: [{ id: 1, tabs: [], activeTabId: null }, { id: 2, tabs: [], activeTabId: null }],
        focusedPaneId: 1,
        activeTabId: null
      });

      // Load pane state for new branch (or start empty)
      FileService.getBranchState(newBranch)["catch"](function () { return null; }).then(function (branchState) {
        var hasBranchPanes = branchState && branchState.panes && branchState.panes.some(function (p) { return p.tabs && p.tabs.length > 0; });
        if (hasBranchPanes) {
          return loadPaneState(branchState.panes, branchState.focusedPaneId || 1);
        }
        return null;
      }).then(function () {
        // Prune states for deleted branches
        FileService.pruneBranchStates()["catch"](function () {});
        isSwitchingBranchRef.current = false;
      })["catch"](function () {
        isSwitchingBranchRef.current = false;
      });
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
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'S') {
        e.preventDefault();
        handleSaveAll();
      }
      if (e.altKey && e.shiftKey && e.key === 'F') {
        e.preventDefault();
        handleFormat();
      }
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'G') {
        e.preventDefault();
        toggleGitPanel();
      }
      // Ctrl+Shift+Z is handled in capture phase below so Monaco cannot swallow it.
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
      var clientY = e.clientY;
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
          var reservedRight = EDITOR_MIN_WIDTH + (showGitPanelRef.current ? gitPanelWidthRef.current : 0);
          var maxSidebarWidth = Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, rect.width - reservedRight));
          var nextWidth = clientX - rect.left;
          setSidebarWidth(clamp(nextWidth, SIDEBAR_MIN_WIDTH, maxSidebarWidth));
        }

        if (s.mode === 'gitpanel') {
          var body = document.getElementById('ide-body-container');
          if (!body) return;

          var rect = body.getBoundingClientRect();
          var nextWidth = rect.right - clientX;
          setGitPanelWidth(clamp(nextWidth, GIT_PANEL_MIN_WIDTH, 600));
        }

        if (s.mode === 'openeditors') {
          var delta = clientY - s.startY;
          var nextHeight = Math.max(60, Math.min(400, s.startHeight + delta));
          setOpenEditorsHeight(nextHeight);
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

    // Capture-phase listener for Ctrl+Shift+Z so it fires before Monaco's
    // own keybinding handler (which intercepts in the bubble phase).
    var onZenCapture = function(e) {
      if (e.ctrlKey && !e.metaKey && e.shiftKey && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        e.stopPropagation();
        toggleZenMode();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    document.addEventListener('keydown', onZenCapture, true);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return function () {
      _mrMounted = false;
      unsubscribe();
      unsubBranch();
      if (resizeRafRef.current) {
        cancelAnimationFrame(resizeRafRef.current);
        resizeRafRef.current = null;
      }
      window.removeEventListener('keydown', onKeyDown);
      document.removeEventListener('keydown', onZenCapture, true);
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };
  }, []);

  // Heartbeat — adaptive poll: 30s when connected, 5s when trying to reconnect.
  // Skipped entirely while the tab is hidden (Page Visibility API).
  useEffect(function () {
    var wasOnline = true;
    var timeoutId = null;

    function schedule() {
      var delay = wasOnline ? 30000 : 5000;
      timeoutId = setTimeout(tick, delay);
    }

    function tick() {
      if (document.hidden) {
        // Tab is backgrounded — skip this cycle and reschedule at the normal
        // online interval so we resume quickly once the tab becomes visible again.
        schedule();
        return;
      }
      FileService.ping().then(function () {
        if (!wasOnline) {
          wasOnline = true;
          setServerOnline(true);
        }
        schedule();
      }).catch(function () {
        if (wasOnline) {
          wasOnline = false;
          setServerOnline(false);
        }
        schedule();
      });
    }

    schedule();
    return function () { clearTimeout(timeoutId); };
  }, []);

  // On reconnect: scan open dirty tabs for newer localStorage drafts and offer restore.
  useEffect(function () {
    if (!serverOnline) {
      serverOnlineRef.current = false;
      return;
    }
    if (serverOnlineRef.current) return; // was already online — no transition
    serverOnlineRef.current = true;
    var st = EditorStore.getState();
    var offers = [];
    st.panes.forEach(function (pane) {
      pane.tabs.forEach(function (tab) {
        if (!tab.dirty || !tab.path || tab.path.startsWith('mbeditor://')) return;
        var draft = _loadDraft(tab.path);
        if (draft && draft.content !== tab.content) {
          offers.push({ paneId: pane.id, tabId: tab.id, path: tab.path, name: tab.name, draftContent: draft.content });
        }
      });
    });
    if (offers.length > 0) setDraftRestoreOffer(offers);
  }, [serverOnline]);

  // WebSocket push — when the server broadcasts files_changed, refresh the tree
  // and git status immediately (same work as the 10s poll below does).
  useEffect(function () {
    function handleFilesChanged() {
      if (document.hidden) return;
      GitService.fetchStatus()["catch"](function () {});
      FileService.getTree().then(function (data) {
        var newData = data || [];
        setTreeData(function (prevData) {
          if (JSON.stringify(newData) === JSON.stringify(prevData)) return prevData;
          SearchService.buildIndex(newData);
          return newData;
        });
      })["catch"](function () {});
    }
    WebSocketService.onFilesChanged(handleFilesChanged);
    return function () { WebSocketService.offFilesChanged(handleFilesChanged); };
  }, []);

  // Auto-refresh the file tree every 10s to pick up external changes (new files, deletions, etc.)
  // When an ActionCable WebSocket is connected this acts only as a safety-net fallback —
  // the WebSocket push above handles immediate invalidation after mbeditor mutations.
  // Uses functional setTreeData to skip the re-render when nothing has changed.
  useEffect(function () {
    var intervalId = setInterval(function () {
      if (document.hidden) return;
      if (WebSocketService.isConnected()) return; // WebSocket is handling refreshes
      // Refresh tree and check for git branch changes (to trigger per-branch tab state swap)
      GitService.fetchStatus()["catch"](function () {});
      FileService.getTree().then(function (data) {
        var newData = data || [];
        setTreeData(function (prevData) {
          if (JSON.stringify(newData) === JSON.stringify(prevData)) return prevData;
          SearchService.buildIndex(newData);
          return newData;
        });
      }).catch(function () {}); // silently ignore auto-refresh errors
    }, 10000);
    return function () { clearInterval(intervalId); };
  }, []);

  var handleSelectFile = function handleSelectFile(path, name, line) {
    TabManager.openTab(path, name, line);
    handleNodeSelect({ path: path, name: name || path.split('/').pop(), type: 'file' });
    setQuickOpen(false);
  };

  // Single-click in explorer: soft (preview) open — replaces any existing soft tab
  var handleSoftOpenFile = function handleSoftOpenFile(path, name) {
    TabManager.openTab(path, name, null, null, true);
    handleNodeSelect({ path: path, name: name || path.split('/').pop(), type: 'file' });
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
    handleNodeSelect({ path: path, name: name || path.split('/').pop(), type: 'file' });
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
        SearchService.invalidate();
        GitService.fetchStatus();
        // Reset the AVI clean baseline so undo past this save point shows dirty correctly.
        var _closeEntry = window.__mbeditorModels && window.__mbeditorModels[tab.path];
        if (_closeEntry && _closeEntry.model && !_closeEntry.model.isDisposed()) {
          _closeEntry.cleanVersionId = _closeEntry.model.getAlternativeVersionId();
        }
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
    // Don't overwrite server state with React defaults before the initial load completes.
    if (!stateRestoredRef.current) return;
    // debounce explicitly using setTimeout to avoid spamming the backend
    var timeoutId = setTimeout(function () {
      var st = EditorStore.getState();
      var lightweightPanes = st.panes.map(function (p) {
        return {
          id: p.id,
          activeTabId: p.activeTabId,
          tabs: p.tabs.filter(function(t) { return !t.isCombinedDiff; }).map(function (t) {
            return {
              id: t.id,
              path: t.path,
              name: t.name,
              dirty: t.dirty,
              viewState: t.viewState,
              isSettings: !!t.isSettings,
              isPreview: !!t.isPreview,
              previewFor: t.previewFor || null,
              isDiff: !!t.isDiff,
              diffBaseSha: t.diffBaseSha || null,
              diffHeadSha: t.diffHeadSha || null,
              repoPath: t.repoPath || null
            };
          })
        };
      });
      // Save pane state per-branch so it can be restored when switching back
      var currentBranch = prevGitBranchRef.current;
      if (currentBranch && !isSwitchingBranchRef.current) {
        FileService.saveBranchState(currentBranch, { panes: lightweightPanes, focusedPaneId: st.focusedPaneId })["catch"](function () {});
      }
      // Also persist to global state (prefs + panes as legacy fallback)
      FileService.saveState({ panes: lightweightPanes, focusedPaneId: st.focusedPaneId, collapsedSections: collapsedSections, expandedDirs: expandedDirs, showGitPanel: showGitPanel, gitPanelWidth: gitPanelWidth, editorPrefs: editorPrefs, activeSidebarTab: activeSidebarTab, sidebarCollapsed: sidebarCollapsed, openEditorsHeight: openEditorsHeight });
    }, 1000);
    return function () {
      return clearTimeout(timeoutId);
    };
  }, [state.panes, state.focusedPaneId, collapsedSections, expandedDirs, showGitPanel, gitPanelWidth, editorPrefs, activeSidebarTab, sidebarCollapsed, openEditorsHeight]);

  useEffect(function() {
    document.documentElement.setAttribute('data-theme', editorPrefs.theme || 'vs-dark');
  }, [editorPrefs.theme]);

  useEffect(function() {
    EditorStore.setState({ editorPrefs: editorPrefs });
  }, [editorPrefs]);

  useEffect(function() {
    var handler = function(e) {
      e.preventDefault();
      setPwaInstallPrompt(e);
    };
    window.addEventListener('beforeinstallprompt', handler);
    return function() { window.removeEventListener('beforeinstallprompt', handler); };
  }, []);

  var focusedPane = state.panes.find(function (p) {
    return p.id === state.focusedPaneId;
  }) || state.panes[0] || null;
  var activeTab = focusedPane && focusedPane.tabs.find(function (t) {
    return t.id === focusedPane.activeTabId;
  });

  // Phase 7: Per-file last-commit info shown in the status bar
  var _useState31 = useState(null);
  var _useState32 = _slicedToArray(_useState31, 2);
  var activeFileCommit = _useState32[0];
  var setActiveFileCommit = _useState32[1];

  // EOL indicator — tracks current line-ending style of the active file
  var _useState31e = useState(null);
  var _useState31e2 = _slicedToArray(_useState31e, 2);
  var activeEOL = _useState31e2[0];
  var setActiveEOL = _useState31e2[1];

  useEffect(function () {
    if (!gitAvailable || !activeTab || activeTab.isDiff || activeTab.isCombinedDiff || activeTab.isCommitGraph || !activeTab.path || activeTab.path.indexOf('diff://') === 0 || activeTab.path.indexOf('combined-diff://') === 0) {
      setActiveFileCommit(null);
      return;
    }
    var currentPath = activeTab.path;
    GitService.fetchFileHistory(currentPath).then(function(data) {
      var first = data && data.history && data.history[0];
      if (first) {
        setActiveFileCommit({ hash: first.hash, title: first.title, author: first.author, date: first.date });
      } else {
        setActiveFileCommit(null);
      }
    }).catch(function() {
      setActiveFileCommit(null);
    });
  }, [activeTab ? activeTab.id : null, gitAvailable]);

  // Update EOL indicator whenever active tab or its content changes
  useEffect(function () {
    if (!activeTab || typeof activeTab.content !== 'string' ||
        activeTab.isDiff || activeTab.isCombinedDiff || activeTab.isCommitGraph || activeTab.isPreview) {
      setActiveEOL(null);
      return;
    }
    if (activeTab.content.indexOf('\r\n') !== -1) {
      setActiveEOL('CRLF');
    } else if (activeTab.content.indexOf('\r') !== -1) {
      setActiveEOL('CR');
    } else {
      setActiveEOL('LF');
    }
  }, [activeTab ? activeTab.id : null, activeTab ? activeTab.content : null]);

  useEffect(function () {
    if (!activeTab || typeof activeTab.content !== 'string') return;
    if (activeTab.isDiff || activeTab.isCombinedDiff || activeTab.isCommitGraph) return;
    if (isRubyPath(activeTab.path) && !rubocopAvailable) return;
    if (activeTab.path.endsWith('.haml') && !hamlLintAvailable) return;

    // Clear markers and skip auto-lint when RuboCop linting is disabled
    if (isRubyPath(activeTab.path) && editorPrefs.rubocopLintEnabled === false) {
      setMarkers(function(prev) { return _extends({}, prev, _defineProperty({}, activeTab.id, [])); });
      return;
    }

    _debouncedAutoLint(activeTab, focusedPane ? focusedPane.id : null);

    return function () {
      _debouncedAutoLint.cancel();
    };
  }, [focusedPane ? focusedPane.id : null, activeTab ? activeTab.id : null, activeTab ? activeTab.content : null, rubocopAvailable, hamlLintAvailable, editorPrefs.rubocopLintEnabled]);

  var handleOpenCommitGraph = function handleOpenCommitGraph() {
    var paneId = state.focusedPaneId || 1;
    var tabId = 'mbeditor://commit-graph';
    
    var pane = state.panes.find(function(p) { return p.id === paneId; });
    var existing = pane && pane.tabs.find(function(t) { return t.id === tabId; });
    if (existing) {
      TabManager.switchTab(paneId, tabId);
      return;
    }

    var newTab = {
      id: tabId,
      path: tabId,
      name: 'Commit Graph',
      dirty: false,
      content: '', // not used
      isCommitGraph: true
    };

    var newPanes = state.panes.map(function(p) {
      if (p.id === paneId) {
        return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: tabId });
      }
      return p;
    });

    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId, activeTabId: tabId });
    
    // Fetch data asynchronously
    GitService.fetchCommitGraph().then(function(data) {
      var s = EditorStore.getState();
      var p = s.panes.find(function(p) { return p.id === paneId; });
      if (!p) return;
      var t = p.tabs.find(function(t) { return t.id === tabId; });
      if (t) {
        var newPanes2 = s.panes.map(function(p2) {
          if (p2.id === paneId) {
            var newTabs = p2.tabs.map(function(t2) {
              return t2.id === tabId ? Object.assign({}, t2, { commits: data.commits }) : t2;
            });
            return Object.assign({}, p2, { tabs: newTabs });
          }
          return p2;
        });
        EditorStore.setState({ panes: newPanes2 });
      }
    });
  };

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
      // Reset the AVI clean baseline so undo past this save point shows dirty correctly.
      var _modelEntry = window.__mbeditorModels && window.__mbeditorModels[tab.path];
      if (_modelEntry && _modelEntry.model && !_modelEntry.model.isDisposed()) {
        _modelEntry.cleanVersionId = _modelEntry.model.getAlternativeVersionId();
      }
      EditorStore.setStatus("Saved", "success");
      _clearDraft(tab.path);
      SearchService.invalidate();

      // Hot reload for Markdown: sync preview tab after save
      if (/\.(md|markdown)$/i.test(tab.path)) {
        TabManager.syncMarkdownPreview(tab.path, tab.content);
      }

      GitService.fetchStatus();
    })["catch"](function (err) {
      EditorStore.setStatus("Save failed: " + err.message, "error");
    })["finally"](function () {
      return setLoading(function (prev) {
        return _extends({}, prev, { save: false });
      });
    });
  };

  function dismissPendingReload(reload) {
    EditorStore.setState({
      pendingReloads: EditorStore.getState().pendingReloads.filter(function (r) {
        return !(r.paneId === reload.paneId && r.tabId === reload.tabId);
      })
    });
  }

  function handleSaveAndReload(reload) {
    var st = EditorStore.getState();
    var pane = st.panes.find(function (p) { return p.id === reload.paneId; });
    var tab = pane && pane.tabs.find(function (t) { return t.id === reload.tabId; });
    if (!tab) { dismissPendingReload(reload); return; }
    FileService.saveFile(tab.path, tab.content).then(function () {
      EditorStore.setState({
        panes: EditorStore.getState().panes.map(function (p) {
          if (p.id !== reload.paneId) return p;
          return Object.assign({}, p, {
            tabs: p.tabs.map(function (t) {
              if (t.id !== reload.tabId) return t;
              return Object.assign({}, t, {
                content: reload.serverContent,
                dirty: false,
                externalContentVersion: (t.externalContentVersion || 0) + 1
              });
            })
          });
        })
      });
      dismissPendingReload(reload);
    })["catch"](function () {
      EditorStore.setStatus('Save failed — cannot reload', 'error');
    });
  }

  function handleDiscardAndReload(reload) {
    EditorStore.setState({
      panes: EditorStore.getState().panes.map(function (p) {
        if (p.id !== reload.paneId) return p;
        return Object.assign({}, p, {
          tabs: p.tabs.map(function (t) {
            if (t.id !== reload.tabId) return t;
            return Object.assign({}, t, {
              content: reload.serverContent,
              dirty: false,
              externalContentVersion: (t.externalContentVersion || 0) + 1
            });
          })
        });
      })
    });
    dismissPendingReload(reload);
  }

  function handleKeepMine(reload) {
    dismissPendingReload(reload);
  }

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
      // Reset AVI clean baselines for all saved files so undo past save shows dirty correctly.
      dirtyTabs.forEach(function(tab) {
        var _me = window.__mbeditorModels && window.__mbeditorModels[tab.path];
        if (_me && _me.model && !_me.model.isDisposed()) {
          _me.cleanVersionId = _me.model.getAlternativeVersionId();
        }
      });
      EditorStore.setStatus("All files saved", "success");
      SearchService.invalidate();
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
    var alreadySplit = pane2 && pane2.tabs.length > 0;
    // Only set the split ref; do NOT pre-split the view width here.
    // Pane 2 appears as a drop zone only when the cursor actually hovers
    // over the right-half editor content, keeping the tab bar intact.
    dragSplitWidthRef.current = alreadySplit ? pane1Width : 50;
    setDraggedTab({ sourcePaneId: sourcePaneId, tabId: tabId });
  };

  var clearDragState = function clearDragState() {
    // If pane 2 is still empty after the drag, restore pane 1 to full width.
    var pane2 = EditorStore.getState().panes.find(function (p) { return p.id === 2; });
    if (!pane2 || pane2.tabs.length === 0) {
      setPane1Width(100);
      dragSplitWidthRef.current = 50;
    }
    setDraggedTab(null);
    setDragOverPaneId(null);
  };

  var moveDraggedTabToPane = function moveDraggedTabToPane(targetPaneId) {
    if (!draggedTab) return;
    TabManager.moveTabToPane(draggedTab.sourcePaneId, targetPaneId, draggedTab.tabId);
    clearDragState();
  };

  var handleChangeEOL = function handleChangeEOL(newEOL) {
    var ed = window.__mbeditorActiveEditor;
    if (!ed || !window.monaco) return;
    var model = ed.getModel();
    if (!model || !activeTab || !focusedPane) return;
    var seq = newEOL === 'CRLF'
      ? window.monaco.editor.EndOfLineSequence.CRLF
      : window.monaco.editor.EndOfLineSequence.LF;
    model.setEOL(seq);
    var newContent = model.getValue();
    TabManager.markDirty(focusedPane.id, activeTab.path, newContent);
    setActiveEOL(newEOL);
    EditorStore.setStatus('Line endings changed to ' + newEOL, 'info');
  };

  var handleFormat = function handleFormat() {
    if (!activeTab) return;

    var isRubyLang = activeTab.path.endsWith('.rb') || activeTab.path.endsWith('.gemspec') || activeTab.path.endsWith("Rakefile") || activeTab.path.endsWith("Gemfile");

    if (isRubyLang && !rubocopAvailable) {
      EditorStore.setStatus("RuboCop is not available for this workspace.", "warning");
      return;
    }

    if (isRubyLang) {
      setLoading(function (prev) {
        return _extends({}, prev, { format: true });
      });
      EditorStore.setStatus("Formatting...", "info");
      FileService.formatFile(activeTab.path, activeTab.content).then(function (res) {
        if (res.content) {
          // Update content and mark dirty — user decides when to save.
          // The executeEdits path in EditorPanel preserves the undo stack.
          var newPanes = EditorStore.getState().panes.map(function (p) {
            if (p.id === focusedPane.id) return _extends({}, p, { tabs: p.tabs.map(function (t) {
                return t.id === activeTab.id ? _extends({}, t, { content: res.content, dirty: true, externalContentVersion: (t.externalContentVersion || 0) + 1 }) : t;
              }) });
            return p;
          });
          EditorStore.setState({ panes: newPanes });
        }
        EditorStore.setStatus("Formatted (Unsaved)", "success");
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

    if (parserName) {
      setLoading(function (prev) {
        return _extends({}, prev, { format: true });
      });
      EditorStore.setStatus("Formatting with Prettier...", "info");
      var doFormat = function doFormat() {
        return window.prettier.format(activeTab.content, {
          parser: parserName,
          plugins: Object.values(window.prettierPlugins),
          printWidth: editorPrefs.prettierPrintWidth != null ? editorPrefs.prettierPrintWidth : 80,
          tabWidth: editorPrefs.prettierTabWidth != null ? editorPrefs.prettierTabWidth : 2,
          useTabs: !!editorPrefs.prettierUseTabs,
          semi: editorPrefs.prettierSemi !== false,
          singleQuote: !!editorPrefs.prettierSingleQuote,
          trailingComma: editorPrefs.prettierTrailingComma || 'all',
          bracketSpacing: editorPrefs.prettierBracketSpacing !== false
        }).then(function (formatted) {
          var newPanes = EditorStore.getState().panes.map(function (p) {
            if (p.id === focusedPane.id) return _extends({}, p, { tabs: p.tabs.map(function (t) {
                return t.id === activeTab.id ? _extends({}, t, { content: formatted, dirty: true, externalContentVersion: (t.externalContentVersion || 0) + 1 }) : t;
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
      };
      if (window.prettier && window.prettierPlugins) {
        doFormat();
      } else if (window.loadPrettierPlugins) {
        window.loadPrettierPlugins().then(doFormat)["catch"](function (err) {
          EditorStore.setStatus("Failed to load Prettier: " + err.message, "error");
          setLoading(function (prev) { return _extends({}, prev, { format: false }); });
        });
      } else {
        EditorStore.setStatus("Prettier is not available.", "warning");
        setLoading(function (prev) { return _extends({}, prev, { format: false }); });
      }
      return;
    }

    // Fallback: Monaco re-indent using the editor's configured tabSize/insertSpaces
    var monacoEditor = window.__mbeditorActiveEditor;
    if (monacoEditor) {
      var reindentAction = monacoEditor.getAction('editor.action.reindentLines');
      if (reindentAction) {
        reindentAction.run().then(function () {
          EditorStore.setStatus("Formatted (Unsaved)", "success");
        });
      }
    }
  };

  var TEST_CACHE_PREFIX = 'mbeditor_test_result_';

  var loadCachedTestResult = function loadCachedTestResult(filePath) {
    try {
      var stored = localStorage.getItem(TEST_CACHE_PREFIX + filePath);
      return stored ? JSON.parse(stored) : null;
    } catch (e) {
      return null;
    }
  };

  var saveCachedTestResult = function saveCachedTestResult(filePath, result) {
    try {
      localStorage.setItem(TEST_CACHE_PREFIX + filePath, JSON.stringify(result));
    } catch (e) {}
  };

  var executeTestRun = function executeTestRun(filePath) {
    setTestLoading(true);
    EditorStore.setStatus('Running tests...', 'info');

    FileService.runTests(filePath).then(function (res) {
      var resultWithMeta = Object.assign({}, res, { cachedAt: Date.now() });
      var targetFile = res.testFile || filePath;
      setTestResult(resultWithMeta);
      setTestPanelFile(targetFile);
      setTestPanelOpen(true);
      saveCachedTestResult(filePath, resultWithMeta);
      if (res.ok) {
        var s = res.summary || {};
        var failCount = (s.failed || 0) + (s.errored || 0);
        if (failCount === 0) {
          EditorStore.setStatus('All ' + (s.total || 0) + ' tests passed', 'success');
        } else {
          EditorStore.setStatus(failCount + ' test' + (failCount === 1 ? '' : 's') + ' failed out of ' + (s.total || 0), 'warning');
        }
      } else {
        EditorStore.setStatus('Test run failed: ' + (res.error || 'unknown error'), 'error');
      }
    })["catch"](function (err) {
      var msg = err.response && err.response.data && err.response.data.error || err.message;
      var errResult = { ok: false, error: msg, tests: [], summary: null, cachedAt: Date.now() };
      setTestResult(errResult);
      setTestPanelFile(filePath);
      setTestPanelOpen(true);
      saveCachedTestResult(filePath, errResult);
      EditorStore.setStatus('Test run failed: ' + msg, 'error');
    })["finally"](function () {
      setTestLoading(false);
    });
  };

  var handleRunTest = function handleRunTest() {
    if (!activeTab || !activeTab.path) return;
    if (testLoading) return;

    var cached = loadCachedTestResult(activeTab.path);
    if (cached && !testPanelOpen) {
      setTestResult(cached);
      setTestPanelFile(cached.testFile || activeTab.path);
      setTestPanelOpen(true);
      return;
    }

    executeTestRun(activeTab.path);
  };

  var handleRerunTest = function handleRerunTest() {
    if (!activeTab || !activeTab.path) return;
    if (testLoading) return;
    executeTestRun(activeTab.path);
  };

  var onFormatRef = useRef(handleFormat);
  onFormatRef.current = handleFormat;

  // Eagerly load all remaining pages sequentially in the background.
  // Self-chains via .then() so only one request is in-flight at a time.
  // Uses only refs so it's safe to call from async callbacks without
  // worrying about stale closure state.
  var _debouncedSearch = useRef(window._.debounce(function (q) {
    if (!q.trim()) {
      searchRequestIdRef.current += 1;
      setSearchLoading(false);
      setSearchHasMore(false); searchHasMoreRef.current = false;
      setSearchTotalCount(0);
      searchOffsetRef.current = 0;
      searchLoadingMoreRef.current = false;
      searchQueryRef.current = '';
      EditorStore.setState({ searchResults: [], searchHasMore: false });
      return;
    }
    var requestId = ++searchRequestIdRef.current;
    setSearchLoading(true);
    setSearchHasMore(false); searchHasMoreRef.current = false;
    setSearchTotalCount(0);
    searchOffsetRef.current = 0;
    searchLoadingMoreRef.current = false;
    searchQueryRef.current = q;
    EditorStore.setState({ searchResults: [], searchHasMore: false });
    EditorStore.setStatus("Searching project...", "info");
    SearchService.projectSearch(q, 0, SearchService.PAGE_SIZE, { regex: searchUseRegexRef.current, matchCase: searchMatchCaseRef.current, wholeWord: searchWholeWordRef.current }).then(function (res) {
      if (searchRequestIdRef.current !== requestId) return;
      var hasMore = !!(res && res.hasMore);
      setSearchHasMore(hasMore); searchHasMoreRef.current = hasMore;
      searchOffsetRef.current = SearchService.PAGE_SIZE;
      if (res && res.totalCount != null) setSearchTotalCount(res.totalCount);
      var total = (res && res.totalCount != null) ? res.totalCount : (res && res.results ? res.results.length : 0);
      EditorStore.setStatus("Found " + total + (hasMore ? '+' : '') + " result" + (total !== 1 ? "s" : ""), "success");
    }).finally(function () {
      if (searchRequestIdRef.current === requestId) setSearchLoading(false);
    });
  }, 400)).current;

  var loadMoreSearchResults = function loadMoreSearchResults() {
    var q = searchQueryRef.current;
    if (!q || searchLoadingMoreRef.current || !searchHasMoreRef.current) return;
    searchLoadingMoreRef.current = true;
    var offset = searchOffsetRef.current;
    SearchService.projectSearch(q, offset, SearchService.PAGE_SIZE, { regex: searchUseRegexRef.current, matchCase: searchMatchCaseRef.current, wholeWord: searchWholeWordRef.current }).then(function(res) {
      if (searchQueryRef.current !== q) { searchLoadingMoreRef.current = false; return; }
      var hasMore = !!(res && res.hasMore);
      searchHasMoreRef.current = hasMore;
      setSearchHasMore(hasMore);
      searchOffsetRef.current = offset + SearchService.PAGE_SIZE;
      searchLoadingMoreRef.current = false;
    }).catch(function() {
      searchLoadingMoreRef.current = false;
    });
  };

  var handleSearchChange = function handleSearchChange(e) {
    var val = e.target.value;
    if (!val) { clearSearch(); return; }
    setSearchQuery(val);
    _debouncedSearch(val);
  };

  var handleSearchRegexToggle = function handleSearchRegexToggle() {
    var next = !searchUseRegexRef.current;
    searchUseRegexRef.current = next;
    setSearchUseRegex(next);
    if (searchQueryRef.current) {
      _debouncedSearch(searchQueryRef.current);
    }
  };

  var handleSearchMatchCaseToggle = function handleSearchMatchCaseToggle() {
    var next = !searchMatchCaseRef.current;
    searchMatchCaseRef.current = next;
    setSearchMatchCase(next);
    if (searchQueryRef.current) {
      _debouncedSearch(searchQueryRef.current);
    }
  };

  var handleSearchWholeWordToggle = function handleSearchWholeWordToggle() {
    var next = !searchWholeWordRef.current;
    searchWholeWordRef.current = next;
    setSearchWholeWord(next);
    if (searchQueryRef.current) {
      _debouncedSearch(searchQueryRef.current);
    }
  };

  var clearSearch = function clearSearch() {
    searchRequestIdRef.current += 1;
    if (_debouncedSearch.cancel) _debouncedSearch.cancel();
    setSearchQuery("");
    setSearchLoading(false);
    setSearchHasMore(false); searchHasMoreRef.current = false;
    setSearchTotalCount(0);
    searchOffsetRef.current = 0;
    searchLoadingMoreRef.current = false;
    searchQueryRef.current = '';
    EditorStore.setState({ searchResults: [], searchHasMore: false });
  };

  var execSearch = function execSearch(e) {
    e.preventDefault();
    _debouncedSearch(searchQuery);
  };

  var handleReplaceAll = function handleReplaceAll() {
    if (!searchQuery.trim()) {
      EditorStore.setStatus("Enter a search query first", "error");
      return;
    }
    var matchCount = (state.searchResults || []).length;
    var confirmMsg = "Replace all occurrences of \"" + searchQuery + "\" with \"" + replaceQuery + "\"?";
    if (matchCount > 0) {
      confirmMsg += " (" + matchCount + (searchHasMore ? "+" : "") + " match" + (matchCount !== 1 ? "es" : "") + " across files)";
    }
    if (!window.confirm(confirmMsg)) return;

    setReplaceLoading(true);
    EditorStore.setStatus("Replacing…", "info");
    SearchService.replaceInFiles(searchQuery, replaceQuery, {
      regex: searchUseRegexRef.current,
      matchCase: searchMatchCaseRef.current,
      wholeWord: searchWholeWordRef.current
    }).then(function(data) {
      var count   = data.replaced_count || 0;
      var files   = data.files_affected || [];
      var errors  = data.errors || [];
      var msg = "Replaced " + count + " occurrence" + (count !== 1 ? "s" : "") + " in " + files.length + " file" + (files.length !== 1 ? "s" : "");
      if (errors.length) msg += " (" + errors.length + " error" + (errors.length !== 1 ? "s" : "") + ")";
      EditorStore.setStatus(msg, errors.length ? "warning" : "success");

      // Invalidate search cache so next search reflects the new content.
      SearchService.invalidate();

      // Update any open Monaco models whose content changed.
      if (files.length && window.__mbeditorModels) {
        files.forEach(function(relPath) {
          var model = window.__mbeditorModels[relPath];
          if (!model) return;
          FileService.getFile(relPath).then(function(res) {
            if (res && res.content != null && !model.isDisposed()) {
              model.setValue(res.content);
            }
          }).catch(function() {});
        });
      }

      // Refresh search results to reflect replacements.
      if (searchQueryRef.current) {
        _debouncedSearch(searchQueryRef.current);
      }
    }).catch(function(err) {
      EditorStore.setStatus("Replace failed: " + (err.message || String(err)), "error");
    }).finally(function() {
      setReplaceLoading(false);
    });
  };

  // Load more results when the user scrolls near the bottom of the list.
  var handleSearchResultsScroll = function handleSearchResultsScroll(e) {
    var el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 200) {
      loadMoreSearchResults();
    }
  };

  var toggleGitPanel = function toggleGitPanel() {
    setShowGitPanel(function (prev) {
      if (!prev) GitService.fetchInfo();
      return !prev;
    });
  };

  var toggleZenMode = function toggleZenMode() {
    setZenMode(function (prev) {
      var next = !prev;
      // After React re-renders the new layout, call layout() on all visible Monaco editors
      // so they fill the reclaimed space correctly.
      setTimeout(function () {
        if (window.monaco && window.monaco.editor) {
          window.monaco.editor.getEditors().forEach(function(ed) {
            if (typeof ed.layout === 'function') ed.layout();
          });
        }
      }, 50);
      return next;
    });
  };

  var startGitPanelResize = function startGitPanelResize(e) {
    e.preventDefault();
    resizeSessionRef.current = { mode: 'gitpanel' };
    setActiveResizeMode('gitpanel');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  var handleSelectCommit = function handleSelectCommit(commit) {
    setSelectedCommit(commit);
    setCommitDetailFiles(null);
    GitService.fetchCommitDetail(commit.hash).then(function (data) {
      setCommitDetailFiles(data.files || []);
    }).catch(function () {
      setCommitDetailFiles([]);
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

  // Unified single-node select: keeps selectedTreeNode (anchor) + selectedPaths in sync
  var handleNodeSelect = function handleNodeSelect(node) {
    setSelectedTreeNode(node);
    setSelectedPaths(node ? new Set([node.path]) : new Set());
  };

  // Multi-select: Ctrl/Cmd or Shift click — updates selectedPaths without touching the anchor
  var handleMultiSelect = function handleMultiSelect(pathsSet) {
    setSelectedPaths(pathsSet);
  };

  // Move one or more paths into a target folder via the rename/mv API
  var handleMoveNodes = function handleMoveNodes(srcPaths, targetFolderPath) {
    var validSrcs = srcPaths.filter(function(p) {
      // Prevent moving a folder into itself or one of its descendants
      return p !== targetFolderPath && !targetFolderPath.startsWith(p + '/');
    });
    if (validSrcs.length === 0) return;

    var moves = validSrcs.map(function(srcPath) {
      var baseName = srcPath.split('/').pop();
      var destPath = targetFolderPath + '/' + baseName;
      return FileService.renamePath(srcPath, destPath).then(function() {
        applyRenameToOpenTabs(srcPath, destPath);
      });
    });

    Promise.all(moves).then(function() {
      setSelectedTreeNode(null);
      setSelectedPaths(new Set());
      EditorStore.setStatus('Moved ' + validSrcs.length + ' item(s).', 'success');
      return refreshProjectTree().then(function() { GitService.fetchStatus(); });
    })['catch'](function(err) {
      var message = err && err.response && err.response.data && err.response.data.error || err.message;
      EditorStore.setStatus('Move failed: ' + message, 'error');
    });
  };

  var openContextMenu = function openContextMenu(e, node) {
    setContextMenu({ x: e.clientX, y: e.clientY, node: node });
    handleNodeSelect(node);
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
    if (sidebarCollapsed) return;
    e.preventDefault();
    resizeSessionRef.current = { mode: 'sidebar' };
    setActiveResizeMode('sidebar');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  var startOpenEditorsResize = function startOpenEditorsResize(e) {
    if (collapsedSections.openEditors) return;
    e.preventDefault();
    resizeSessionRef.current = { mode: 'openeditors', startY: e.clientY, startHeight: openEditorsHeight };
    setActiveResizeMode('openeditors');
    document.body.style.cursor = 'row-resize';
    document.body.style.userSelect = 'none';
  };

  var toggleSidebarCollapsed = function toggleSidebarCollapsed() {
    setSidebarCollapsed(function (prev) { return !prev; });
  };

  var expandSidebarTo = function expandSidebarTo(tab) {
    setActiveSidebarTab(tab);
    setSidebarCollapsed(false);
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

  // Reveal a folder path in the explorer: switch to explorer tab and expand
  // all ancestor dirs plus the folder itself.
  var handleOpenFolderInExplorer = function handleOpenFolderInExplorer(folderPath) {
    var folderName = folderPath.split('/').pop() || folderPath;
    // Build ancestor + self expansion map
    var parts = folderPath.split('/');
    var toExpand = {};
    for (var i = 1; i <= parts.length; i++) {
      toExpand[parts.slice(0, i).join('/')] = true;
    }
    // Apply all state updates together so the tree renders once with everything correct
    setExpandedDirs(function(prev) { return Object.assign({}, prev, toExpand); });
    handleNodeSelect({ path: folderPath, name: folderName, type: 'folder' });
    setActiveSidebarTab('explorer');
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

    // Optimistically insert the new node so the tree doesn't flash empty while waiting for the server
    var optimisticNode = { path: path, name: name, type: type === 'folder' ? 'folder' : 'file', children: type === 'folder' ? [] : undefined };
    setTreeData(function (prev) { return insertNodeIntoTree(prev, parentPath, optimisticNode); });

    if (type === 'file') {
      setLoading(function (prev) {
        return _extends({}, prev, { createFile: true });
      });
      FileService.createFile(path, '').then(function (res) {
        var createdPath = res && res.path || path;
        var createdName = createdPath.split('/').pop();
        handleNodeSelect({ path: createdPath, name: createdName, type: 'file' });
        EditorStore.setStatus('Created file: ' + createdName, 'success');
        return refreshProjectTree().then(function () {
          handleSelectFile(createdPath, createdName);
          GitService.fetchStatus();
        });
      })["catch"](function (err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Create file failed: ' + message, 'error');
        // Roll back the optimistic node on failure
        refreshProjectTree();
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
        handleNodeSelect({ path: createdPath, name: createdPath.split('/').pop(), type: 'folder' });
        EditorStore.setStatus('Created folder: ' + createdPath, 'success');
        return refreshProjectTree().then(function () {
          return GitService.fetchStatus();
        });
      })["catch"](function (err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Create folder failed: ' + message, 'error');
        // Roll back the optimistic node on failure
        refreshProjectTree();
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
      setSelectedPaths(new Set([renamedPath]));
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
    // If a specific node is provided (e.g. from context menu), delete just that.
    // Otherwise delete all paths in the multi-selection (or fall back to selectedTreeNode).
    var pathsToDelete;
    if (targetNode !== undefined && targetNode) {
      pathsToDelete = [targetNode.path];
    } else if (selectedPaths && selectedPaths.size > 0) {
      pathsToDelete = Array.from(selectedPaths);
    } else if (selectedTreeNode && selectedTreeNode.path) {
      pathsToDelete = [selectedTreeNode.path];
    } else {
      EditorStore.setStatus('Select a file or folder to delete first.', 'warning');
      return;
    }

    // Remove paths that are already covered by a selected ancestor directory.
    // This prevents redundant requests (and resulting 404s) when a folder and
    // its children are both in the selection.
    pathsToDelete = pathsToDelete.filter(function(p) {
      return !pathsToDelete.some(function(other) {
        return other !== p && p.startsWith(other.endsWith('/') ? other : other + '/');
      });
    });

    var label = pathsToDelete.length === 1 ? pathsToDelete[0] : pathsToDelete.length + ' items';
    var confirmed = window.confirm('Delete ' + label + '? This cannot be undone.');
    if (!confirmed) return;

    setLoading(function (prev) {
      return _extends({}, prev, { deletePath: true });
    });
    Promise.allSettled(pathsToDelete.map(function(p) {
      return FileService.deletePath(p).then(function() {
        removeDeletedPathFromOpenTabs(p);
      });
    })).then(function (results) {
      var failures = results.filter(function(r) { return r.status === 'rejected'; });
      if (failures.length === 0) {
        handleNodeSelect(null);
        EditorStore.setStatus('Deleted: ' + label, 'success');
      } else {
        var message = failures[0].reason && failures[0].reason.response && failures[0].reason.response.data && failures[0].reason.response.data.error || (failures[0].reason && failures[0].reason.message) || 'Unknown error';
        EditorStore.setStatus('Delete failed: ' + message, 'error');
      }
      return refreshProjectTree().then(function () {
        GitService.fetchStatus();
      });
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
  var isPrettierable = activeTab && SUPPORTED_PRETTIER_EXTS.includes(activeTab.path.split('.').pop().toLowerCase());
  var rubocopLintOn = editorPrefs.rubocopLintEnabled !== false;
  var canLintAndFormat = !!activeTab;
  var hasGitBranch = !!(state.gitBranch && state.gitBranch.trim());

  var renderTabBar = function renderTabBar(paneId, tabs, activeId) {
    return React.createElement(TabBar, {
      tabs: tabs,
      activeId: activeId,
      paneId: paneId,
      tabDisplayMode: editorPrefs.tabDisplayMode || 'scroll',
      onSelect: function (id) {
        // Sync explorer selection with the newly active tab so there's only one highlight
        var tab = tabs.find(function(t) { return t.id === id; });
        if (tab && tab.path && !tab.path.startsWith('mbeditor://') && tab.path !== '__settings__') {
          handleNodeSelect({ path: tab.path, name: tab.name, type: 'file' });
        }
        TabManager.switchTab(paneId, id);
      },
      onClose: function (id) {
        return requestCloseTab(paneId, id);
      },
      onTabDragStart: function (id) {
        return handleTabDragStart(paneId, id);
      },
      onTabDragEnd: clearDragState,
      onHardenTab: function (tabId) {
        return TabManager.hardenTab(paneId, tabId);
      },
      onShowHistory: function (path) {
        setHistoryPanelPath(path);
      },
      onRevealInExplorer: function (path) {
        setActiveSidebarTab('explorer');
        handleNodeSelect({ path: path, name: path.split('/').pop(), type: 'file' });
        setExpandedDirs(function (prev) {
          var parts = path.split('/');
          var updates = {};
          for (var i = 0; i < parts.length - 1; i++) {
            updates[parts.slice(0, i + 1).join('/')] = true;
          }
          return Object.assign({}, prev, updates);
        });
      }
    });
  };

  function openSettingsTab() {
    var st = EditorStore.getState();
    var foundPaneId = null;
    var foundTab = null;
    st.panes.forEach(function(p) {
      if (!foundTab) {
        var t = p.tabs.find(function(tab) { return tab.path === '__settings__'; });
        if (t) { foundTab = t; foundPaneId = p.id; }
      }
    });
    if (foundTab) {
      var newPanes = st.panes.map(function(p) {
        if (p.id === foundPaneId) return Object.assign({}, p, { activeTabId: '__settings__' });
        return p;
      });
      EditorStore.setState({ panes: newPanes, focusedPaneId: foundPaneId, activeTabId: '__settings__' });
      return;
    }
    var paneId = st.focusedPaneId;
    var pane = st.panes.find(function(p) { return p.id === paneId; }) || st.panes[0];
    if (!pane) return;
    paneId = pane.id;
    var newTab = { id: '__settings__', path: '__settings__', name: 'Settings', dirty: false, content: '', isSettings: true };
    var newPanes2 = st.panes.map(function(p) {
      if (p.id === paneId) return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: '__settings__' });
      return p;
    });
    EditorStore.setState({ panes: newPanes2, focusedPaneId: paneId, activeTabId: '__settings__' });
  }

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
            }, disabled: loading.save || !activeTab || !activeTab.dirty, 'aria-busy': !!loading.save },
          !loading.save && React.createElement("i", { className: "fas fa-save" }),
          !editorPrefs.toolbarIconOnly && !loading.save && " Save",
          !loading.save && activeTab && activeTab.dirty ? " ●" : ""
        ),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleSaveAll, disabled: loading.saveAll || !state.panes.flatMap(function (p) {
              return p.tabs;
            }).some(function (t) {
              return t.dirty;
            }), 'aria-busy': !!loading.saveAll },
          !loading.saveAll && React.createElement(
            "i",
            { className: "fas fa-save", style: { position: 'relative' } },
            React.createElement("i", { className: "fas fa-save", style: { position: 'absolute', top: '-2px', left: '3px', fontSize: '9px', opacity: 0.8 } })
          ),
          !editorPrefs.toolbarIconOnly && !loading.saveAll && " Save All"
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          'div',
          { role: 'group' },
          React.createElement(
            "button",
            { className: "statusbar-btn", onClick: function() { var ed = window.__mbeditorActiveEditor; if (ed) ed.trigger('keyboard', 'undo', null); }, disabled: !activeTab || !state.canUndo, title: "Undo (Ctrl+Z)" },
            React.createElement("i", { className: "fas fa-undo" }),
            !editorPrefs.toolbarIconOnly && " Undo"
          ),
          React.createElement(
            "button",
            { className: "statusbar-btn", onClick: function() { var ed = window.__mbeditorActiveEditor; if (ed) ed.trigger('keyboard', 'redo', null); }, disabled: !activeTab || !state.canRedo, title: "Redo (Ctrl+Y)" },
            React.createElement("i", { className: "fas fa-redo" }),
            !editorPrefs.toolbarIconOnly && " Redo"
          )
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleFormat, disabled: loading.format || !canLintAndFormat, 'aria-busy': !!loading.format },
          !loading.format && React.createElement("i", { className: "fas fa-magic" }),
          !editorPrefs.toolbarIconOnly && !loading.format && " Format"
        ),
        hasGitBranch && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            { type: "button", className: "statusbar-btn", onClick: toggleGitPanel },
            React.createElement("i", { className: "fas fa-code-branch" }),
            !editorPrefs.toolbarIconOnly && " Git"
          )
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { type: "button", className: "statusbar-btn", onClick: function () { return setShowHelp(true); }, title: "Keyboard shortcuts & help" },
          React.createElement("i", { className: "fas fa-keyboard" }),
          !editorPrefs.toolbarIconOnly && " Help"
        ),
        pwaInstallPrompt && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            {
              type: "button",
              className: "statusbar-btn",
              title: "Install as app",
              onClick: function() {
                pwaInstallPrompt.prompt();
                pwaInstallPrompt.userChoice.then(function() { setPwaInstallPrompt(null); });
              }
            },
            React.createElement("i", { className: "fas fa-download" }),
            !editorPrefs.toolbarIconOnly && " Install"
          )
        )
      )
    ),
    showHelp && React.createElement(ShortcutHelp, { onClose: function () { return setShowHelp(false); } }),
    React.createElement(
      "div",
      { className: "ide-body", id: "ide-body-container" },
      React.createElement(
        "div",
        { className: "ide-sidebar" + (sidebarCollapsed ? " ide-sidebar-collapsed" : ""), style: { width: (sidebarCollapsed ? SIDEBAR_COLLAPSED_WIDTH : sidebarWidth) + "px", display: zenMode ? 'none' : undefined } },
        sidebarCollapsed
          ? React.createElement(
              "div",
              { className: "sidebar-icon-strip" },
              React.createElement(
                "div",
                { className: "sidebar-strip-top" },
                React.createElement(
                  "div",
                  { className: "sidebar-nav-group", "data-group": "nav" },
                  React.createElement(
                    "button",
                    { type: "button", className: "sidebar-strip-btn " + (activeSidebarTab === 'explorer' ? 'active' : ''), title: "Explorer", onClick: function () { return expandSidebarTo('explorer'); } },
                    React.createElement("i", { className: "far fa-folder" })
                  ),
                  React.createElement(
                    "button",
                    { type: "button", className: "sidebar-strip-btn " + (activeSidebarTab === 'search' ? 'active' : ''), title: "Search", onClick: function () { return expandSidebarTo('search'); } },
                    React.createElement("i", { className: "fas fa-search" })
                  ),
                  React.createElement(
                    "button",
                    { type: "button", className: "sidebar-strip-btn", title: "Editor Preferences", onClick: openSettingsTab },
                    React.createElement("i", { className: "fas fa-cog" })
                  )
                )
              ),
              React.createElement(
                "div",
                { className: "sidebar-strip-bottom" },
                React.createElement(
                  "button",
                  { type: "button", className: "sidebar-strip-btn", title: "Expand sidebar", onClick: toggleSidebarCollapsed },
                  React.createElement("i", { className: "fas fa-chevron-right" })
                )
              )
            )
          : React.createElement(
              React.Fragment,
              null,
              React.createElement(
                "div",
                { className: "ide-sidebar-tabs" },
                React.createElement(
                  "button",
                  { type: "button", className: "ide-sidebar-tab " + (activeSidebarTab === 'explorer' ? 'active' : ''), onClick: function () { return setActiveSidebarTab('explorer'); } },
                  "EXPLORER"
                ),
                React.createElement(
                  "button",
                  { type: "button", className: "ide-sidebar-tab " + (activeSidebarTab === 'search' ? 'active' : ''), onClick: function () { return setActiveSidebarTab('search'); } },
                  "SEARCH"
                ),
                React.createElement(
                  "button",
                  { type: "button", className: "ide-sidebar-tab ide-sidebar-tab-icon", title: "Editor Preferences", onClick: openSettingsTab },
                  React.createElement("i", { className: "fas fa-cog" })
                ),
                React.createElement(
                  "button",
                  { type: "button", className: "sidebar-strip-btn", title: "Collapse sidebar", onClick: toggleSidebarCollapsed },
                  React.createElement("i", { className: "fas fa-chevron-left" })
                )
              ),
              activeSidebarTab === 'explorer' && React.createElement(
          "div",
          { className: "ide-sidebar-content" },
          React.createElement(
            "div",
            { className: "ide-sidebar-fixed", style: { '--open-editors-height': openEditorsHeight + 'px' } },
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
                            if (tab.path && !tab.path.startsWith('mbeditor://') && tab.path !== '__settings__') {
                              handleNodeSelect({ path: tab.path, name: tab.name, type: 'file' });
                            }
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
          )
          ),
          state.panes.flatMap(function (p) { return p.tabs; }).length > 0 && React.createElement(
            "div",
            { className: "open-editors-resize-handle", onMouseDown: startOpenEditorsResize }
          ),
          React.createElement(
            "div",
            { className: "ide-sidebar-scrollable" },
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
                  iconClass: 'far fa-file',
                  ariaBusy: !!loading.createFile,
                  onClick: function () {
                    return handleCreateFile();
                  },
                  disabled: !!loading.createFile
                }),
                React.createElement(SidebarActionButton, {
                  title: "New folder",
                  iconClass: 'far fa-folder',
                  ariaBusy: !!loading.createDir,
                  onClick: function () {
                    return handleCreateDir();
                  },
                  disabled: !!loading.createDir
                }),
                React.createElement(SidebarActionButton, {
                  title: "Rename selected",
                  iconClass: 'fas fa-pen',
                  ariaBusy: !!loading.renamePath,
                  onClick: function () {
                    return handleRenamePath();
                  },
                  disabled: !!loading.renamePath || !selectedTreePath
                }),
                React.createElement(SidebarActionButton, {
                  title: "Delete selected",
                  iconClass: 'far fa-trash-alt',
                  ariaBusy: !!loading.deletePath,
                  onClick: function () {
                    return handleDeletePath();
                  },
                  disabled: !!loading.deletePath || selectedPaths.size === 0,
                  danger: true
                })
              )
            },
            React.createElement(FileTree, {
              items: editorPrefs.showDotFiles ? treeData : filterDotFiles(treeData || []),
              onSelect: handleSoftOpenFile,
              activePath: editorPrefs.autoRevealInExplorer !== false ? (activeTab && activeTab.path) : null,
              selectedPaths: selectedPaths,
              anchorPath: selectedTreePath,
              onNodeSelect: handleNodeSelect,
              onMultiSelect: handleMultiSelect,
              onMove: handleMoveNodes,
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
              onRenameCancel: handleRenameCancel,
              typeaheadEnabled: editorPrefs.fileTreeTypeahead !== false
            })
          )
          )
        ),
        activeSidebarTab === 'search' && React.createElement(
          "div",
          { className: "search-panel" },
          React.createElement(
            "div",
            { className: "search-input-shell" },
            React.createElement("input", {
              className: "search-input",
              placeholder: "Find in files…",
              value: searchQuery,
              onChange: handleSearchChange
            }),
            React.createElement(
              "div",
              { className: "search-input-adornments" },
              React.createElement(
                "button",
                {
                  type: "button",
                  className: "search-adornment-btn" + (searchMatchCase ? " active" : ""),
                  onClick: handleSearchMatchCaseToggle,
                  title: "Match Case"
                },
                React.createElement("i", { className: "codicon codicon-case-sensitive" })
              ),
              React.createElement(
                "button",
                {
                  type: "button",
                  className: "search-adornment-btn" + (searchWholeWord ? " active" : ""),
                  onClick: handleSearchWholeWordToggle,
                  title: "Match Whole Word"
                },
                React.createElement("i", { className: "codicon codicon-whole-word" })
              ),
              React.createElement(
                "button",
                {
                  type: "button",
                  className: "search-adornment-btn" + (searchUseRegex ? " active" : ""),
                  onClick: handleSearchRegexToggle,
                  title: "Use Regular Expression"
                },
                React.createElement("i", { className: "codicon codicon-regex" })
              ),
              React.createElement(
                "button",
                {
                  type: "button",
                  className: "search-adornment-btn" + (replaceMode ? " active" : ""),
                  onClick: function() { setReplaceMode(function(p) { return !p; }); },
                  title: "Toggle Replace"
                },
                React.createElement("i", { className: "codicon codicon-replace" })
              ),
              searchQuery && React.createElement(
                "button",
                {
                  type: "button",
                  className: "search-adornment-btn search-adornment-clear",
                  onClick: clearSearch,
                  title: "Clear search",
                  "aria-label": "Clear search"
                },
                React.createElement("i", { className: "fas fa-times" })
              )
            )
          ),
          replaceMode && React.createElement(
            "div",
            { className: "search-replace-row" },
            React.createElement("input", {
              className: "search-input search-replace-input",
              placeholder: "Replace with…",
              value: replaceQuery,
              onChange: function(e) { setReplaceQuery(e.target.value); },
              disabled: replaceLoading
            }),
            React.createElement(
              "button",
              {
                type: "button",
                className: "search-replace-all-btn",
                onClick: handleReplaceAll,
                disabled: !searchQuery.trim() || replaceLoading,
                title: "Replace All"
              },
              replaceLoading
                ? React.createElement("i", { className: "fas fa-spinner fa-spin" })
                : React.createElement(React.Fragment, null,
                    React.createElement("i", { className: "codicon codicon-replace-all" }),
                    " Replace All"
                  )
            )
          ),
          (function() {
            var allResults  = state.searchResults || [];
            var loadedCount = allResults.length;
            var total       = searchTotalCount > 0 ? searchTotalCount : loadedCount;
            var hasAny      = loadedCount > 0;

            return React.createElement(
              React.Fragment,
              null,
              searchQuery && !searchLoading && React.createElement(
                "div",
                { className: "search-results-header" },
                hasAny
                  ? (total + (searchHasMore ? '+' : '') + " result" + (total !== 1 ? "s" : ""))
                  : "No results"
              ),
              React.createElement(
                "div",
                { className: "search-results-area" },
                hasAny && React.createElement(
                  "div",
                  {
                    className: "search-results" + (searchLoading ? " search-results-blurred" : ""),
                    ref: searchResultsContainerRef,
                    onScroll: handleSearchResultsScroll
                  },
                  allResults.map(function(res, i) {
                    var fileName = res.file.split('/').pop();
                    return React.createElement(
                      "div",
                      {
                        key: i,
                        className: "search-result-item",
                        onClick: (function(r) { return function() { handleSelectFile(r.file, r.file.split('/').pop(), r.line); }; })(res)
                      },
                      React.createElement("i", { className: (window.getFileIcon ? window.getFileIcon(fileName) : 'far fa-file-code') + " search-result-icon" }),
                      React.createElement(
                        "div", { className: "search-result-body" },
                        React.createElement(
                          "div", { className: "search-result-file" },
                          fileName,
                          React.createElement("span", { className: "search-result-line-num" }, " ", res.file, ":", res.line)
                        ),
                        React.createElement("div", { className: "search-result-text" }, res.text)
                      )
                    );
                  }),
                  searchHasMore && React.createElement(
                    "div", { className: "search-loading-more" },
                    React.createElement("i", { className: "fas fa-spinner fa-spin" }),
                    " Loading more\u2026"
                  )
                ),
                searchLoading && React.createElement(
                  "div",
                  { className: "search-loading-overlay" },
                  React.createElement("div", { className: "search-loading-spinner" })
                )
              )
            );
          })()
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

            // If the cursor is over the tab bar, suppress the cross-pane split overlay
            // so same-pane tab reordering within any tab bar is unaffected.
            if (e.target && e.target.closest && e.target.closest('.tab-bar')) {
              if (dragOverPaneId !== null) setDragOverPaneId(null);
              e.dataTransfer.dropEffect = 'move';
              return;
            }

            var rect = e.currentTarget.getBoundingClientRect();
            var splitAtX = rect.left + rect.width * (dragSplitWidthRef.current / 100);
            var hoverPaneId = e.clientX >= splitAtX ? 2 : 1;
            var nextDropPane = hoverPaneId === draggedTab.sourcePaneId ? null : hoverPaneId;

            // When cursor first enters the right-half content area and pane 2 is empty,
            // apply the 50% split width so the drop zone becomes visible.
            if (nextDropPane === 2) {
              var pane2Empty = EditorStore.getState().panes.find(function(p) { return p.id === 2; });
              if (!pane2Empty || pane2Empty.tabs.length === 0) {
                setPane1Width(50);
              }
            }

            e.dataTransfer.dropEffect = 'move';
            if (dragOverPaneId !== nextDropPane) setDragOverPaneId(nextDropPane);
          },
          onDropCapture: function (e) {
            if (!draggedTab) return;

            // If dropping onto a tab bar element, let the tab item's own onDrop
            // bubble-phase handler manage the reorder — don't intercept here.
            if (e.target && e.target.closest && e.target.closest('.tab-bar')) {
              return;
            }

            e.preventDefault();

            var rect = e.currentTarget.getBoundingClientRect();
            var splitAtX = rect.left + rect.width * (dragSplitWidthRef.current / 100);
            var targetPaneId = e.clientX >= splitAtX ? 2 : 1;

            if (targetPaneId !== draggedTab.sourcePaneId) {
              moveDraggedTabToPane(targetPaneId);
            } else {
              clearDragState();
            }
          }
        },
        state.panes.map(function (pane, idx) {
          // Show empty pane 2 as a drop zone only when the cursor is actively hovering
          // over its half of the editor content (dragOverPaneId === 2).
          if (pane.id === 2 && pane.tabs.length === 0 && dragOverPaneId !== 2) return null;

          // Dynamic width distribution
          var isSplit = state.panes[1].tabs.length > 0 || dragOverPaneId === 2;
          var flexBasis = '100%';
          if (isSplit) flexBasis = pane.id === 1 ? pane1Width + "%" : 100 - pane1Width + "%";

          var isFocused = state.focusedPaneId === pane.id;
          var pActiveTab = pane.tabs.find(function (t) {
            return t.id === pane.activeTabId;
          });
          var canAcceptDrop = !!draggedTab && draggedTab.sourcePaneId !== pane.id;
          var isDropTarget = canAcceptDrop && dragOverPaneId === pane.id;

          var content;
          if (pane.tabs.length === 0) {
            content = React.createElement(
              'div',
              { className: 'ide-empty-pane' },
              React.createElement('i', { className: 'fas fa-code ide-empty-icon' }),
              React.createElement(
                'p',
                null,
                'Ctrl+P to open files'
              )
            );
          } else if (pActiveTab) {
              if (pActiveTab.isCommitGraph) {
                content = React.createElement(window.CommitGraph || CommitGraph, {
                  commits: pActiveTab.commits || [],
                  onSelectCommit: handleSelectCommit
                });
              } else if (pActiveTab.isSettings) {
                content = React.createElement(
                  'div',
                  { className: 'ide-settings-tab-content' },
                  React.createElement(
                    'div',
                    { className: 'ide-settings-body' },

                    /* ── Appearance ──────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Appearance'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Theme'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.theme || 'vs-dark',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { theme: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'vs-dark' }, 'Dark'),
                        React.createElement('option', { value: 'vs' }, 'Light'),
                        React.createElement('option', { value: 'hc-black' }, 'HC Dark'),
                        React.createElement('option', { value: 'hc-light' }, 'HC Light'),
                        React.createElement('option', { value: 'dracula' }, 'Dracula'),
                        React.createElement('option', { value: 'night-owl' }, 'Night Owl'),
                        React.createElement('option', { value: 'monokai' }, 'Monokai'),
                        React.createElement('option', { value: 'nord' }, 'Nord'),
                        React.createElement('option', { value: 'github-dark' }, 'GitHub Dark'),
                        React.createElement('option', { value: 'tomorrow-night' }, 'Tomorrow Night'),
                        React.createElement('option', { value: 'github-light' }, 'GitHub Light')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Font size'),
                      React.createElement('input', {
                        key: String(editorPrefs.fontSize || 13),
                        type: 'number', min: '8', max: '32', step: '1',
                        className: 'ide-settings-input',
                        defaultValue: editorPrefs.fontSize || 13,
                        onChange: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (v >= 8 && v <= 32) setEditorPrefs(function(p) { return Object.assign({}, p, { fontSize: v }); });
                        },
                        onBlur: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (isNaN(v) || v < 8 || v > 32) e.target.value = String(editorPrefs.fontSize || 13);
                        }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row-full' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Font family'),
                      React.createElement('input', {
                        type: 'text',
                        className: 'ide-settings-input ide-settings-input-wide',
                        value: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
                        onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { fontFamily: e.target.value }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Row height in pixels. 0 = auto (roughly font size × 1.5)' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Line height (0=auto)'),
                      React.createElement('input', {
                        key: String(editorPrefs.lineHeight != null ? editorPrefs.lineHeight : 0),
                        type: 'number', min: '0', max: '100', step: '1',
                        className: 'ide-settings-input',
                        defaultValue: editorPrefs.lineHeight != null ? editorPrefs.lineHeight : 0,
                        onChange: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (!isNaN(v) && v >= 0 && v <= 100) setEditorPrefs(function(p) { return Object.assign({}, p, { lineHeight: v }); });
                        },
                        onBlur: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (isNaN(v) || v < 0 || v > 100) e.target.value = String(editorPrefs.lineHeight != null ? editorPrefs.lineHeight : 0);
                        }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Extra space between characters in pixels. 0 = default' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Letter spacing (px)'),
                      React.createElement('input', {
                        key: String(editorPrefs.letterSpacing != null ? editorPrefs.letterSpacing : 0),
                        type: 'number', min: '-5', max: '20', step: '0.5',
                        className: 'ide-settings-input',
                        defaultValue: editorPrefs.letterSpacing != null ? editorPrefs.letterSpacing : 0,
                        onChange: function(e) {
                          var v = parseFloat(e.target.value);
                          if (!isNaN(v) && v >= -5 && v <= 20) setEditorPrefs(function(p) { return Object.assign({}, p, { letterSpacing: v }); });
                        },
                        onBlur: function(e) {
                          var v = parseFloat(e.target.value);
                          if (isNaN(v) || v < -5 || v > 20) e.target.value = String(editorPrefs.letterSpacing != null ? editorPrefs.letterSpacing : 0);
                        }
                      })
                    ),

                    /* ── Indentation (unified editor + Prettier) ── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Indentation'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Tab size'),
                      React.createElement('input', {
                        key: String(editorPrefs.tabSize || 4),
                        type: 'number', min: '1', max: '8', step: '1',
                        className: 'ide-settings-input',
                        defaultValue: editorPrefs.tabSize || 4,
                        onChange: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (v >= 1 && v <= 8) setEditorPrefs(function(p) { return Object.assign({}, p, { tabSize: v }); });
                        },
                        onBlur: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (isNaN(v) || v < 1 || v > 8) e.target.value = String(editorPrefs.tabSize || 4);
                        }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Use spaces'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.insertSpaces),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { insertSpaces: v }); }); }
                      })
                    ),

                    /* ── Editor ──────────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Editor'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Word wrap'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.wordWrap || 'off',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { wordWrap: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'off' }, 'Off'),
                        React.createElement('option', { value: 'on' }, 'On'),
                        React.createElement('option', { value: 'wordWrapColumn' }, 'Column')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Line numbers'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.lineNumbers || 'on',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { lineNumbers: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'on' }, 'On'),
                        React.createElement('option', { value: 'off' }, 'Off'),
                        React.createElement('option', { value: 'relative' }, 'Relative')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Whitespace'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.renderWhitespace || 'none',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { renderWhitespace: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'none' }, 'None'),
                        React.createElement('option', { value: 'selection' }, 'Selection'),
                        React.createElement('option', { value: 'boundary' }, 'Boundary'),
                        React.createElement('option', { value: 'all' }, 'All')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Minimap'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.minimap),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { minimap: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Scroll past end'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.scrollBeyondLastLine),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { scrollBeyondLastLine: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Bracket colors'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.bracketPairColorization),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { bracketPairColorization: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Vim mode'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.vimMode),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { vimMode: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'When to insert a matching closing bracket automatically' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Auto-close brackets'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.autoClosingBrackets || 'always',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { autoClosingBrackets: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'always' }, 'Always'),
                        React.createElement('option', { value: 'languageDefined' }, 'Per language rules'),
                        React.createElement('option', { value: 'beforeWhitespace' }, 'Only before whitespace'),
                        React.createElement('option', { value: 'never' }, 'Never')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'When to insert a matching closing quote automatically' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Auto-close quotes'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.autoClosingQuotes || 'always',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { autoClosingQuotes: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'always' }, 'Always'),
                        React.createElement('option', { value: 'languageDefined' }, 'Per language rules'),
                        React.createElement('option', { value: 'beforeWhitespace' }, 'Only before whitespace'),
                        React.createElement('option', { value: 'never' }, 'Never')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'What to highlight on the current editor line' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Line highlight'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.renderLineHighlight || 'none',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { renderLineHighlight: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'none' }, 'None'),
                        React.createElement('option', { value: 'gutter' }, 'Line number only'),
                        React.createElement('option', { value: 'line' }, 'Current line background'),
                        React.createElement('option', { value: 'all' }, 'Line number + background')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Cursor style'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.cursorStyle || 'line',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { cursorStyle: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'line' }, 'Line (|)'),
                        React.createElement('option', { value: 'block' }, 'Block (filled)'),
                        React.createElement('option', { value: 'underline' }, 'Underline (_)'),
                        React.createElement('option', { value: 'line-thin' }, 'Line thin'),
                        React.createElement('option', { value: 'block-outline' }, 'Block outline'),
                        React.createElement('option', { value: 'underline-thin' }, 'Underline thin')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Cursor blinking'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.cursorBlinking || 'blink',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { cursorBlinking: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'blink' }, 'Blink (on/off)'),
                        React.createElement('option', { value: 'smooth' }, 'Smooth (fade)'),
                        React.createElement('option', { value: 'phase' }, 'Phase (offset fade)'),
                        React.createElement('option', { value: 'expand' }, 'Expand (grow/shrink)'),
                        React.createElement('option', { value: 'solid' }, 'Solid (no blink)')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Show collapse arrows next to foldable regions (functions, classes, blocks)' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Code folding'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.folding !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { folding: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Animate scrolling instead of jumping instantly' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Smooth scrolling'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.smoothScrolling),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { smoothScrolling: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Hold Ctrl (or Cmd) and scroll the mouse wheel to zoom the font size' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Ctrl+scroll to zoom'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.mouseWheelZoom),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { mouseWheelZoom: v }); }); }
                      })
                    ),

                    /* ── Behaviour ───────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Behaviour'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'How aggressively the editor re-indents lines as you type' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Auto indent'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.autoIndent || 'full',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { autoIndent: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'none' }, 'None (disabled)'),
                        React.createElement('option', { value: 'keep' }, 'Keep current level'),
                        React.createElement('option', { value: 'brackets' }, 'Indent on { and ['),
                        React.createElement('option', { value: 'advanced' }, 'Language indent rules'),
                        React.createElement('option', { value: 'full' }, 'Full (language grammar)')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Whether pressing Enter accepts the highlighted autocomplete suggestion' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Accept suggestion on Enter'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.acceptSuggestionOnEnter || 'on',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { acceptSuggestionOnEnter: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'on' }, 'Always'),
                        React.createElement('option', { value: 'smart' }, 'Only when navigated (↑↓)'),
                        React.createElement('option', { value: 'off' }, 'Never (Tab only)')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Suggest completions based on words already present in open files' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Word-based suggestions'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.wordBasedSuggestions || 'matchingDocuments',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { wordBasedSuggestions: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'off' }, 'Off'),
                        React.createElement('option', { value: 'currentDocument' }, 'Current file only'),
                        React.createElement('option', { value: 'matchingDocuments' }, 'Same language files'),
                        React.createElement('option', { value: 'allDocuments' }, 'All open files')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Auto-format pasted code using the language formatter' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Format on paste'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.formatOnPaste !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { formatOnPaste: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Re-indent and auto-close blocks as you type (e.g. after pressing Enter inside {})' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Format on type'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.formatOnType !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { formatOnType: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Show autocomplete suggestions while typing (not just on trigger characters like .)' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Quick suggestions'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.quickSuggestions !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { quickSuggestions: v }); }); }
                      })
                    ),

                    /* ── Formatting (Prettier) ───────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Formatting'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Print width'),
                      React.createElement('input', {
                        key: String(editorPrefs.prettierPrintWidth != null ? editorPrefs.prettierPrintWidth : 80),
                        type: 'number', min: '40', max: '200', step: '1',
                        className: 'ide-settings-input',
                        defaultValue: editorPrefs.prettierPrintWidth != null ? editorPrefs.prettierPrintWidth : 80,
                        onChange: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (v >= 40 && v <= 200) setEditorPrefs(function(p) { return Object.assign({}, p, { prettierPrintWidth: v }); });
                        },
                        onBlur: function(e) {
                          var v = parseInt(e.target.value, 10);
                          if (isNaN(v) || v < 40 || v > 200) e.target.value = String(editorPrefs.prettierPrintWidth != null ? editorPrefs.prettierPrintWidth : 80);
                        }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Trailing commas'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.prettierTrailingComma || 'all',
                          onChange: function(e) { setEditorPrefs(function(p) { return Object.assign({}, p, { prettierTrailingComma: e.target.value }); }); }
                        },
                        React.createElement('option', { value: 'all' }, 'All'),
                        React.createElement('option', { value: 'es5' }, 'ES5'),
                        React.createElement('option', { value: 'none' }, 'None')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Semicolons'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.prettierSemi !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { prettierSemi: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Single quotes'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!editorPrefs.prettierSingleQuote,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { prettierSingleQuote: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Bracket spacing'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.prettierBracketSpacing !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { prettierBracketSpacing: v }); }); }
                      })
                    ),

                    /* ── Interface ───────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'Interface'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Explorer follows active file'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.autoRevealInExplorer),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { autoRevealInExplorer: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Explorer type-ahead'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.fileTreeTypeahead !== false),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { fileTreeTypeahead: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Show dotfiles'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.showDotFiles),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { showDotFiles: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Tab bar layout'),
                      React.createElement(
                        'select', {
                          value: editorPrefs.tabDisplayMode || 'scroll',
                          onChange: function(e) { var v = e.target.value; setEditorPrefs(function(p) { return Object.assign({}, p, { tabDisplayMode: v }); }); }
                        },
                        React.createElement('option', { value: 'scroll' }, 'Scroll'),
                        React.createElement('option', { value: 'wrap' }, 'Wrap (multi-row)')
                      )
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Quick Open: show folders'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.quickOpenShowFolders),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { quickOpenShowFolders: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Toolbar: icons only'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.toolbarIconOnly),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { toolbarIconOnly: v }); }); }
                      })
                    ),

                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Persist find state across files'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.persistFindState !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { persistFindState: v }); }); }
                      })
                    ),

                    /* ── RuboCop ─────────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'RuboCop'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Enable RuboCop linting'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.rubocopLintEnabled !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { rubocopLintEnabled: v }); }); }
                      })
                    ),
                    rubocopAvailable && rubocopConfigPath ? React.createElement(
                      'div', { className: 'ide-settings-row ide-settings-row-link' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Config file'),
                      React.createElement(
                        'button', {
                          type: 'button',
                          className: 'ide-settings-config-link',
                          title: 'Open ' + rubocopConfigPath,
                          onClick: function() { handleSelectFile(rubocopConfigPath, rubocopConfigPath.split('/').pop()); }
                        },
                        React.createElement('i', { className: 'fas fa-file-alt', style: { marginRight: 5 } }),
                        rubocopConfigPath
                      )
                    ) : null,
                    React.createElement(
                      'button',
                      {
                        className: 'ide-settings-reset-btn',
                        type: 'button',
                        onClick: function() { setEditorPrefs(Object.assign({}, DEFAULT_EDITOR_PREFS)); }
                      },
                      React.createElement('i', { className: 'fas fa-undo', style: { marginRight: 6 } }),
                      'Reset to defaults'
                    )
                  )
                );
              } else if (pActiveTab.isDiff) {
                var _t = editorPrefs.theme || 'vs-dark';
                var isDiffDark = _t !== 'vs' && _t !== 'hc-light' && _t !== 'github-light';
                content = React.createElement(window.DiffViewer || DiffViewer, {
                  key: pActiveTab.id,
                  path: pActiveTab.path,
                  original: pActiveTab.diffOriginal || '',
                  modified: pActiveTab.diffModified || '',
                  isDark: isDiffDark,
                  editorPrefs: editorPrefs,
                  onClose: function() { requestCloseTab(pane.id, pActiveTab.id); }
                });
              } else {
                content = React.createElement(window.EditorPanel || EditorPanel, {
                  key: pActiveTab.id,
                  tab: pActiveTab,
                  paneId: pane.id,
                  markers: markers[pActiveTab.id] || [],
                  gitAvailable: gitAvailable,
                  testAvailable: testAvailable,
                  treeData: treeData,
                  testResult: testResult,
                  testPanelFile: testPanelFile,
                  testLoading: testLoading,
                  testInlineVisible: testInlineVisible,
                  editorPrefs: editorPrefs,
                  monacoReady: monacoReady,
                  onFormat: function() { onFormatRef.current(); },
                  onSave: function() { handleSave(pane.id, pActiveTab); },
                  onRunTest: handleRunTest,
                  onShowHistory: function(path) { setHistoryPanelPath(path); },
                  onContentChange: function onContentChange(val) {
                    // Dirty/clean state is now set in EditorPanel via AVI comparison.
                    // onContentChange only needs to handle draft persistence.
                    var st = EditorStore.getState();
                    var cp = st.panes.find(function(p) { return p.id === pane.id; });
                    var ct = cp && cp.tabs.find(function(t) { return t.id === pActiveTab.id; });
                    if (ct && ct.dirty) {
                      _scheduleDraftWrite(pActiveTab.path, val);
                    } else {
                      _clearDraft(pActiveTab.path);
                    }
                  }
                });
              }
          }

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
                onClickCapture: function (e) {
                  // Do not steal click events from controls inside the Settings tab.
                  // Focusing the pane in capture phase can rerender before checkbox
                  // change events are processed, making toggles appear stuck.
                  if (e.target && e.target.closest && e.target.closest('.ide-settings-tab-content')) return;
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
                renderTabBar(pane.id, pane.tabs, pane.activeTabId),
                React.createElement(
                  "div",
                  { style: { flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', visibility: activeResizeMode === 'pane' ? 'hidden' : 'visible' } },
                  content
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
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+Shift+S")),
                            React.createElement("td", null, "Save all dirty files")
                          ),
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Alt+Shift+F")),
                            React.createElement("td", null, "Format the active file")
                          ),
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+Shift+G")),
                            React.createElement("td", null, "Toggle git panel")
                          ),
                          React.createElement("tr", null,
                            React.createElement("td", null, React.createElement("kbd", null, "Ctrl+Shift+Z")),
                            React.createElement("td", null, "Toggle zen / focus mode")
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

      // Right-side Git panel (children of ide-body, alongside sidebar and ide-main)
      showGitPanel && !zenMode && React.createElement("div", {
        className: "panel-divider gitpanel-divider " + (activeResizeMode === 'gitpanel' ? 'active' : ''),
        onMouseDown: startGitPanelResize,
        role: "separator",
        "aria-orientation": "vertical",
        "aria-label": "Resize git panel"
      }),
      showGitPanel && !zenMode && React.createElement(
        "div",
        { className: "ide-git-right-panel", style: { width: gitPanelWidth + "px" } },
        React.createElement(window.GitPanel || GitPanel, {
          gitInfo: state.gitInfo,
          error: state.gitInfoError,
          redmineEnabled: redmineEnabled,
          onRefresh: function () { return GitService.fetchInfo(); },
          onClose: function () { return setShowGitPanel(false); },
          onOpenFile: openFileFromGitPanel,
          onOpenDiff: TabManager.openDiffTab,
          onOpenAllChanges: function(scope, label) { TabManager.openCombinedDiffTab(scope, label); },
          onSelectCommit: handleSelectCommit
        })
      )
    ),
    React.createElement(
      "div",
      { className: "ide-statusbar" },
      hasGitBranch && React.createElement(
        "div",
        { className: "statusbar-branch" },
        React.createElement("i", { className: "fas fa-code-branch" }),
        " ",
        state.gitBranch,
        state.gitInfo && state.gitInfo.ahead > 0 && React.createElement(
          "span",
          { className: "statusbar-aheadbehind", title: state.gitInfo.ahead + " commit(s) ahead of upstream" },
          " \u2191",
          state.gitInfo.ahead
        ),
        state.gitInfo && state.gitInfo.behind > 0 && React.createElement(
          "span",
          { className: "statusbar-aheadbehind statusbar-behind", title: state.gitInfo.behind + " commit(s) behind upstream" },
          " \u2193",
          state.gitInfo.behind
        )
      ),
      !serverOnline && (function () {
        var dirtyCount = state.panes.reduce(function (acc, p) {
          return acc + p.tabs.filter(function (t) { return t.dirty; }).length;
        }, 0);
        return React.createElement(
          "div",
          {
            className: "statusbar-offline",
            title: dirtyCount > 0 ? dirtyCount + " unsaved file" + (dirtyCount !== 1 ? "s" : "") + " — changes are backed up locally" : "Server offline"
          },
          React.createElement("i", { className: "fas fa-exclamation-triangle" }),
          dirtyCount > 0
            ? " Offline \u2014 " + dirtyCount + " unsaved"
            : " Server offline"
        );
      })(),
      activeFileCommit && React.createElement(
        "div",
        { className: "statusbar-file-commit", title: activeFileCommit.title + " — " + activeFileCommit.author },
        React.createElement("i", { className: "fas fa-history", style: { marginRight: "4px", opacity: 0.7 } }),
        React.createElement("span", { className: "commit-hash" }, activeFileCommit.hash.slice(0, 7)),
        " ",
        activeFileCommit.author
      ),
      React.createElement(
        "div",
        { className: "statusbar-msg " + state.statusMessage.kind },
        state.statusMessage.text
      ),
      activeEOL && React.createElement(
        "button",
        {
          type: "button",
          className: "statusbar-btn statusbar-eol-btn",
          title: "Line endings: " + activeEOL + " — click to change",
          onClick: function() { handleChangeEOL(activeEOL === 'CRLF' ? 'LF' : 'CRLF'); }
        },
        activeEOL
      ),
      zenMode && React.createElement(
        "button",
        {
          type: "button",
          className: "statusbar-btn statusbar-zen-btn",
          title: "Zen mode active — click or press Ctrl+Shift+Z to exit",
          onClick: toggleZenMode
        },
        "ZEN"
      ),
      React.createElement(
        "div",
        { className: "statusbar-version" },
        "v" + (document.body.dataset.mbeditorVersion || "")
      )
    ),

    // File History Panel overlay
    historyPanelPath && React.createElement(
      React.Fragment,
      null,
      React.createElement("div", {
        style: { position: 'fixed', inset: 0, zIndex: 9800, background: 'rgba(0,0,0,0.55)' },
        onClick: function() { setHistoryPanelPath(null); }
      }),
      React.createElement(window.FileHistoryPanel || FileHistoryPanel, {
        path: historyPanelPath,
        onClose: function () { return setHistoryPanelPath(null); },
        onSelectCommit: function (hash, path) {
          TabManager.openDiffTab(path, path.split('/').pop(), hash + '^', hash, null);
        }
      })
    ),

    // Test Results Panel overlay — closing hides the dialog but keeps testResult for inline markers
    (testPanelOpen || testLoading) && React.createElement(window.TestResultsPanel || TestResultsPanel, {
      result: testResult,
      testFile: testPanelFile,
      isLoading: testLoading,
      showInline: testInlineVisible,
      onToggleInline: function () { setTestInlineVisible(function (prev) { return !prev; }); },
      onClose: function () { setTestPanelOpen(false); },
      onRerun: handleRerunTest,
      onOpenTestFile: testPanelFile ? function () {
        var fileName = testPanelFile.split('/').pop();
        TabManager.openTab(testPanelFile, fileName);
        setTestPanelOpen(false);
      } : null
    }),

    // Commit Detail overlay (shown when a commit row is clicked in CommitGraph)
    selectedCommit && React.createElement(
      React.Fragment,
      null,
      React.createElement("div", {
        style: { position: 'fixed', inset: 0, zIndex: 9000, background: 'rgba(0,0,0,0.45)' },
        onClick: function() { setSelectedCommit(null); setCommitDetailFiles(null); }
      }),
      React.createElement(
        "div",
        { className: "ide-commit-detail-panel" },
        React.createElement(
          "div",
          { className: "ide-commit-detail-header" },
          React.createElement(
            "div",
            null,
            React.createElement("div", { className: "ide-commit-detail-title" }, selectedCommit.title),
            React.createElement(
              "div",
              { className: "ide-commit-detail-meta" },
              React.createElement("span", { className: "commit-hash" }, selectedCommit.hash.slice(0, 7)),
              " \xB7 ",
              selectedCommit.author,
              " \xB7 ",
              selectedCommit.date ? new Date(selectedCommit.date).toLocaleString() : ""
            )
          ),
          React.createElement(
            "button",
            { className: "git-header-btn", onClick: function() { setSelectedCommit(null); setCommitDetailFiles(null); }, title: "Close" },
            React.createElement("i", { className: "fas fa-times" })
          )
        ),
        commitDetailFiles === null
          ? React.createElement("div", { className: "git-empty", 'aria-busy': 'true' }, "Loading…")
          : commitDetailFiles.length === 0
            ? React.createElement("div", { className: "git-empty" }, "No file changes found.")
            : React.createElement(
                "div",
                { className: "git-list" },
                commitDetailFiles.map(function(f, i) {
                  var name = (f.path || '').split('/').pop() || f.path;
                  return React.createElement(
                    "div",
                    { key: i, className: "git-file-item" },
                    React.createElement(
                      "div",
                      { className: "git-file-info", onClick: function() { openFileFromGitPanel(f.path, name); } },
                      React.createElement("span", { className: "git-status-badge git-" + (f.status || 'M'), title: f.status }, f.status),
                      React.createElement("span", { className: "git-file-path", title: f.path }, f.path)
                    ),
                    React.createElement(
                      "div",
                      { className: "git-file-actions" },
                      React.createElement(
                        "button",
                        {
                          className: "git-action-btn",
                          title: "View Diff",
                          onClick: function(e) {
                            e.stopPropagation();
                            TabManager.openDiffTab(f.path, name, selectedCommit.hash + '^', selectedCommit.hash, null);
                          }
                        },
                        React.createElement("i", { className: "fas fa-exchange-alt" })
                      )
                    )
                  );
                })
              )
      )
    ),

    // Modals & Panels
    state.isQuickOpenVisible && React.createElement(window.QuickOpenDialog || QuickOpenDialog, {
      onSelect: handleSelectFile,
      showFolders: !!(editorPrefs.quickOpenShowFolders),
      onSelectFolder: handleOpenFolderInExplorer,
      onClose: function () { return setQuickOpen(false); }
    }),
    draftRestoreOffer && React.createElement(
      "div",
      {
        className: "ide-draft-restore-overlay",
        role: "dialog",
        "aria-modal": "true",
        "aria-label": "Restore unsaved drafts"
      },
      React.createElement(
        "div",
        { className: "ide-draft-restore-dialog" },
        React.createElement("div", { className: "ide-draft-restore-title" },
          React.createElement("i", { className: "fas fa-save", style: { marginRight: 8 } }),
          "Unsaved drafts found"
        ),
        React.createElement("div", { className: "ide-draft-restore-body" },
          draftRestoreOffer.length + " file" + (draftRestoreOffer.length !== 1 ? "s have" : " has") + " locally backed-up drafts from when the server was offline:"
        ),
        React.createElement(
          "ul",
          { className: "ide-draft-restore-list" },
          draftRestoreOffer.map(function (o) {
            return React.createElement("li", { key: o.path }, o.name || o.path);
          })
        ),
        React.createElement(
          "div",
          { className: "ide-draft-restore-actions" },
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-draft-restore-btn ide-draft-restore-btn-primary",
              onClick: function () {
                draftRestoreOffer.forEach(function (offer) {
                  TabManager.markDirty(offer.paneId, offer.tabId, offer.draftContent);
                });
                setDraftRestoreOffer(null);
              }
            },
            "Restore all"
          ),
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-draft-restore-btn",
              onClick: function () {
                draftRestoreOffer.forEach(function (offer) { _clearDraft(offer.path); });
                setDraftRestoreOffer(null);
              }
            },
            "Discard drafts"
          )
        )
      )
    ),
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