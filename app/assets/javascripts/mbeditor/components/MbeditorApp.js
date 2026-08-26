"use strict";

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i["return"]) _i["return"](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError("Invalid attempt to destructure non-iterable instance"); } }; })();

var _extends = Object.assign || function (target) { for (var i = 1; i < arguments.length; i++) { var source = arguments[i]; for (var key in source) { if (Object.prototype.hasOwnProperty.call(source, key)) { target[key] = source[key]; } } } return target; };

function _defineProperty(obj, key, value) { if (key in obj) { Object.defineProperty(obj, key, { value: value, enumerable: true, configurable: true, writable: true }); } else { obj[key] = value; } return obj; }

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;
var useMemo = _React.useMemo;

// Functional setTreeData updater shared by every path that re-fetches the tree
// (WebSocket push, the 10s poll, the manual refresh button).
//
// Returning prevData when nothing changed is the whole point: the fetched array
// is always a fresh object, so returning it unconditionally makes React commit
// on every tick and defeats FileTreeMemo's `prev.items === next.items` check —
// a full app re-render every 10 seconds, forever, with the tree untouched.
//
// The comparison is a deep one. An earlier version hashed only the top-level
// entry names, which missed every file added or removed inside a directory:
// the re-render happened anyway, and the quick-open index was never rebuilt.
// JSON.stringify over the whole tree measures 0.33 ms for ~1600 nodes, well
// under the render it saves.
function _treeUpdater(newData) {
  return function (prevData) {
    if (JSON.stringify(newData) === JSON.stringify(prevData)) return prevData;
    SearchService.buildIndex(newData);
    return newData;
  };
}

var SIDEBAR_MIN_WIDTH = 280;
var SIDEBAR_MAX_WIDTH = 560;
var EDITOR_MIN_WIDTH = 320;
var GIT_PANEL_MIN_WIDTH = 280;
var PANE_MIN_WIDTH_PERCENT = 20;
var PANE_MAX_WIDTH_PERCENT = 80;
var SIDEBAR_COLLAPSED_WIDTH = 48;
// Extension -> Prettier parser. Limited to what the vendored plugins actually
// parse (babel, estree, html, postcss, markdown); anything outside this map
// falls through to Monaco's re-indent.
//
// One map, one options builder, one runner — there were four copies of each,
// and they had drifted: two read a `prettierTabWidth`/`prettierUseTabs` pair
// that no settings screen ever wrote, so Prettier reprinted every JS/JSX file
// at two spaces however the editor was configured.
var PRETTIER_PARSERS = {
  js: 'babel', jsx: 'babel', mjs: 'babel', cjs: 'babel',
  json: 'json', jsonc: 'json', json5: 'json5',
  css: 'css', scss: 'scss', less: 'less',
  html: 'html', vue: 'vue',
  md: 'markdown', markdown: 'markdown'
};
var SUPPORTED_PRETTIER_EXTS = Object.keys(PRETTIER_PARSERS);

function prettierParserFor(path) {
  return PRETTIER_PARSERS[String(path || '').split('.').pop().toLowerCase()] || null;
}

// Indentation comes from the editor's own tabSize/insertSpaces, so formatting
// produces what the user set up. `insertSpaces !== true` mirrors how
// EditorPanel configures Monaco: anything but an explicit true means tabs.
function prettierOptions(prefs, parserName, extra) {
  return Object.assign({
    parser: parserName,
    plugins: Object.values(window.prettierPlugins || {}),
    printWidth: prefs.prettierPrintWidth != null ? prefs.prettierPrintWidth : 80,
    tabWidth: prefs.tabSize != null ? prefs.tabSize : 4,
    useTabs: prefs.insertSpaces !== true,
    semi: prefs.prettierSemi !== false,
    singleQuote: !!prefs.prettierSingleQuote,
    trailingComma: prefs.prettierTrailingComma || 'all',
    bracketSpacing: prefs.prettierBracketSpacing !== false
  }, extra || {});
}

// Format with Prettier, loading it on first use. Rejects if it cannot be
// loaded, so callers can report that rather than appear to do nothing.
function runPrettier(source, prefs, parserName, extra) {
  var go = function () { return window.prettier.format(source, prettierOptions(prefs, parserName, extra)); };
  if (window.prettier && window.prettierPlugins) return go();
  if (window.loadPrettierPlugins) return window.loadPrettierPlugins().then(go);
  return Promise.reject(new Error('Prettier is not available'));
}

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
  formatOnType: false,
  formatOnSave: false,
  quickSuggestions: true,
  wordBasedSuggestions: 'matchingDocuments',
  acceptSuggestionOnEnter: 'on',
  autoRevealInExplorer: true,
  toolbarIconOnly: false,
  rubocopLintEnabled: true,
  routeHints: true,
  prettierPrintWidth: 80,
  prettierSemi: true,
  prettierSingleQuote: false,
  prettierTrailingComma: 'all',
  prettierBracketSpacing: true,
  vimMode: false,
  fileTreeTypeahead: true,
  quickOpenShowFolders: false,
  tabDisplayMode: 'scroll',
  persistFindState: true,
  showDotFiles: false,
  branchStateRestore: true
};

// Indentation of formatted output is the formatter's job, not a post-pass:
// Prettier is given useTabs/tabWidth from the editor's own settings, and Ruby
// indentation comes from the project's .rubocop.yml. Monaco's built-in
// "Convert Indentation to Tabs / to Spaces" commands (F1) cover converting a
// file that is already open, using its own indentation guesser.

function diffLines(oldLines, newLines) {
  var n = oldLines.length, m = newLines.length;
  var dp = [];
  for (var i = 0; i <= n; i++) { dp.push(new Array(m + 1).fill(0)); }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      dp[i][j] = oldLines[i-1] === newLines[j-1] ? dp[i-1][j-1] + 1 : Math.max(dp[i-1][j], dp[i][j-1]);
    }
  }
  var changed = [], i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldLines[i-1] === newLines[j-1]) { i--; j--; }
    else if (j > 0 && (i === 0 || dp[i][j-1] >= dp[i-1][j])) { changed.push(j); j--; }
    else { i--; }
  }
  return changed;
}

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

  // The tooltip lives on a wrapper, not on the button, and is drawn by CSS
  // rather than the title attribute. Both parts are load-bearing:
  //
  // The host app's Pico CSS sets `pointer-events: none` on [disabled], so a
  // disabled button never receives hover and a native title never appears at
  // all — and Rename/Delete are disabled whenever nothing is selected, which
  // is most of the time. Hanging the tooltip on an always-enabled wrapper is
  // what keeps it working in that state.
  //
  // Native titles are also ~1s late, which is already why .collab-hovercard
  // exists rather than a title on the collab chip.
  return React.createElement(
    "span",
    { className: "sb-tip", "data-tip": title },
    React.createElement(
      "button",
      {
        type: "button",
        className: "project-action-btn" + (danger ? " danger" : ""),
        "aria-label": ariaLabel || title,
        "aria-busy": !!ariaBusy,
        onClick: onClick,
        disabled: !!disabled
      },
      !ariaBusy && React.createElement("i", { className: iconClass })
    )
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

// Split a search hit into [before, match, after] so the match can be tinted
// and pinned on screen. `col`/`end_col` are 1-based against the RAW line while
// the row renders the stripped `text`, so `lead` — the characters strip took
// off the front — is what maps one onto the other. Returns null for the tiers
// and queries that produce no columns; the row then renders as plain text.
function searchMatchParts(res) {
  var text = res.text == null ? "" : String(res.text);
  if (!res.col || !res.end_col) return null;
  var start = res.col - 1 - (res.lead || 0);
  var end = Math.min(res.end_col - 1 - (res.lead || 0), text.length);
  if (!(start >= 0 && end > start && start < text.length)) return null;
  // U+200E: a strong LTR character, so the left-ellipsis trick in
  // .search-result-pre (direction: rtl) can never reorder a segment that
  // happens to be all punctuation.
  return ["‎" + text.slice(0, start), text.slice(start, end), text.slice(end)];
}

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

  // Search results are windowed: a project-wide query can return up to
  // SearchReplaceService::MAX_RESULTS (10_000) rows, and every row is five
  // elements, so rendering the list in full built ~50k nodes — enough to kill
  // the tab outright, and 92 ms of render for a mere 3_000 rows. Rows are a
  // fixed 22px, which is what makes the arithmetic here as simple as the file
  // tree's. The results are a VS Code-style tree — a header row per file, its
  // matches nested under it — but header and match rows are deliberately the
  // *same* height (.search-result-file-row and .search-result-item both pin
  // it), so the flattened row array still windows by plain multiplication.
  // Give the two rows different heights and every offset here is wrong.
  var SEARCH_ROW_HEIGHT = 22;
  var SEARCH_ROW_BUFFER = 5;

  // File paths whose match list is folded away. Keyed by path, so a file that
  // scrolls out of the window keeps its state.
  var _useStateSC = useState({});
  var _useStateSC2 = _slicedToArray(_useStateSC, 2);
  var searchCollapsedFiles = _useStateSC2[0];
  var setSearchCollapsedFiles = _useStateSC2[1];
  var toggleSearchFile = function toggleSearchFile(file) {
    setSearchCollapsedFiles(function (prev) {
      var next = Object.assign({}, prev);
      if (next[file]) delete next[file]; else next[file] = true;
      return next;
    });
  };
  var _useStateSV = useState({ scrollTop: 0, height: 0 });
  var _useStateSV2 = _slicedToArray(_useStateSV, 2);
  var searchViewport = _useStateSV2[0];
  var setSearchViewport = _useStateSV2[1];

  // The container's height is only known once it is on screen, and a viewport
  // of 0 would render a single row and never grow — nothing would scroll, so
  // no scroll event would arrive to correct it.
  //
  // Measured from a callback ref rather than an effect: the results list
  // mounts and unmounts as the sidebar tab changes and as a query goes from
  // no-results to results, none of which an effect's dependency list sees.
  // Same reason the model graph wires its pan/zoom this way.
  var searchViewportObserverRef = useRef(null);
  var measureSearchViewport = function measureSearchViewport(el) {
    if (!el) return;
    setSearchViewport(function (prev) {
      if (prev.height === el.clientHeight && prev.scrollTop === el.scrollTop) return prev;
      return { scrollTop: el.scrollTop, height: el.clientHeight };
    });
  };
  var attachSearchResults = useRef(function (el) {
    if (searchViewportObserverRef.current) {
      searchViewportObserverRef.current.disconnect();
      searchViewportObserverRef.current = null;
    }
    searchResultsContainerRef.current = el;
    if (!el) return;
    measureSearchViewport(el);
    if (typeof ResizeObserver === 'undefined') return;
    var obs = new ResizeObserver(function () { measureSearchViewport(el); });
    obs.observe(el);
    searchViewportObserverRef.current = obs;
  }).current;

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

  // Ref mirrors for use inside long-lived event handlers registered with
  // empty-dependency effects (live search refresh on files_changed).
  var searchPanelVisibleRef = useRef(false);
  searchPanelVisibleRef.current = !sidebarCollapsed && activeSidebarTab === 'search';

  // Whether the server can run the save-time babel syntax check
  // (host-provided mini_racer + babel-standalone; see /workspace payload).
  var jsSyntaxCheckAvailableRef = useRef(false);

  var _useStateRFMap = useState({});
  var _useStateRFMap2 = _slicedToArray(_useStateRFMap, 2);
  var railsFilesMap = _useStateRFMap2[0];
  var setRailsFilesMap = _useStateRFMap2[1];

  var _useStateRFC = useState({});
  var _useStateRFC2 = _slicedToArray(_useStateRFC, 2);
  var railsGroupsCollapsed = _useStateRFC2[0];
  var setRailsGroupsCollapsed = _useStateRFC2[1];

  var _useStateChangelog = useState(null); // null | { content, loading, error }
  var _useStateChangelog2 = _slicedToArray(_useStateChangelog, 2);
  var changelogState = _useStateChangelog2[0];
  var setChangelogState = _useStateChangelog2[1];

  var _useStateSchemaModal = useState(null);
  var _useStateSchemaModal2 = _slicedToArray(_useStateSchemaModal, 2);
  var schemaModal = _useStateSchemaModal2[0];
  var setSchemaModal = _useStateSchemaModal2[1];

  var _useStateImportConflict = useState(null);
  var _useStateImportConflict2 = _slicedToArray(_useStateImportConflict, 2);
  var importConflict = _useStateImportConflict2[0];
  var setImportConflict = _useStateImportConflict2[1];

  // { initialFolder } while the upload dialog is open, null otherwise.
  var _useStateImportDialog = useState(null);
  var _useStateImportDialog2 = _slicedToArray(_useStateImportDialog, 2);
  var importDialog = _useStateImportDialog2[0];
  var setImportDialog = _useStateImportDialog2[1];

  var _useStateSchemaLoading = useState(null);
  var _useStateSchemaLoading2 = _slicedToArray(_useStateSchemaLoading, 2);
  var schemaLoadingLabel = _useStateSchemaLoading2[0];
  var setSchemaLoadingLabel = _useStateSchemaLoading2[1];

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

  var _useStateLog = useState(false);
  var _useStateLog2 = _slicedToArray(_useStateLog, 2);
  var showLogPanel = _useStateLog2[0];
  var setShowLogPanel = _useStateLog2[1];

  var _useStateProblems = useState(false);
  var _useStateProblems2 = _slicedToArray(_useStateProblems, 2);
  var showProblemsPanel = _useStateProblems2[0];
  var setShowProblemsPanel = _useStateProblems2[1];

  // Error/warning tallies across the open tabs, mirrored into the status bar.
  var _useStateProblemCounts = useState({ errors: 0, warnings: 0 });
  var _useStateProblemCounts2 = _slicedToArray(_useStateProblemCounts, 2);
  var problemCounts = _useStateProblemCounts2[0];
  var setProblemCounts = _useStateProblemCounts2[1];

  // Below this the toolbar's labelled buttons no longer fit beside the title
  // and the file search, and start pushing each other out of the bar.
  var TOOLBAR_LABEL_MIN_WIDTH = 1180;

  // matchMedia rather than a resize listener: the browser only tells us when
  // the answer actually changes, so there is nothing to throttle.
  var _useStateNarrow = useState(function () {
    return typeof window.matchMedia === 'function' &&
      window.matchMedia('(max-width: ' + TOOLBAR_LABEL_MIN_WIDTH + 'px)').matches;
  });
  var _useStateNarrow2 = _slicedToArray(_useStateNarrow, 2);
  var narrowToolbar = _useStateNarrow2[0];
  var setNarrowToolbar = _useStateNarrow2[1];

  useEffect(function () {
    if (typeof window.matchMedia !== 'function') return;
    var mq = window.matchMedia('(max-width: ' + TOOLBAR_LABEL_MIN_WIDTH + 'px)');
    var onChange = function (e) { setNarrowToolbar(e.matches); };
    setNarrowToolbar(mq.matches);
    // addEventListener on MediaQueryList is the modern spelling; addListener
    // is kept for older Safari, which mbeditor still runs in.
    if (mq.addEventListener) mq.addEventListener('change', onChange);
    else mq.addListener(onChange);
    return function () {
      if (mq.removeEventListener) mq.removeEventListener('change', onChange);
      else mq.removeListener(onChange);
    };
  }, []);

  // Model graph. Built lazily — generating it eager-loads the host app — and
  // only when the Models tab is opened.
  var _useStateModelGraph = useState(null);
  var _useStateModelGraph2 = _slicedToArray(_useStateModelGraph, 2);
  var modelGraph = _useStateModelGraph2[0];
  var setModelGraph = _useStateModelGraph2[1];

  var _useStateModelGraphLoading = useState(false);
  var _useStateModelGraphLoading2 = _slicedToArray(_useStateModelGraphLoading, 2);
  var modelGraphLoading = _useStateModelGraphLoading2[0];
  var setModelGraphLoading = _useStateModelGraphLoading2[1];

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

  // Icon-only toolbar: on by preference, or automatically once the window is
  // too narrow for the labels to fit beside the title and file search.
  var toolbarIconOnly = editorPrefs.toolbarIconOnly || narrowToolbar;

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
  var ctrlWPendingRef = useRef(false);
  var ctrlWTimeoutRef = useRef(null);
  var _useStateCP = useState([]);
  var _useStateCP2 = _slicedToArray(_useStateCP, 2);
  var customPaths = _useStateCP2[0];
  var setCustomPaths = _useStateCP2[1];
  var customPathsRef = useRef([]);
  customPathsRef.current = customPaths;
  // Whether to show the presence chips at all. Read at render rather than held in
  // state: cable availability changes on handshake and on every reconnect, so a
  // stored copy is stale the moment it is written. This only decides whether a
  // chip paints — the protocol itself is gated on the roster.
  var collabEnabled = typeof WebSocketService !== 'undefined' &&
    typeof WebSocketService.isCableAvailable === 'function' &&
    WebSocketService.isCableAvailable();
  var _useStateIdent = useState(
    typeof CollaborationIdentity !== 'undefined' ? CollaborationIdentity.get() : null
  );
  var _useStateIdent2 = _slicedToArray(_useStateIdent, 2);
  var collabIdentity = _useStateIdent2[0];
  var setCollabIdentity = _useStateIdent2[1];
  // Presence roster: other connected participants, keyed by client_id →
  // { name, colour, current_file }. Fed by the global presence stream; rendered
  // as click-to-jump chips in the status bar.
  var _useStateRoster = useState({});
  var _useStateRoster2 = _slicedToArray(_useStateRoster, 2);
  var collabRoster = _useStateRoster2[0];
  var setCollabRoster = _useStateRoster2[1];

  // Follow mode (slice 8): the presence client_id of the participant whose file +
  // viewport we're tracking, or null when navigating independently. Toggled from a
  // roster chip. The file-open is driven by the effect below; the scroll-tracking
  // lives in CollaborationService.setFollow().
  var _useStateFollow = useState(null);
  var _useStateFollow2 = _slicedToArray(_useStateFollow, 2);
  var followedClientId = _useStateFollow2[0];
  var setFollowedClientId = _useStateFollow2[1];
  var recentSavesRef = useRef({});
  var isSavingRef = useRef(false);
  // True once the saved session has finished loading into the panes. Anything
  // that opens a tab on startup must wait for this, or the restore overwrites it.
  var _useStateSR = useState(false);
  var _useStateSR2 = _slicedToArray(_useStateSR, 2);
  var sessionRestored = _useStateSR2[0];
  var setSessionRestored = _useStateSR2[1];
  var pendingChangelogRef = useRef(false);
  // path -> the file's content as last seen ON DISK (newline-normalised).
  // External-change detection compares disk-to-disk; comparing disk to the
  // buffer flags every dirty tab, which is just the definition of "dirty".
  var lastDiskContentRef = useRef({});

  // Every successful save must go through this. Besides the 3.5s grace window
  // that stops the external-change check racing our own write, a save defines
  // the new on-disk truth — so it must also refresh the external-change
  // baseline. The check's own fetch is skipped inside the grace window, so
  // without this the baseline stayed at the *pre-save* disk content and the
  // next files_changed push reported our own save as an external edit on any
  // tab the user had started editing again.
  function noteLocalSave(path, content) {
    recentSavesRef.current[path] = Date.now();
    setTimeout(function () { delete recentSavesRef.current[path]; }, 3500);
    if (typeof content === 'string') {
      lastDiskContentRef.current[path] = content.replace(/\r\n/g, '\n');
    }
    // The file on disk just moved, so any line-diff answer we are holding for
    // it predates the write and must not be reused for the tint.
    if (typeof GitService !== 'undefined' && GitService.invalidateLineDiff) {
      GitService.invalidateLineDiff(path);
    }
  }

  // ── Draft backup helpers ─────────────────────────────────────────────────
  var draftWriteTimerRef = useRef({});
  var serverOnlineRef = useRef(true);

  var _draftKey = function _draftKey(path) {
    var base = typeof window.mbeditorBasePath === 'function' ? window.mbeditorBasePath() : '';
    return 'mbeditor_draft\x00' + base + '\x00' + path;
  };
  var _saveDraftNow = function _saveDraftNow(path, content) {
    var doWrite = function() {
      try { localStorage.setItem(_draftKey(path), JSON.stringify({ content: content, ts: Date.now() })); } catch (e) {}
    };
    if (typeof requestIdleCallback !== 'undefined') {
      requestIdleCallback(doWrite, { timeout: 2000 });
    } else {
      doWrite();
    }
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

  var _useStateSB = useState(false);
  var _useStateSB2 = _slicedToArray(_useStateSB, 2);
  var isSwitchingBranch = _useStateSB2[0];
  var setIsSwitchingBranch = _useStateSB2[1];

  var clamp = function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  };

  var filterDotFiles = function filterDotFiles(nodes) {
    return nodes.filter(function(n) { return n.name[0] !== '.'; }).map(function(n) {
      return n.children ? Object.assign({}, n, { children: filterDotFiles(n.children) }) : n;
    });
  };

  // filterDotFiles rebuilds the whole tree, so calling it inline in the render
  // handed FileTreeMemo a fresh array every time and its `prev.items ===
  // next.items` check never held — the memo was there but never fired.
  var fileTreeItems = useMemo(function () {
    return editorPrefs.showDotFiles ? treeData : filterDotFiles(treeData || []);
  }, [treeData, editorPrefs.showDotFiles]);

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

  // Every structural mutation (create, delete, rename, import) funnels through
  // here, so this is where the project-search cache has to be dropped. Saves
  // invalidated it at their own call sites, which is why editing a file
  // updated the results but adding or deleting one never did — the stale
  // cached page was served for the same query. The per-path delta refresh on
  // the files_changed push can't cover it either: it re-scans named files,
  // and a file that just appeared or vanished isn't in the previous result set.
  // True when the server will push a files_changed broadcast for a write we are
  // about to make, so the coalesced handler will refresh the tree and git for
  // us. Every mutation used to refresh both itself as well, which doubled or
  // tripled the most expensive requests the editor makes. Without a socket
  // nothing arrives, so callers keep their own refresh for that case.
  var _socketWillBroadcast = function _socketWillBroadcast() {
    return typeof WebSocketService !== 'undefined' &&
      typeof WebSocketService.isCableAvailable === 'function' &&
      WebSocketService.isCableAvailable();
  };

  var refreshProjectTree = function refreshProjectTree() {
    return FileService.getTree().then(function (data) {
      // _treeUpdater keeps the previous array (and skips the index rebuild)
      // when the tree is unchanged; going round it re-rendered the whole app.
      setTreeData(_treeUpdater(data || []));
      SearchService.invalidate();
      if (searchQueryRef.current && searchPanelVisibleRef.current) {
        _debouncedSearch(searchQueryRef.current);
      }
      return data || [];
    })["catch"](function (err) {
      EditorStore.setStatus("Failed to refresh files: " + (err && err.message || "Unknown error"), "error");
      return [];
    });
  };

  var isRubyPath = function isRubyPath(path) {
    return path && (path.endsWith('.rb') || path.endsWith('.gemspec') || path.endsWith('Rakefile') || path.endsWith('Gemfile'));
  };

  // editor_plugins.js owns the ruby-lsp health flags; this app never writes
  // them directly. Tolerates the plugins file not having loaded yet.
  var noteLspFailure = function noteLspFailure(err) {
    if (window.MbeditorEditorPlugins && MbeditorEditorPlugins.noteLspFailure) {
      MbeditorEditorPlugins.noteLspFailure(err);
    }
  };

  // Opens the schema modal for a model. Shared by the Rails panel's schema
  // button and the model diagram, so both show the same thing.
  var openSchemaModal = function openSchemaModal(label) {
    if (schemaLoadingLabel === label) return;
    setSchemaLoadingLabel(label);
    FileService.getModelSchema(label.replace(/\s+/g, '')).then(function (data) {
      setSchemaLoadingLabel(null);
      setSchemaModal(data && data.columns
        ? { label: label, data: data }
        : { label: label, error: 'No schema found for ' + label });
    })["catch"](function (err) {
      setSchemaLoadingLabel(null);
      var msg = (err && err.response && err.response.data && err.response.data.error) ||
        'No db/schema.rb found or table not defined';
      setSchemaModal({ label: label, error: msg });
    });
  };

  // The server caches on a fingerprint of app/models and db/migrate mtimes, so
  // re-requesting on every tab visit is cheap and picks up a saved model or a
  // new migration without any invalidation wiring here.
  var loadModelGraph = function loadModelGraph(force) {
    if (!FileService.getModelGraph) return;
    setModelGraphLoading(true);
    FileService.getModelGraph(force).then(function (data) {
      setModelGraph(data);
    })["catch"](function (err) {
      setModelGraph({
        ok: false,
        error: (err && err.response && err.response.data && err.response.data.error) ||
          'Could not load the model graph.'
      });
    })["finally"](function () { setModelGraphLoading(false); });
  };

  useEffect(function () {
    if (activeSidebarTab !== 'models' || sidebarCollapsed) return;
    loadModelGraph(false);
  }, [activeSidebarTab, sidebarCollapsed]);

  // The one writer for the markers map. Two things it must not do:
  //
  //   * write a fresh map when nothing changed — the auto-lint fires per
  //     keystroke on JS files and re-clearing an already-empty marker list
  //     would re-render the whole app every time;
  //   * mutate the tab object in the store — EditorStore's contract is that
  //     every nested value is replaced, never edited in place, or
  //     subscribeToSlice cannot see the change. TabBar reads this map instead.
  var applyMarkersForTab = function applyMarkersForTab(tabId, nextMarkers) {
    setMarkers(function (prev) {
      var cur = prev[tabId];
      if (cur && cur.length === 0 && nextMarkers.length === 0) return prev;
      return _extends({}, prev, _defineProperty({}, tabId, nextMarkers));
    });
  };

  var runRubyLint = function runRubyLint(tab, paneId) {
    var options = arguments.length <= 2 || arguments[2] === undefined ? {} : arguments[2];

    if (!tab || (!isRubyPath(tab.path) && !tab.path.endsWith('.haml'))) return Promise.resolve(null);

    // An empty buffer has no offenses, and answering that here rather than over
    // the wire skips the most expensive request the Ruby path makes: a
    // whole-document RuboCop run, budgeted at 10s server-side. It matters
    // because every newly created .rb file starts empty and is opened
    // immediately, so the lint fired on a document with nothing in it.
    // Resolving with an empty marker set (rather than null) keeps the
    // marker-clearing below intact, so deleting a file's contents still clears
    // its squiggles.
    if (!String(tab.content || '').trim()) {
      applyMarkersForTab(tab.id, []);
      if (options.showStatus) EditorStore.setStatus('No RuboCop offenses!', 'success');
      return Promise.resolve({ markers: [] });
    }

    if (options.showLoading) {
      setLoading(function (prev) {
        return _extends({}, prev, { lint: true });
      });
    }
    if (options.showStatus) {
      EditorStore.setStatus('Linting...', 'info');
    }

    // ruby-lsp answers diagnostics for Ruby files when it's available: same
    // markers, plus Prism syntax errors, without a per-keystroke rubocop boot.
    // Anything short of a usable answer falls through to the HTTP lint for
    // this call, so behaviour without ruby-lsp is unchanged.
    var lintRequest;
    var lspUsable = window.MBEDITOR_RUBY_LSP_AVAILABLE &&
      !(window.MbeditorEditorPlugins && MbeditorEditorPlugins.lspBackedOff());
    if (lspUsable && isRubyPath(tab.path) && FileService.lspDiagnostics) {
      lintRequest = FileService.lspDiagnostics(tab.path, tab.content).then(function (res) {
        if (res && res.markers && !res.fallback && !res.error) return res;
        noteLspFailure({ lspData: res || {} });
        return FileService.lintFile(tab.path, tab.content);
      })["catch"](function (err) {
        noteLspFailure(err);
        return FileService.lintFile(tab.path, tab.content);
      });
    } else {
      lintRequest = FileService.lintFile(tab.path, tab.content);
    }

    return lintRequest.then(function (res) {
      var nextMarkers = res.markers || [];
      applyMarkersForTab(tab.id, nextMarkers);

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

    var parserName = prettierParserFor(tab.path);

    if (parserName && window.prettier && window.prettierPlugins) {
      var prefs = EditorStore.getState().editorPrefs || DEFAULT_EDITOR_PREFS;
      window.prettier.format(tab.content, prettierOptions(prefs, parserName)).then(function () {
        applyMarkersForTab(tab.id, []);
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
        applyMarkersForTab(tab.id, newMarkers);
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
      if (workspace && typeof workspace.jsSyntaxCheckAvailable === 'boolean') {
        jsSyntaxCheckAvailableRef.current = workspace.jsSyntaxCheckAvailable;
      }
      if (workspace && typeof workspace.rubyLspAvailable === 'boolean') {
        window.MBEDITOR_RUBY_LSP_AVAILABLE = workspace.rubyLspAvailable;
      }
      if (workspace && typeof workspace.gitAvailable === 'boolean') {
        setGitAvailable(workspace.gitAvailable);
      }
      if (workspace && typeof workspace.redmineEnabled === 'boolean') {
        setRedmineEnabled(workspace.redmineEnabled);
      }
      if (workspace && workspace.testTimeout) {
        FileService.setTestTimeout(workspace.testTimeout);
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
        if (t.isChangelog || t.path === 'mbeditor://changelog') {
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
        if (t.isModelGraph || t.path === 'mbeditor://model-graph') {
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
          // Drop duplicate file tabs within a pane — a single file must never
          // appear twice in the same pane. A race between persisted state and an
          // in-flight reopen can otherwise rebuild the pane with the same path
          // twice (the "duplicated file twice over" symptom). Only plain file
          // tabs are de-duplicated by path; diff/preview/settings/changelog tabs
          // encode their identity elsewhere and are left untouched. resIdx is
          // advanced for every original tab so it stays aligned with `results`.
          var seenPaths = {};
          var tabs = [];
          p.tabs.forEach(function (t) {
            var res = results[resIdx++];
            var isPlainFile = t.path && !t.isDiff && !t.isCombinedDiff && !t.isSettings &&
              !t.isChangelog && !t.isPreview && !t.isModelGraph &&
              !/^(diff|combined-diff):\/\//.test(t.path) && !/::preview$/.test(t.path);
            if (isPlainFile) {
              if (seenPaths[t.path]) return;
              seenPaths[t.path] = true;
            }
            tabs.push(_extends({}, t, {
              content: res.content,
              externalContentVersion: (t.externalContentVersion || 0) + 1
            },
            // A state saved before this tab type existed carries the path but
            // not the flag, and would restore as a missing file.
            t.path === 'mbeditor://model-graph' ? { isModelGraph: true } : {},
            res._isDiffResult ? { diffOriginal: res.diffOriginal, diffModified: res.diffModified } : {},
            typeof res.fileNotFound === 'boolean' ? { fileNotFound: res.fileNotFound, dirty: res.fileNotFound ? false : t.dirty } : {},
            res.image === true ? { isImage: true } : {}));
          });
          // If activeTabId pointed at a dropped duplicate, fall back to the first tab.
          var activeStillPresent = tabs.some(function (t) { return t.id === p.activeTabId; });
          return _extends({}, p, {
            tabs: tabs,
            activeTabId: activeStillPresent ? p.activeTabId : ((tabs[0] && tabs[0].id) || null)
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
    })["catch"](function () { /* fall through to marking restore done */ })
      .then(function () { setSessionRestored(true); });

    // Watch for git branch changes and swap per-branch tab state
    var unsubBranch = EditorStore.subscribeToSlice(['gitBranch'], function (st) {
      var newBranch = st.gitBranch;
      var oldBranch = prevGitBranchRef.current;
      if (!newBranch || newBranch === oldBranch) return;
      prevGitBranchRef.current = newBranch;
      if (!oldBranch || isSwitchingBranchRef.current) return;
      // Ignore spurious branch changes triggered by saves (race condition)
      if (isSavingRef.current) return;

      // Never auto-swap per-branch tab state while there are unsaved edits. The
      // swap clears every pane and reloads each tab's content from disk, which
      // would silently discard in-progress work — the "reverts changes
      // completely" symptom, now triggered more often by the periodic git
      // status poll picking up external branch changes. Keep the current tabs
      // and edits in place; the new branch's saved layout loads on the next
      // switch once the work is saved.
      var hasUnsavedEdits = (EditorStore.getState().panes || []).some(function (p) {
        return (p.tabs || []).some(function (t) { return t.dirty; });
      });
      if (hasUnsavedEdits) return;

      isSwitchingBranchRef.current = true;
      setIsSwitchingBranch(true);

      var shouldRestore = (EditorStore.getState().editorPrefs || {}).branchStateRestore !== false;

      if (shouldRestore) {
        // Save pane state for old branch before switching
        var cur = EditorStore.getState();
        var lightweightPanes = cur.panes.map(function (p) {
          return {
            id: p.id,
            activeTabId: p.activeTabId,
            tabs: p.tabs.filter(function (t) { return !t.isCombinedDiff && !t.isModelGraph && !t.isUntitled; }).map(function (t) {
              return {
                id: t.id, path: t.path, name: t.name, dirty: t.dirty, viewState: t.viewState,
                isSettings: !!t.isSettings, isPreview: !!t.isPreview, previewFor: t.previewFor || null,
                isDiff: !!t.isDiff, diffBaseSha: t.diffBaseSha || null, diffHeadSha: t.diffHeadSha || null,
                repoPath: t.repoPath || null, isChangelog: !!t.isChangelog
              };
            })
          };
        });
        FileService.saveBranchState(oldBranch, { panes: lightweightPanes, focusedPaneId: cur.focusedPaneId })["catch"](function () {});
      }

      // Clear all open tabs for the new branch
      EditorStore.setState({
        panes: [{ id: 1, tabs: [], activeTabId: null }, { id: 2, tabs: [], activeTabId: null }],
        focusedPaneId: 1,
        activeTabId: null
      });

      // Load pane state for new branch (or start empty)
      var restorePromise;
      if (shouldRestore) {
        restorePromise = FileService.getBranchState(newBranch)["catch"](function () { return null; }).then(function (branchState) {
          var hasBranchPanes = branchState && branchState.panes && branchState.panes.some(function (p) { return p.tabs && p.tabs.length > 0; });
          if (hasBranchPanes) {
            return loadPaneState(branchState.panes, branchState.focusedPaneId || 1);
          }
          return null;
        });
      } else {
        restorePromise = Promise.resolve(null);
      }

      restorePromise.then(function () {
        // Prune states for deleted branches
        FileService.pruneBranchStates()["catch"](function () {});
        isSwitchingBranchRef.current = false;
        setIsSwitchingBranch(false);
      })["catch"](function () {
        isSwitchingBranchRef.current = false;
        setIsSwitchingBranch(false);
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
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && (e.key === 'L' || e.key === 'l')) {
        e.preventDefault();
        setShowLogPanel(function (prev) { return !prev; });
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
          var nextWidth = clientX - rect.left - SIDEBAR_COLLAPSED_WIDTH;
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

    // Capture-phase listener for vim Ctrl+W window navigation.
    // Runs before Monaco (and the browser) so neither can swallow the keystrokes.
    // Phase 1 — Ctrl+W: prevent tab-close and arm the pending flag.
    // Phase 2 — next key: act on it here (still capture phase) so Monaco-vim
    //   cannot consume it as a word-motion or other binding.
    var onCtrlWCapture = function(e) {
      // Phase 2: a previous Ctrl+W is pending — consume the follow-up key.
      if (ctrlWPendingRef.current) {
        ctrlWPendingRef.current = false;
        if (ctrlWTimeoutRef.current) { clearTimeout(ctrlWTimeoutRef.current); ctrlWTimeoutRef.current = null; }
        var _st = EditorStore.getState();
        var _cur = _st.focusedPaneId;
        var _target;
        if (e.key === '1') _target = 1;
        else if (e.key === '2') _target = 2;
        else if (e.key === 'h') _target = 1;
        else _target = _cur === 1 ? 2 : 1; // w, l, Ctrl+W, or anything else → cycle
        if (_target !== _cur) {
          if (typeof TabManager !== 'undefined') TabManager.focusPane(_target);
          window.dispatchEvent(new CustomEvent('mbeditor:focusPane', { detail: { paneId: _target } }));
        }
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      // Phase 1: intercept Ctrl+W itself when vim mode is on.
      if (e.metaKey || e.shiftKey || e.altKey) return;
      if (!e.ctrlKey || (e.key !== 'w' && e.key !== 'W')) return;
      var prefs = EditorStore.getState().editorPrefs;
      if (!prefs || !prefs.vimMode) return;
      e.preventDefault();
      e.stopPropagation();
      if (ctrlWTimeoutRef.current) clearTimeout(ctrlWTimeoutRef.current);
      ctrlWPendingRef.current = true;
      ctrlWTimeoutRef.current = setTimeout(function() { ctrlWPendingRef.current = false; }, 1500);
    };

    // Capture-phase listener for Ctrl/Cmd+F. Monaco only intercepts Find while
    // the editor DOM node has focus (bubble phase); once focus leaves the editor
    // (e.g. clicking a tab) the browser's native Find takes over. This routes
    // Find back to the active editor unless the user is typing in another input
    // (sidebar search, rename box) or focus is already inside a Monaco editor.
    var onFindCapture = function(e) {
      if (!(e.ctrlKey || e.metaKey) || e.shiftKey || e.altKey) return;
      if (e.key !== 'f' && e.key !== 'F') return;
      var ed = window.__mbeditorActiveEditor;
      if (!ed) return;
      var ae = document.activeElement;
      if (ae && ae.closest) {
        // Already in a Monaco editor — let Monaco's own binding handle it.
        if (ae.closest('.monaco-editor')) return;
        // Don't hijack Find while typing in another input region.
        if (ae.closest('.ide-sidebar, .git-panel, .quick-open-overlay, .schema-modal, input, textarea, [contenteditable="true"]')) return;
      }
      e.preventDefault();
      e.stopPropagation();
      ed.focus();
      var action = ed.getAction && ed.getAction('actions.find');
      if (action) action.run();
    };

    window.addEventListener('keydown', onKeyDown);
    document.addEventListener('keydown', onZenCapture, true);
    document.addEventListener('keydown', onCtrlWCapture, true);
    document.addEventListener('keydown', onFindCapture, true);
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
      if (ctrlWTimeoutRef.current) { clearTimeout(ctrlWTimeoutRef.current); ctrlWTimeoutRef.current = null; }
      window.removeEventListener('keydown', onKeyDown);
      document.removeEventListener('keydown', onZenCapture, true);
      document.removeEventListener('keydown', onCtrlWCapture, true);
      document.removeEventListener('keydown', onFindCapture, true);
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

  // Live search-result refresh: when a save/rename/delete broadcast names the
  // changed files and the search panel is showing results, re-scan just those
  // files and splice their rows in place. Debounced so keystroke-saves don't
  // spam single-file scans; paths accumulate across the debounce window.
  var _pendingSearchRefreshPaths = useRef(new Set());
  var _flushSearchRefresh = useRef(window._.debounce(function () {
    var q = searchQueryRef.current;
    var paths = Array.from(_pendingSearchRefreshPaths.current);
    _pendingSearchRefreshPaths.current.clear();
    if (!q || !searchPanelVisibleRef.current || paths.length === 0) return;
    var opts = { regex: searchUseRegexRef.current, matchCase: searchMatchCaseRef.current, wholeWord: searchWholeWordRef.current };
    paths.reduce(function (chain, p) {
      return chain.then(function () {
        return SearchService.refreshFile(q, p, opts).then(function (delta) {
          var diff = delta.added - delta.removed;
          if (diff !== 0) {
            setSearchTotalCount(function (prev) { return Math.max(0, (prev || 0) + diff); });
          }
        });
      });
    }, Promise.resolve());
    // 250ms, not 2s. The window only exists to coalesce the paths from a
    // burst of saves; anything longer is dead time the user spends looking at
    // stale search rows, and the server-side result cache was already dropped
    // by the same broadcast, so waiting buys nothing.
  }, 250)).current;

  // WebSocket push — when the server broadcasts files_changed, refresh the tree
  // and git status immediately (same work as the 10s poll below does).
  useEffect(function () {
    // One broadcast per written file, so a bulk write (Save All, Format All,
    // a drag-and-drop import, a rename) used to cost one full tree walk and
    // one git status PER FILE, all in flight at once. On a real host repo
    // those are the two most expensive requests the editor makes, and with
    // the browser's six sockets per host the saves themselves ended up queued
    // behind their own fallout — past ~30 files the POSTs hit the 30 s axios
    // timeout and Save All reported failure for writes that had succeeded.
    // The refresh is idempotent, so a burst only needs one of each.
    var timer = null;
    var pendingPaths = [];
    var pendingFullCheck = false;
    var pendingStructural = false;

    function flush() {
      timer = null;
      // The named paths and "re-check everything" are two separate questions.
      // Collapsing them lost the paths whenever a path-less broadcast (a new
      // directory, say) landed in the same window as a save, and the saved
      // file's search rows then stayed stale until the next edit.
      var paths = pendingPaths;
      var fullCheck = pendingFullCheck;
      var structural = pendingStructural;
      pendingPaths = [];
      pendingFullCheck = false;
      pendingStructural = false;
      var tabsToCheck = (fullCheck || paths.length === 0) ? null : paths;
      // The cheap /git_status probe, not the full /git_info fan-out. This
      // fires on every save, and the fan-out is the most expensive request
      // the editor makes — on a dev server with a handful of threads it
      // queues the tree and search requests behind itself, which is what made
      // search look like it was waiting for git. fetchStatusLite patches the
      // branch and file list immediately and escalates to the fan-out on its
      // own when the branch actually changed.
      GitService.fetchStatusLite({ background: true })["catch"](function () {});

      // A save changes a file's contents, not the shape of the workspace, so
      // there is nothing in the tree for it to invalidate: the names, the
      // nesting and the quick-open index are all exactly as they were. Walking
      // the whole workspace to learn that — and then rebuilding the MiniSearch
      // index from the result, because the file's byte count moved and made
      // the payload compare unequal — was pure cost on the save path, and it
      // grew with the size of the checkout rather than with the edit.
      // Git badges come from git_status above, not from this payload.
      if (structural) {
        FileService.getTree().then(function (data) {
          setTreeData(_treeUpdater(data || []));
          checkOpenTabsForExternalChanges(tabsToCheck);
        })["catch"](function () {});
      } else {
        checkOpenTabsForExternalChanges(tabsToCheck);
      }

      if (paths.length && searchQueryRef.current && searchPanelVisibleRef.current) {
        paths.forEach(function (p) { _pendingSearchRefreshPaths.current.add(p); });
        _flushSearchRefresh();
      }
    }

    function handleFilesChanged(payload) {
      if (document.hidden) return;
      // No paths named means "something changed, re-check everything" — it
      // must not be swallowed by a burst that did name paths.
      if (!payload || !payload.paths) pendingFullCheck = true;
      else pendingPaths = pendingPaths.concat(payload.paths);
      // Absent (an older server) counts as structural — the conservative read.
      if (!payload || payload.structural !== false) pendingStructural = true;
      if (timer) return;
      timer = setTimeout(flush, 200);
    }
    // Deferring the refresh means it can now come due after the page has begun
    // going away. Requests issued into a closing page are aborted mid-flight,
    // which wastes a tree walk and leaves the server holding a connection that
    // never completes.
    var cancelPending = function () {
      if (timer) clearTimeout(timer);
      timer = null;
    };
    window.addEventListener('pagehide', cancelPending);

    WebSocketService.onFilesChanged(handleFilesChanged);
    return function () {
      cancelPending();
      window.removeEventListener('pagehide', cancelPending);
      WebSocketService.offFilesChanged(handleFilesChanged);
    };
  }, []);

  // A branch switch changes every tracked file at once, and no push announces
  // it — the broadcast only covers mbeditor's own writes. Re-read the tree and
  // every open tab, the same work a manual workspace refresh does. Clean tabs
  // take the new branch's content; dirty ones queue the usual reload prompt,
  // so unsaved work is never overwritten.
  useEffect(function () {
    function onBranchChanged() {
      SearchService.invalidate();
      FileService.getTree({ refresh: true }).then(function (data) {
        setTreeData(_treeUpdater(data || []));
      })["catch"](function () {})["finally"](function () {
        checkOpenTabsForExternalChanges();
      });
    }
    window.addEventListener('mbeditor:branch-changed', onBranchChanged);
    return function () { window.removeEventListener('mbeditor:branch-changed', onBranchChanged); };
  }, []);

  // WebSocket push — when a peer saves a collaboratively-bound file, the CRDT has
  // already kept our buffer byte-identical, so the single on-disk write is enough
  // for everyone. Reset that tab's clean baseline and clear its dirty indicator
  // without touching disk or undo history. Gated on the file being collab-bound:
  // for non-collab tabs a peer's save is an external change handled by the
  // files_changed path above (which respects local unsaved edits).
  useEffect(function () {
    function handleFileSaved(data) {
      var path = data && data.path;
      if (!path) return;
      if (typeof CollaborationService === 'undefined' || !CollaborationService.isBound(path)) return;

      var st = EditorStore.getState();
      var changed = false;
      var newPanes = st.panes.map(function (p) {
        return Object.assign({}, p, {
          tabs: p.tabs.map(function (t) {
            if (t.path !== path || !t.dirty) return t;
            changed = true;
            return Object.assign({}, t, { dirty: false, cleanContent: t.content });
          })
        });
      });
      if (changed) EditorStore.setState({ panes: newPanes });

      // The CRDT kept our buffer identical to what the peer just wrote, so the
      // buffer is the new on-disk truth — refresh the external-change baseline.
      var _savedTab = null;
      newPanes.forEach(function (p) {
        p.tabs.forEach(function (t) { if (t.path === path) _savedTab = t; });
      });
      if (_savedTab && typeof _savedTab.content === 'string') {
        lastDiskContentRef.current[path] = _savedTab.content.replace(/\r\n/g, '\n');
      }

      // Reset the AVI clean baseline so undo past this peer's save shows dirty correctly.
      var _modelEntry = window.__mbeditorModels && window.__mbeditorModels[path];
      if (_modelEntry && _modelEntry.model && !_modelEntry.model.isDisposed()) {
        _modelEntry.cleanVersionId = _modelEntry.model.getAlternativeVersionId();
      }
    }
    WebSocketService.onFileSaved(handleFileSaved);
    return function () { WebSocketService.offFileSaved(handleFileSaved); };
  }, []);

  // onlyPaths: when the trigger names the files that changed (the
  // files_changed push always does — it only ever announces mbeditor's own
  // writes), restrict the check to open tabs on those paths. The old
  // behaviour re-fetched EVERY open tab on every save: N requests per save,
  // and each one another chance for a stale comparison to cry "changed
  // externally". A manual workspace refresh passes nothing and still checks
  // everything — that is the button's job.
  function checkOpenTabsForExternalChanges(onlyPaths) {
    var pathSet = null;
    if (onlyPaths && onlyPaths.length) {
      pathSet = {};
      onlyPaths.forEach(function (p) { pathSet[p] = true; });
    }
    var st = EditorStore.getState();
    var allTabs = st.panes.reduce(function (acc, p) {
      return acc.concat(p.tabs.map(function (t) { return { paneId: p.id, tab: t }; }));
    }, []);
    var fileTabs = allTabs.filter(function (pt) {
      var path = pt.tab.path || '';
      if (pathSet && !pathSet[path]) return false;
      return path &&
        !path.startsWith('mbeditor://') &&
        !path.startsWith('diff://') &&
        !path.startsWith('combined-diff://') &&
        !path.startsWith('untitled://') &&
        !pt.tab.isCombinedDiff &&
        !pt.tab.isSettings &&
        !pt.tab.isImage &&
        !pt.tab.isDiff &&
        typeof pt.tab.content === 'string';
    });
    fileTabs.forEach(function (pt) {
      var savedAt = recentSavesRef.current[pt.tab.path];
      if (savedAt && Date.now() - savedAt < 3000) return;
      // A collaboratively-bound file's live buffer is the shared CRDT, kept
      // converged across peers and reconciled with disk on save (file_saved).
      // Re-applying an external on-disk snapshot over it would silently clobber
      // everyone's shared state, so skip detection here — the CRDT is authoritative
      // while peers are editing. Intentional local edits (Format/Load) still flow
      // through the binding and are unaffected.
      if (typeof CollaborationService !== 'undefined' &&
          CollaborationService.isAttached(pt.tab.path)) {
        return;
      }
      FileService.getFile(pt.tab.path, { allowMissing: true }).then(function (data) {
        if (!data || typeof data.content !== 'string') return;
        // Re-read the tab: the snapshot above predates the fetch, and edits or
        // a save that landed meanwhile would make a stale comparison here
        // report phantom external changes.
        var liveState = EditorStore.getState();
        var livePane = liveState.panes.find(function (p) { return p.id === pt.paneId; });
        var liveTab = livePane && livePane.tabs.find(function (t) { return t.id === pt.tab.id; });
        if (!liveTab || liveTab.path !== pt.tab.path) return;
        var savedAgain = recentSavesRef.current[pt.tab.path];
        if (savedAgain && Date.now() - savedAgain < 3000) return;
        pt = { paneId: pt.paneId, tab: liveTab };
        var serverNorm = data.content.replace(/\r\n/g, '\n');
        var tabNorm = (pt.tab.content || '').replace(/\r\n/g, '\n');

        // Did the file on disk actually change? Compare disk against the last
        // disk content we saw, never against the buffer — a dirty buffer
        // differs from disk by definition, so the old comparison reported
        // every unsaved tab as "updated externally" whenever a files_changed
        // push arrived (which our own save of some *other* file triggers).
        // A clean tab's buffer IS the disk content, so it seeds the baseline;
        // a dirty tab with no baseline yet can't be judged, so record and wait.
        var prevDisk = lastDiskContentRef.current[pt.tab.path];
        lastDiskContentRef.current[pt.tab.path] = serverNorm;
        if (serverNorm === tabNorm) return;
        if (prevDisk === undefined && pt.tab.dirty) return;
        if (prevDisk === undefined) prevDisk = tabNorm;
        if (serverNorm === prevDisk) return;

        if (!pt.tab.dirty) {
          EditorStore.setState({
            panes: EditorStore.getState().panes.map(function (p) {
              if (p.id !== pt.paneId) return p;
              return Object.assign({}, p, {
                tabs: p.tabs.map(function (t) {
                  if (t.id !== pt.tab.id) return t;
                  return Object.assign({}, t, {
                    content: data.content,
                    externalContentVersion: (t.externalContentVersion || 0) + 1
                  });
                })
              });
            })
          });
          // The text just moved under the diagnostics. Only the mounted editor
          // re-lints, so without this a background tab kept reporting offenses
          // at line numbers the external write had shifted — and the Problems
          // panel and status-bar tallies reported them too. Dropping them says
          // "not known yet", which is true: the file re-lints when you open it.
          discardStaleMarkers(pt.tab.path);
        } else {
          // Re-verify the tab still exists before queuing
          var currentState = EditorStore.getState();
          var stillExists = currentState.panes.some(function (p) {
            return p.id === pt.paneId && p.tabs.some(function (t) { return t.id === pt.tab.id; });
          });
          if (!stillExists) return;
          var existing = EditorStore.getState().pendingReloads.find(function (r) {
            return r.paneId === pt.paneId && r.tabId === pt.tab.id;
          });
          if (!existing) {
            EditorStore.setState({
              pendingReloads: EditorStore.getState().pendingReloads.concat([{
                paneId: pt.paneId,
                tabId: pt.tab.id,
                path: pt.tab.path,
                name: pt.tab.name,
                serverContent: data.content
              }])
            });
          }
        }
      })["catch"](function () {});
    });
  }

  // Auto-refresh the file tree every 10s to pick up external changes (new files,
  // deletions, a branch switch in a terminal).
  //
  // This runs whether or not the WebSocket is connected. It used to skip when
  // connected, on the reasoning that the push covered it — but the server only
  // broadcasts from mbeditor's own mutation endpoints, so a connected socket
  // meant external changes were never picked up at all. The push remains the
  // instant path for our own writes; this is what catches everything else.
  // _treeUpdater keeps the previous array when nothing changed, so a quiet
  // workspace costs one fetch and no re-render at all.
  useEffect(function () {
    var intervalId = setInterval(function () {
      if (document.hidden) return;
      FileService.getTree({ background: true }).then(function (data) {
        setTreeData(_treeUpdater(data || []));
      }).catch(function () {}); // silently ignore auto-refresh errors
    }, 10000);
    return function () { clearInterval(intervalId); };
  }, []);

  // Git branch/status must be polled independently of the WebSocket. The WS only
  // broadcasts after mbeditor-initiated mutations, so an external `git checkout`
  // (e.g. switching branches in a terminal) is never pushed. Poll on a short
  // interval and refresh immediately when the tab regains focus so branch
  // changes are picked up promptly instead of requiring a manual git-panel reload.
  useEffect(function () {
    // Steady-state ticks use the cheap lite poll; it escalates to the full
    // /git_info fan-out on its own when the branch or working tree changed.
    var refresh = function () {
      if (document.hidden) return;
      GitService.fetchStatusLite({ background: true })["catch"](function () {});
    };
    // Regaining focus is a strong signal something may have happened in a
    // terminal meanwhile — do a full refresh (server-side cache bounds cost).
    var fullRefresh = function () {
      if (document.hidden) return;
      GitService.fetchStatus()["catch"](function () {});
    };
    var intervalId = setInterval(refresh, 5000);
    var onVisible = function () { if (!document.hidden) fullRefresh(); };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('focus', fullRefresh);
    return function () {
      clearInterval(intervalId);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', fullRefresh);
    };
  }, []);

  // Keep the status-bar error/warning tallies in step with Monaco's markers.
  // Every diagnostic source in the editor — rubocop, ruby-lsp, the TypeScript
  // worker — lands here, so one subscription covers all of them. Markers change
  // on every keystroke for JS, so the recount is debounced.
  useEffect(function () {
    if (!monacoReady || !window.monaco || !window.monaco.editor || !window.ProblemsPanel) return;

    var timer = null;
    var recount = function () {
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () {
        timer = null;
        var next = window.ProblemsPanel.counts();
        // Two object literals are never Object.is-equal, so handing React a
        // fresh {errors, warnings} re-rendered the app on every marker change
        // — which for a JS file is every keystroke. Compare the fields.
        setProblemCounts(function (prev) {
          return (prev && prev.errors === next.errors && prev.warnings === next.warnings) ? prev : next;
        });
      }, 250);
    };

    var sub = window.monaco.editor.onDidChangeMarkers(recount);
    recount();

    return function () {
      if (timer) clearTimeout(timer);
      sub.dispose();
    };
  }, [monacoReady]);

  var handleSelectFile = function handleSelectFile(path, name, line, col, endCol) {
    TabManager.openTab(path, name, line, null, false, col, endCol);
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

  // Both of these are keyed by something that dies with the tab — markers by
  // tab id, the external-change baseline by path — and nothing dropped them, so
  // a long session held a full copy of every file it had ever opened. Run after
  // a close (single or bulk) and reconcile against what is still open: a path
  // the other pane still shows keeps its baseline, which a per-tab delete
  // would have got wrong.
  var forgetClosedTabs = function forgetClosedTabs() {
    var openIds = {};
    var openPaths = {};
    EditorStore.getState().panes.forEach(function (p) {
      p.tabs.forEach(function (t) {
        openIds[t.id] = true;
        if (t.path) openPaths[t.path] = true;
      });
    });
    Object.keys(lastDiskContentRef.current).forEach(function (path) {
      if (!openPaths[path]) delete lastDiskContentRef.current[path];
    });
    setMarkers(function (prev) {
      var stale = Object.keys(prev).filter(function (id) { return !openIds[id]; });
      if (stale.length === 0) return prev;
      var next = _extends({}, prev);
      stale.forEach(function (id) { delete next[id]; });
      return next;
    });
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
      EditorStore.setState({
        pendingReloads: EditorStore.getState().pendingReloads.filter(function (r) {
          return EditorStore.getState().panes.some(function (p) {
            return p.tabs.some(function (t) { return t.id === r.tabId; });
          });
        })
      });
      forgetClosedTabs();
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
      if (tab.isUntitled) {
        // Save-as converts the scratch tab to a real one (closing the scratch
        // tab in the process); a cancelled prompt keeps the tab open.
        saveUntitledTab(closingPaneId, tab, { close: true })["catch"](function (err) {
          if (!(err && err.cancelled)) {
            EditorStore.setStatus("Save failed: " + (err && err.message || err), "error");
          }
        })["finally"](function () {
          setClosingTabId(null);
          setClosingPaneId(null);
        });
        return;
      }
      setLoading(function (prev) {
        return _extends({}, prev, { save: true });
      });
      EditorStore.setStatus("Saving " + tab.name + "...", "info");
      isSavingRef.current = true;
      FileService.saveFile(tab.path, tab.content).then(function () {
        noteLocalSave(tab.path, tab.content);
        EditorStore.setStatus("Saved", "success");
        SearchService.invalidate();
        GitService.fetchStatusLite({ background: true });
        // Reset the AVI clean baseline so undo past this save point shows dirty correctly.
        var _closeEntry = window.__mbeditorModels && window.__mbeditorModels[tab.path];
        if (_closeEntry && _closeEntry.model && !_closeEntry.model.isDisposed()) {
          _closeEntry.cleanVersionId = _closeEntry.model.getAlternativeVersionId();
        }
        TabManager.closeTab(closingPaneId, tab.id);
        EditorStore.setState({
          pendingReloads: EditorStore.getState().pendingReloads.filter(function (r) {
            return EditorStore.getState().panes.some(function (p) {
              return p.tabs.some(function (t) { return t.id === r.tabId; });
            });
          })
        });
        forgetClosedTabs();
      })["catch"](function (err) {
        EditorStore.setStatus("Save failed: " + err.message, "error");
      })["finally"](function () {
        isSavingRef.current = false;
        setLoading(function (prev) {
          return _extends({}, prev, { save: false });
        });
        setClosingTabId(null);
        setClosingPaneId(null);
      });
    } else {
      TabManager.closeTab(closingPaneId, tab.id);
      EditorStore.setState({
        pendingReloads: EditorStore.getState().pendingReloads.filter(function (r) {
          return EditorStore.getState().panes.some(function (p) {
            return p.tabs.some(function (t) { return t.id === r.tabId; });
          });
        })
      });
      forgetClosedTabs();
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
    forgetClosedTabs();
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
    forgetClosedTabs();
    setClosingTabId(null);
    setClosingPaneId(null);
    EditorStore.setStatus("Closed " + pane.tabs.length + " editor" + (pane.tabs.length === 1 ? "" : "s") + " in Group " + paneId, "info");
  };

  var handleCloseOtherTabs = function handleCloseOtherTabs(paneId, keepId) {
    var pane = state.panes.find(function (p) { return p.id === paneId; });
    if (!pane) return;
    var others = pane.tabs.filter(function (t) { return t.id !== keepId; });
    if (others.length === 0) return;
    if (!confirmBulkClose(others, "other editors")) return;
    TabManager.closeOtherTabsInPane(paneId, keepId);
    forgetClosedTabs();
    EditorStore.setStatus("Closed " + others.length + " editor" + (others.length === 1 ? "" : "s"), "info");
  };

  var handleCloseSavedTabs = function handleCloseSavedTabs(paneId) {
    var pane = state.panes.find(function (p) { return p.id === paneId; });
    if (!pane) return;
    var saved = pane.tabs.filter(function (t) { return !t.dirty; });
    if (saved.length === 0) return;
    TabManager.closeSavedTabsInPane(paneId);
    forgetClosedTabs();
    EditorStore.setStatus("Closed " + saved.length + " saved editor" + (saved.length === 1 ? "" : "s"), "info");
  };

  // Save-as for an untitled scratch tab: ask for a workspace-relative path,
  // write it, then swap the scratch tab for a real one opened at that path.
  // Returns a promise that rejects with {cancelled: true} when the user backs
  // out, so close-flows can abort instead of discarding.
  var saveUntitledTab = function saveUntitledTab(paneId, tab, opts) {
    var input = window.prompt('Save as (path relative to workspace root):', tab.name + '.txt');
    if (!input || !input.trim()) return Promise.reject({ cancelled: true });
    var newPath = input.trim().replace(/^\/+/, '');
    return FileService.saveFile(newPath, tab.content).then(function () {
      noteLocalSave(newPath, tab.content);
      SearchService.invalidate();
      GitService.fetchStatusLite({ background: true });
      FileService.getTree().then(function (data) { setTreeData(_treeUpdater(data || [])); })["catch"](function () {});
      TabManager.closeTab(paneId, tab.id);
      forgetClosedTabs();
      if (!(opts && opts.close)) {
        TabManager.openTab(newPath, newPath.split('/').pop(), null, paneId);
      }
      EditorStore.setStatus('Saved ' + newPath, 'success');
    });
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
          tabs: p.tabs.filter(function(t) { return !t.isCombinedDiff && !t.isModelGraph && !t.isUntitled; }).map(function (t) {
            return {
              id: t.id,
              path: t.path,
              name: t.name,
              dirty: t.dirty,
              viewState: t.viewState,
              isSettings: !!t.isSettings,
              isChangelog: !!t.isChangelog,
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

  useEffect(function() {
    FileService.getClientConfig().then(function(cfg) {
      setCustomPaths(Array.isArray(cfg.related_files_custom_paths) ? cfg.related_files_custom_paths : []);
      // Host-app override for the collaboration display name (user_name_callback).
      // Null/blank falls back to the browser-generated, user-editable name.
      if (typeof CollaborationIdentity !== 'undefined') {
        CollaborationIdentity.setServerName(cfg.user_name);
      }
    })['catch'](function() {});
  }, []);

  // Keep the presence chip in sync with name edits / host overrides.
  useEffect(function() {
    if (typeof CollaborationIdentity === 'undefined') return;
    setCollabIdentity(CollaborationIdentity.get());
    return CollaborationIdentity.onChange(function(id) { setCollabIdentity(id); });
  }, []);

  // Version-update detection: open the changelog tab automatically when the
  // gem version has changed since last time the editor was opened.
  //
  // Gated on sessionRestored rather than a timer. Restoring the saved session
  // replaces every pane wholesale, so a changelog tab opened before that lands
  // is silently thrown away — which is exactly what happened whenever the
  // restore took longer than the old 800 ms guess (a big session, a slow or
  // remote host). Sequencing after the restore removes the race instead of
  // making the guess bigger.
  //
  // The seen-version write is deliberately NOT gated: it records that this
  // build has been seen, and re-showing the changelog on every reload until
  // the restore happens to succeed would be worse than missing it once.
  useEffect(function() {
    var SEEN_KEY = 'mbeditor_seen_version';
    var current = document.body.dataset.mbeditorVersion || '';
    if (!current) return;
    var seen = localStorage.getItem(SEEN_KEY) || '';
    localStorage.setItem(SEEN_KEY, current);
    if (!seen || seen === current) return;
    pendingChangelogRef.current = true;
  }, []);

  useEffect(function() {
    if (!sessionRestored || !pendingChangelogRef.current) return;
    pendingChangelogRef.current = false;
    openChangelogTab();
  }, [sessionRestored]);

  var resourceLabelFromPath = function(p) {
    if (!p) return null;

    // Custom paths are checked first so they work regardless of top-level prefix.
    // Paths under app/assets/, app/javascript/, etc. never match standard
    // app/controllers|models|views|helpers, so the check must happen first.
    var customPaths = customPathsRef.current;
    for (var ci = 0; ci < customPaths.length; ci++) {
      var base = customPaths[ci];
      if (p.startsWith(base + '/')) {
        var rest = p.slice(base.length + 1);
        var resource = rest.split('/')[0].replace(/\.[^.]+$/, '');
        resource = resource.replace(/_(controller|model|helper|service)$/, '');
        if (resource) {
          var seg = resource.replace(/ies$/, 'y')
            .replace(/(ss|sh|ch|x|z)es$/, '$1')
            .replace(/([^s])s$/, '$1');
          return seg.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
        }
      }
    }

    var parts = p.split('/');
    var file = parts[parts.length - 1];
    var name;
    if (parts[0] === 'app') {
      if (parts[1] === 'controllers') name = file.replace(/_controller\.rb$/, '');
      else if (parts[1] === 'models') name = file.replace(/\.rb$/, '');
      else if (parts[1] === 'views' && parts.length >= 4) name = parts[2];
      else if (parts[1] === 'helpers') name = file.replace(/_helper\.rb$/, '');
      else return null;
    } else if (parts[0] === 'test' || parts[0] === 'spec') {
      if (parts[1] === 'controllers') name = file.replace(/_controller_(test|spec)\.rb$/, '');
      else if (parts[1] === 'models') name = file.replace(/_(test|spec)\.rb$/, '');
      else return null;
    } else {
      return null;
    }
    var seg = (name || '').split('/').pop() || name || '';
    seg = seg.replace(/ies$/, 'y')
             .replace(/(ss|sh|ch|x|z)es$/, '$1')
             .replace(/([^s])s$/, '$1');
    return seg.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
  };

  var RAILS_MAX_RESOURCES = 10;

  // Map resource label → representative path (capped at RAILS_MAX_RESOURCES, focused pane first)
  // Memoised: all three of these walk every tab in every pane and were rebuilt
  // on every render, including the ones a keystroke causes.
  // resourceLabelFromPath reads customPathsRef, hence customPaths in the deps.
  var railsResourceDeps = useMemo(function() {
    var deps = {};
    var panesOrdered = state.panes.slice().sort(function(a, b) {
      return a.id === state.focusedPaneId ? -1 : b.id === state.focusedPaneId ? 1 : 0;
    });
    panesOrdered.forEach(function(p) {
      var tabs = p.tabs.slice().sort(function(a, b) {
        return a.id === p.activeTabId ? -1 : b.id === p.activeTabId ? 1 : 0;
      });
      tabs.forEach(function(t) {
        if (Object.keys(deps).length >= RAILS_MAX_RESOURCES) return;
        if (!t.path || t.path === '__settings__' || t.path.startsWith('mbeditor://')) return;
        var label = resourceLabelFromPath(t.path);
        if (label && !deps[label]) deps[label] = t.path;
      });
    });
    return deps;
  }, [state.panes, state.focusedPaneId, customPaths]);
  var railsResourceDepStr = Object.keys(railsResourceDeps).sort().join('|');

  var railsOverflow = useMemo(function() {
    var all = {};
    state.panes.forEach(function(p) {
      p.tabs.forEach(function(t) {
        if (!t.path || t.path === '__settings__' || t.path.startsWith('mbeditor://')) return;
        var label = resourceLabelFromPath(t.path);
        if (label) all[label] = true;
      });
    });
    return Math.max(0, Object.keys(all).length - Object.keys(railsResourceDeps).length);
  }, [state.panes, railsResourceDeps, customPaths]);

  var dirtyPaths = useMemo(function() {
    var set = {};
    state.panes.forEach(function(p) {
      p.tabs.forEach(function(t) {
        if (t.dirty && t.path) set[t.path] = true;
      });
    });
    return set;
  }, [state.panes]);

  useEffect(function() {
    if (activeSidebarTab !== 'rails') return;
    var labels = Object.keys(railsResourceDeps);
    if (labels.length === 0) { setRailsFilesMap({}); return; }
    setRailsFilesMap(function(prev) {
      var next = {};
      labels.forEach(function(label) {
        next[label] = prev[label] ? { files: prev[label].files, loading: true } : { files: null, loading: true };
      });
      return next;
    });
    labels.forEach(function(label) {
      var path = railsResourceDeps[label];
      FileService.getRelatedFiles(path).then(function(data) {
        setRailsFilesMap(function(prev) {
          if (!prev.hasOwnProperty(label)) return prev;
          var next = Object.assign({}, prev);
          var update = {};
          update[label] = { files: data, loading: false };
          return Object.assign(next, update);
        });
      })['catch'](function() {
        setRailsFilesMap(function(prev) {
          if (!prev.hasOwnProperty(label)) return prev;
          var next = Object.assign({}, prev);
          var update = {};
          update[label] = { files: null, loading: false };
          return Object.assign(next, update);
        });
      });
    });
  }, [activeSidebarTab, railsResourceDepStr]);

  var focusedPane = state.panes.find(function (p) {
    return p.id === state.focusedPaneId;
  }) || state.panes[0] || null;
  var activeTab = focusedPane && focusedPane.tabs.find(function (t) {
    return t.id === focusedPane.activeTabId;
  });

  // ── Collaboration presence (slice 7) ──────────────────────────────────────
  // Only real, openable files belong in presence — virtual tabs (diffs, previews,
  // settings/changelog) are reported as "no file" so a peer's chip stays blank
  // rather than pointing at something click-to-jump can't open.
  var _presenceFileFor = function (tab) {
    if (!tab || !tab.path) return null;
    var p = tab.path;
    if (tab.isDiff || tab.isCombinedDiff || tab.isCommitGraph || tab.isPreview || tab.isSettings || tab.isChangelog) return null;
    if (p.indexOf('diff://') === 0 || p.indexOf('combined-diff://') === 0 || p.indexOf('mbeditor://') === 0) return null;
    if (p.indexOf('::preview') !== -1 || p === '__settings__') return null;
    return p;
  };
  var presenceFile = _presenceFileFor(activeTab);

  // Latest heartbeat payload, read by the throttled sender and the late-join
  // re-announce so both always relay our current identity + file.
  // Round-trip time to the cable, in ms. Our heartbeat comes back on the same
  // stream, so timing it needs no clock comparison and no extra ping traffic. We
  // publish the result in the next heartbeat; a peer's hover card therefore shows
  // *their* server RTT, which is the number that explains why their edits lag.
  //
  // Matched by sequence number, not just "our entry appeared". Every participant's
  // heartbeat rebroadcasts the whole roster, so our entry comes back on other
  // people's beats too — timing against those measured the gap since our last send
  // instead of the round trip, and read as seconds.
  var presenceSentAtRef = useRef(0);
  var presenceSeqRef = useRef(0);
  var measuredSeqRef = useRef(-1);
  var ownRttRef = useRef(null);
  // Peer RTT + local arrival time, kept in a ref rather than roster state on
  // purpose: both change on every heartbeat, and folding them into the compared
  // roster fields would reinstate the 5s idle re-render this branch just removed.
  // The hover card reads them when it opens instead, and ticks only while open.
  var peerStatsRef = useRef({});

  var presencePayloadRef = useRef(null);
  presencePayloadRef.current = collabIdentity ? {
    client_id:    collabIdentity.clientId,
    name:         collabIdentity.name,
    colour:       collabIdentity.color,
    current_file: presenceFile,
    rtt:          ownRttRef.current,
    seed:         collabIdentity.seed
  } : null;

  var _sendPresenceNow = function () {
    if (!presencePayloadRef.current) return;
    presenceSentAtRef.current = Date.now();
    presenceSeqRef.current += 1;
    WebSocketService.perform(
      'presence',
      Object.assign({}, presencePayloadRef.current, { seq: presenceSeqRef.current })
    );
  };
  // Throttle heartbeats (presence is coarse — not cursor-level), trailing edge so
  // the final file/identity always lands.
  var sendPresenceRef = useRef(null);
  if (!sendPresenceRef.current) {
    sendPresenceRef.current = (window._ && window._.throttle)
      ? window._.throttle(_sendPresenceNow, 1000, { leading: true, trailing: true })
      : _sendPresenceNow;
  }

  // Heartbeat: announce ourselves when the active file or our identity changes,
  // plus a keepalive that refreshes peers who joined in between.
  //
  // Deliberately NOT gated on cable availability. Whether cable is up is not
  // knowable at any single moment worth latching: the handshake completes after
  // the /workspace fetch that first reads it, and reconnects flip it again. Any
  // boolean captured for this decision goes stale and silently strands the page in
  // single-user mode. WebSocketService.perform() already no-ops while
  // disconnected, so an ungated heartbeat costs one dead call every 5s and starts
  // working the instant the socket does.
  useEffect(function () {
    sendPresenceRef.current();
    var id = setInterval(function () { sendPresenceRef.current(); }, 5000);
    return function () { clearInterval(id); };
  }, [presenceFile, collabIdentity ? collabIdentity.clientId : null,
      collabIdentity ? collabIdentity.name : null, collabIdentity ? collabIdentity.color : null]);

  // Roster sync. The server sends the complete roster on every change and we
  // replace ours with it, rather than merging per-participant here/leave events.
  // Merging could not self-correct: one missed leave left a peer in the roster
  // permanently, and since the roster gates collaboration, that one phantom kept
  // persistent undo off and external-change detection suppressed for the whole
  // session. A dropped message now costs one stale interval instead.
  // Subscribed for the life of the app, for the same reason the heartbeat is:
  // no message arrives without a cable, so there is nothing to gate, and gating it
  // on a latched boolean is what left presence unsubscribed when the handshake
  // landed after startup.
  useEffect(function () {
    var handler = function (data) {
      var roster = data && data.roster;
      if (!roster) return;
      var me = (typeof CollaborationIdentity !== 'undefined') ? CollaborationIdentity.get().clientId : null;

      // The first broadcast carrying our newest seq is the one our own heartbeat
      // caused — the server records then broadcasts in the same call. Later
      // broadcasts repeat that seq, hence measuring once per sequence number.
      var mineEcho = me && roster[me];
      if (mineEcho && presenceSentAtRef.current &&
          mineEcho.seq === presenceSeqRef.current &&
          measuredSeqRef.current !== presenceSeqRef.current) {
        measuredSeqRef.current = presenceSeqRef.current;
        ownRttRef.current = Date.now() - presenceSentAtRef.current;
      }

      // rtt and idle change every broadcast, so they stay out of the compared
      // state entirely — folding them in would re-render the app every 5s to keep
      // a hover card fresh that nobody is looking at. The card reads this ref.
      var next = {};
      var stats = {};
      Object.keys(roster).forEach(function (cid) {
        if (cid === me) return;
        var p = roster[cid];
        // Validated once, here, rather than at each of the places that paints it.
        next[cid] = {
          name: p.name,
          colour: CollaborationIdentity.safeColor(p.colour),
          current_file: p.current_file,
          seed: p.seed
        };
        stats[cid] = { rtt: p.rtt, idle: p.idle };
      });
      peerStatsRef.current = stats;

      // Re-evaluated on every roster message rather than only when the peer count
      // transitions, so availability recovers on its own after a reconnect. The
      // service compares the computed value, so a no-change call costs nothing.
      if (typeof CollaborationService !== 'undefined') {
        CollaborationService.setPeerPresent(Object.keys(next).length > 0);
      }

      // Stop following someone who is no longer here.
      setFollowedClientId(function (cur) {
        if (cur && !next[cur]) {
          if (typeof CollaborationService !== 'undefined') CollaborationService.clearFollow();
          return null;
        }
        return cur;
      });

      setCollabRoster(function (prev) {
        var prevIds = Object.keys(prev);
        var nextIds = Object.keys(next);
        var same = prevIds.length === nextIds.length && nextIds.every(function (cid) {
          var a = prev[cid], b = next[cid];
          return a && a.name === b.name && a.colour === b.colour &&
                 a.current_file === b.current_file && a.seed === b.seed;
        });
        return same ? prev : next;
      });
    };
    WebSocketService.onPresence(handler);
    return function () { WebSocketService.offPresence(handler); };
  }, []);

  // The roster is the only "is anyone actually pairing with me?" signal, so it is
  // what gates collaboration. Cable availability alone is not enough: it is up in
  // a normal dev setup, and gating on it silently disabled persistent undo and
  // external-change detection for solo users. The service is told about the roster
  // from the presence handler above, not from an effect here, so it hears about
  // every message rather than only about a change in the participant count.
  var _collabDiag = useState(false);
  var collabDiagOpen = _collabDiag[0], setCollabDiagOpen = _collabDiag[1];
  var _collabTrouble = useState(null);
  var collabTrouble = _collabTrouble[0], setCollabTrouble = _collabTrouble[1];

  // Re-checked on a slow interval because the failures worth reporting — a
  // rejected handshake, a dropped socket — happen asynchronously and nothing
  // else would notice. Only the first failing check's key is stored, so an
  // unchanged state is an identical string and React bails rather than
  // re-rendering the app every tick.
  useEffect(function () {
    // A reconnect is not a fault. Action Cable drops and re-establishes its
    // socket routinely, and a dev server busy with a burst of saves is enough
    // to cause it — the cable shares the same thread pool as every request the
    // editor makes. Reporting the first non-connected sample made the chip
    // announce "Pairing off" during exactly the moments the editor was already
    // struggling, then clear a few seconds later, which reads as a second
    // failure rather than as the self-healing reconnect it actually is.
    //
    // So a transient state has to be seen twice before it is shown, with the
    // confirming check brought forward so a real outage still surfaces in
    // seconds. Hard failures are exempt: missing libraries, no Action Cable, a
    // server that does not advertise it, or a *rejected* handshake never heal
    // on their own, so they report on the first sample as before.
    var TRANSIENT_PROBLEMS = { connected: true };
    var unconfirmed = null;
    var recheckTimer = null;

    function check() {
      if (typeof CollaborationService === 'undefined' ||
          typeof CollaborationService.diagnostics !== 'function') return;
      var d = CollaborationService.diagnostics();
      // "Nobody else is here" is not a fault; everything else is.
      var problem = d.firstProblem && d.firstProblem.key !== 'peers' ? d.firstProblem.key : null;
      var transient = !!problem && !!TRANSIENT_PROBLEMS[problem] && d.cableStatus !== 'rejected';

      if (transient && unconfirmed !== problem) {
        unconfirmed = problem;
        clearTimeout(recheckTimer);
        recheckTimer = setTimeout(check, 3000);
        return;
      }
      unconfirmed = transient ? problem : null;
      setCollabTrouble(function (prev) { return prev === problem ? prev : problem; });
    }
    check();
    var id = setInterval(check, 10000);
    return function () { clearInterval(id); clearTimeout(recheckTimer); };
  }, []);

  var collabPeerIds = Object.keys(collabRoster);

  // A labelled peer chip costs ~110px (name + filename), and the titlebar button
  // cluster does not shrink or wrap: past three peers it squeezes the search pill
  // to its floor and then pushes Help / Install off the right edge. Drop to bare
  // colour dots instead of hiding peers behind a "+N more" summary — a dot is
  // ~20px, so ten peers still fit, every chip stays clickable to follow, and the
  // solid/hollow ring keeps working. The name and file live in the tooltip.
  var COLLAB_LABEL_LIMIT = 3;
  var collabPeerLabels = !toolbarIconOnly && collabPeerIds.length <= COLLAB_LABEL_LIMIT;

  // Colour is minted from a hash before any peer is known, so it has to be
  // reconciled against the roster once one exists. Runs on every roster change;
  // reconcileColor no-ops unless we actually clash and lose the tie-break, so the
  // usual case costs one array map and no state write.
  useEffect(function () {
    if (typeof CollaborationIdentity === 'undefined') return;
    CollaborationIdentity.reconcileColor(collabPeerIds.map(function (cid) {
      return { clientId: cid, color: collabRoster[cid].colour, seed: collabRoster[cid].seed };
    }));
  }, [collabRoster]);

  // Hover card. Anchored from the chip's own rect, right-aligned because these
  // chips sit against the right edge of the titlebar and a left-anchored card
  // would run off screen.
  var _useStateHover = useState(null);
  var _useStateHover2 = _slicedToArray(_useStateHover, 2);
  var collabHover = _useStateHover2[0];
  var setCollabHover = _useStateHover2[1];

  var openCollabHover = function (cid, e) {
    var r = e.currentTarget.getBoundingClientRect();
    setCollabHover({ cid: cid, top: r.bottom + 4, right: window.innerWidth - r.right });
  };

  // Latency and last-seen only need to tick while the card is actually on screen,
  // so the interval lives and dies with it. Idle cost stays zero.
  var _useStateHoverTick = useState(0);
  var _useStateHoverTick2 = _slicedToArray(_useStateHoverTick, 2);
  var setCollabHoverTick = _useStateHoverTick2[1];
  useEffect(function () {
    if (!collabHover) return;
    var id = setInterval(function () { setCollabHoverTick(function (n) { return n + 1; }); }, 1000);
    return function () { clearInterval(id); };
  }, [collabHover]);

  // Follow mode (slice 8): toggle tracking a roster participant. Following sets up
  // the viewport scroll-tracking in CollaborationService; the file-open is handled
  // by the effect below (it also re-fires when the followed peer switches files).
  var followedFile = (followedClientId && collabRoster[followedClientId])
    ? collabRoster[followedClientId].current_file : null;
  var toggleFollow = function (cid) {
    if (followedClientId === cid) {
      setFollowedClientId(null);
      if (typeof CollaborationService !== 'undefined') CollaborationService.clearFollow();
    } else {
      setFollowedClientId(cid);
      if (typeof CollaborationService !== 'undefined') CollaborationService.setFollow(cid);
    }
  };

  // While following, open/focus whatever file the followed participant currently
  // has open, and re-open when they switch files. Viewport tracking within that
  // file is handled by CollaborationService once both peers share the room.
  useEffect(function () {
    if (!followedClientId || !followedFile) return;
    if (activeTab && activeTab.path === followedFile) return;
    handleSelectFile(followedFile, followedFile.split('/').pop());
  }, [followedClientId, followedFile]);

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
    if (!gitAvailable || !activeTab || activeTab.isDiff || activeTab.isCombinedDiff || activeTab.isCommitGraph || !activeTab.path || activeTab.path.indexOf('://') >= 0) {
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
      applyMarkersForTab(activeTab.id, []);
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

  // Format-on-save helper: returns a Promise resolving to the formatted
  // content, or null when no formatter applies / formatting fails (the save
  // then proceeds with the original content — saving must never be blocked
  // by a formatter problem).
  var _formatContentForSave = function _formatContentForSave(tab) {
    var isRubyLang = /\.(rb|rake|gemspec)$/.test(tab.path) || /(?:^|\/)(Rakefile|Gemfile)$/.test(tab.path);
    if (isRubyLang) {
      if (!rubocopAvailable) return Promise.resolve(null);
      return FileService.formatFile(tab.path, tab.content)
        .then(function (res) { return (res && res.content) || null; })
        ["catch"](function () { return null; });
    }
    var parserName = prettierParserFor(tab.path);
    if (!parserName) return Promise.resolve(null);
    return runPrettier(tab.content, editorPrefs, parserName)["catch"](function () { return null; });
  };

  // Re-read a tab from the store after flushing TabManager's throttled content
  // write. `tab` here is whatever the render captured, so flushing alone is not
  // enough — the fresh text lands in the store, not in this object.
  var _freshTab = function _freshTab(paneId, tab) {
    TabManager.flushContent();
    var pane = EditorStore.getState().panes.find(function (p) { return p.id === paneId; });
    var live = pane && pane.tabs.find(function (t) { return t.id === tab.id; });
    return live || tab;
  };

  var handleSave = function handleSave(paneId, tab) {
    tab = _freshTab(paneId, tab);
    if (editorPrefs.formatOnSave === true) {
      EditorStore.setStatus("Formatting " + tab.name + "...", "info");
      _formatContentForSave(tab).then(function (formatted) {
        if (formatted != null && formatted !== tab.content) {
          // Push the formatted text into the tab (externalContentVersion makes
          // the Monaco model pick it up), then save that content.
          EditorStore.setState({
            panes: EditorStore.getState().panes.map(function (p) {
              if (p.id !== paneId) return p;
              return _extends({}, p, { tabs: p.tabs.map(function (t) {
                return t.id === tab.id ? _extends({}, t, { content: formatted, externalContentVersion: (t.externalContentVersion || 0) + 1 }) : t;
              }) });
            })
          });
          _doSave(paneId, _extends({}, tab, { content: formatted }));
        } else {
          _doSave(paneId, tab);
        }
      });
      return;
    }
    _doSave(paneId, tab);
  };

  var _doSave = function _doSave(paneId, tab) {
    if (tab.isUntitled) {
      saveUntitledTab(paneId, tab)["catch"](function (err) {
        if (err && err.cancelled) return;
        EditorStore.setStatus("Save failed: " + (err && err.message || err), "error");
      });
      return;
    }
    setLoading(function (prev) {
      return _extends({}, prev, { save: true });
    });
    EditorStore.setStatus("Saving " + tab.name + "...", "info");
    isSavingRef.current = true;
    FileService.saveFile(tab.path, tab.content).then(function () {
      noteLocalSave(tab.path, tab.content);
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
      // Collab: push a fresh snapshot so the server compacts the buffered deltas.
      if (typeof CollaborationService !== 'undefined' && CollaborationService.isBound(tab.path)) {
        CollaborationService.pushSnapshot(tab.path);
      }
      EditorStore.setStatus("Saved", "success");
      _clearDraft(tab.path);
      if (typeof HistoryService !== 'undefined') {
        HistoryService.flushForPath(tab.path);
      }
      SearchService.invalidate();

      // Hot reload for Markdown: sync preview tab after save
      if (/\.(md|markdown)$/i.test(tab.path)) {
        TabManager.syncMarkdownPreview(tab.path, tab.content);
      }

      // Save-time babel syntax check for JS/JSX: catches code the host's
      // sprockets/react-rails pipeline can't transform (errors Monaco's TS
      // worker misses). Save only — never per keystroke.
      if (jsSyntaxCheckAvailableRef.current && /\.(js|jsx)$/i.test(tab.path)) {
        FileService.lintFile(tab.path, tab.content, 'javascript').then(function (res) {
          var babelMarkers = (res && res.markers) || [];
          if (babelMarkers.length > 0) {
            applyMarkersForTab(tab.id, babelMarkers);
            EditorStore.setStatus('Saved — babel: ' + babelMarkers[0].message, 'warning');
          } else {
            // Clear any previous babel marker for this tab (keep others none —
            // JS tabs have no rubocop markers, so replacing is safe).
            // applyMarkersForTab keeps the previous map when it is already empty.
            applyMarkersForTab(tab.id, []);
          }
        })["catch"](function () {});
      }

      // The server broadcasts files_changed for this very write, and the
      // coalesced handler refreshes git status there — so firing here too ran
      // the git work twice per save, and this copy is the one a burst cannot
      // coalesce. fetchStatusLite escalates to the full /git_info fan-out
      // whenever the working tree signature moved, which saving a different
      // file every time does by definition, so the duplicate was the expensive
      // one. Without a socket no broadcast arrives, so keep it for that case.
      if (!_socketWillBroadcast()) GitService.fetchStatusLite({ background: true });
    })["catch"](function (err) {
      EditorStore.setStatus("Save failed: " + err.message, "error");
    })["finally"](function () {
      isSavingRef.current = false;
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
    isSavingRef.current = true;
    FileService.saveFile(tab.path, tab.content).then(function () {
      noteLocalSave(tab.path, tab.content);
      EditorStore.setState({
        panes: EditorStore.getState().panes.map(function (p) {
          if (p.id !== reload.paneId) return p;
          return Object.assign({}, p, {
            tabs: p.tabs.map(function (t) {
              if (t.id !== reload.tabId) return t;
              return Object.assign({}, t, {
                content: tab.content,
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
    })["finally"](function () {
      isSavingRef.current = false;
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
    // Flush first, then read the panes back out of the store — the render's
    // `state` predates the flush. See TabManager's flush contract.
    TabManager.flushContent();
    var dirtyTabs = EditorStore.getState().panes.flatMap(function (p) {
      return p.tabs;
    }).filter(function (t) {
      // Untitled scratch tabs need a save-as prompt each — Ctrl+S them
      // individually; bulk-save skips them rather than stacking prompts.
      return t.dirty && !t.isUntitled;
    });
    if (dirtyTabs.length === 0) return;

    setLoading(function (prev) {
      return _extends({}, prev, { saveAll: true });
    });
    EditorStore.setStatus("Saving " + dirtyTabs.length + " files...", "info");
    isSavingRef.current = true;
    // allSettled, not all: one slow or rejected write used to abandon the
    // bookkeeping for every other file, so tabs whose contents were already on
    // disk stayed dirty and the only thing on offer was to hit Save All again.
    // Each file is now settled on its own result.
    var promises = dirtyTabs.map(function (tab) {
      return FileService.saveFile(tab.path, tab.content);
    });
    Promise.allSettled(promises).then(function (results) {
      var saved = dirtyTabs.filter(function (tab, i) { return results[i].status === "fulfilled"; });
      // Object.create(null): these keys are file paths, and a file called
      // "constructor" would otherwise test as present against Object.prototype
      // and have its tab marked clean without ever being written.
      var savedPaths = Object.create(null);
      saved.forEach(function (tab) {
        savedPaths[tab.path] = tab.content;
        noteLocalSave(tab.path, tab.content);
      });
      var newPanes = EditorStore.getState().panes.map(function (p) {
        return _extends({}, p, { tabs: p.tabs.map(function (t) {
            // Compare content, not just the path: a tab edited again while the
            // save was in flight is dirty against what actually reached disk.
            if (!(t.path in savedPaths) || t.content !== savedPaths[t.path]) return t;
            return _extends({}, t, { dirty: false, cleanContent: t.content });
          })
        });
      });
      EditorStore.setState({ panes: newPanes });
      // Reset AVI clean baselines for all saved files so undo past save shows dirty correctly.
      saved.forEach(function(tab) {
        var _me = window.__mbeditorModels && window.__mbeditorModels[tab.path];
        if (_me && _me.model && !_me.model.isDisposed()) {
          _me.cleanVersionId = _me.model.getAlternativeVersionId();
        }
      });
      if (saved.length === dirtyTabs.length) {
        EditorStore.setStatus("All files saved", "success");
      } else {
        EditorStore.setStatus("Saved " + saved.length + " of " + dirtyTabs.length +
          " files — " + (dirtyTabs.length - saved.length) + " failed", "error");
      }
      SearchService.invalidate();
      GitService.fetchStatusLite({ background: true });
    })["catch"](function () {
      // allSettled never rejects, so this only fires if the bookkeeping above
      // throws. Without it that would be an unhandled rejection and the status
      // bar would sit on "Saving N files..." forever.
      EditorStore.setStatus("Save All finished with errors", "error");
    })["finally"](function () {
      isSavingRef.current = false;
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

  var handleRefreshWorkspace = function handleRefreshWorkspace() {
    setLoading(function (prev) {
      return _extends({}, prev, { refreshWorkspace: true });
    });
    GitService.fetchStatus()["catch"](function () {});
    FileService.getTree({ refresh: true }).then(function (data) {
      setTreeData(_treeUpdater(data || []));
      checkOpenTabsForExternalChanges();
      EditorStore.setStatus("Workspace refreshed", "success");
    })["catch"](function (err) {
      EditorStore.setStatus("Failed to refresh workspace", "error");
    })["finally"](function () {
      setLoading(function (prev) {
        return _extends({}, prev, { refreshWorkspace: false });
      });
    });
  };

  // The toolbar button and Monaco's own Format Document must not disagree
  // about what "formatted" means, so both go through ruby-lsp when it can
  // answer and fall back to /format when it can't — the same order the
  // formatting provider uses. Returns { content: } either way, since the
  // button also wants to diff the result and flash the changed lines.
  var formatRubySource = function formatRubySource(path, code) {
    var viaLsp = window.MBEDITOR_RUBY_LSP_AVAILABLE &&
      !(window.MbeditorEditorPlugins && MbeditorEditorPlugins.lspBackedOff()) &&
      isRubyPath(path);
    if (!viaLsp) return FileService.formatFile(path, code);

    return FileService.rubyLspRequest('formatting', path, code, 1, 1, { timeout: 15000 })
      .then(function (data) {
        var edits = data && data.result;
        // ruby-lsp answers a whole-document replacement, or null when RuboCop's
        // autocorrect cannot converge — in which case /format's `rubocop -A`
        // pass still gets a turn.
        if (Array.isArray(edits) && edits.length === 1 && typeof edits[0].newText === 'string') {
          return { content: edits[0].newText };
        }
        if (data) noteLspFailure({ lspData: data });
        return FileService.formatFile(path, code);
      })["catch"](function (err) {
        noteLspFailure(err);
        return FileService.formatFile(path, code);
      });
  };

  // Format one tab's content.
  //
  // Resolves to the formatted string, or to null when no formatter covers this
  // file type (the caller then decides whether to fall back to a re-indent).
  // Rejects when a formatter ran and failed, so the reason reaches the user
  // rather than the button appearing to do nothing.
  var formatTabContent = function formatTabContent(tab, prefs) {
    prefs = prefs || editorPrefs;
    if (isRubyPath(tab.path) || tab.path.endsWith('.rake')) {
      if (!rubocopAvailable) return Promise.reject(new Error("RuboCop is not available for this workspace."));
      // RuboCop's output is taken as-is. Ruby indentation belongs to the
      // project's .rubocop.yml (Layout/IndentationStyle and friends), so
      // rewriting it here would fight the linter that is about to be run over
      // the same file. The old code tried the opposite — converting the source
      // to tabs *before* handing it over — which RuboCop simply discarded.
      return formatRubySource(tab.path, tab.content).then(function (res) {
        return (res && res.content) || null;
      });
    }

    var parserName = prettierParserFor(tab.path);
    if (!parserName) return Promise.resolve(null);
    return runPrettier(tab.content, prefs, parserName);
  };

  // Markers are per-model and only the mounted editor re-lints, so a document
  // formatted in the background kept the diagnostics of the text it no longer
  // holds — the Problems panel and the status-bar tallies went on reporting
  // offenses at line numbers that had moved, and Format All barely moved the
  // counts because only the visible tab was re-checked. Dropping them says
  // "not known yet", which is true: the file re-lints when you open it.
  var discardStaleMarkers = function discardStaleMarkers(path) {
    if (!path) return;

    // The React map has to go too, not just Monaco's copy. It is what TabBar
    // counts, and EditorPanel re-applies it to the model the next time that tab
    // mounts — so clearing only Monaco left every background tab primed to put
    // its stale squiggles straight back on the next tab switch.
    EditorStore.getState().panes.forEach(function (p) {
      p.tabs.forEach(function (t) {
        if (t.path === path) applyMarkersForTab(t.id, []);
      });
    });

    if (!window.monaco || !window.monaco.editor) return;
    var entry = window.__mbeditorModels && window.__mbeditorModels[path];
    if (!entry || !entry.model || entry.model.isDisposed()) return;

    var owners = {};
    window.monaco.editor.getModelMarkers({ resource: entry.model.uri }).forEach(function (m) {
      owners[m.owner] = true;
    });
    Object.keys(owners).forEach(function (owner) {
      window.monaco.editor.setModelMarkers(entry.model, owner, []);
    });
  };

  // Write formatted content back to a tab, dirty and unsaved — the user decides
  // when to save. EditorPanel applies it through executeEdits, so undo works.
  var applyFormattedContent = function applyFormattedContent(paneId, tabId, formatted) {
    var formattedPath = null;
    EditorStore.setState({
      panes: EditorStore.getState().panes.map(function (p) {
        if (p.id !== paneId) return p;
        return _extends({}, p, { tabs: p.tabs.map(function (t) {
          if (t.id !== tabId) return t;
          formattedPath = t.path;
          return _extends({}, t, { content: formatted, dirty: true, externalContentVersion: (t.externalContentVersion || 0) + 1 });
        }) });
      })
    });
    discardStaleMarkers(formattedPath);
  };

  var highlightFormatChanges = function highlightFormatChanges(before, after) {
    var monacoEditor = window.__mbeditorActiveEditor;
    if (!monacoEditor || before === after) return;
    var changedLineNums = diffLines(before.split('\n'), after.split('\n'));
    if (!changedLineNums.length) return;
    var ids = monacoEditor.deltaDecorations([], changedLineNums.map(function (ln) {
      return { range: new monaco.Range(ln, 1, ln, 1), options: { isWholeLine: true, className: 'mbeditor-format-changed' } };
    }));
    setTimeout(function () { monacoEditor.deltaDecorations(ids, []); }, 3000);
  };

  var handleFormat = function handleFormat() {
    if (!activeTab) return;

    var paneId = focusedPane.id;
    var tab = _freshTab(paneId, activeTab);
    var originalContent = tab.content;

    setLoading(function (prev) { return _extends({}, prev, { format: true }); });
    EditorStore.setStatus("Formatting " + tab.name + "...", "info");

    formatTabContent(tab).then(function (formatted) {
      if (formatted == null) {
        // No formatter for this file type — re-indent with Monaco instead.
        var monacoEditor = window.__mbeditorActiveEditor;
        var reindentAction = monacoEditor && monacoEditor.getAction('editor.action.reindentLines');
        if (!reindentAction) {
          EditorStore.setStatus("No formatter for " + tab.name + ".", "warning");
          return;
        }
        return reindentAction.run().then(function () {
          EditorStore.setStatus("Re-indented (Unsaved)", "success");
        });
      }
      if (formatted !== originalContent) {
        applyFormattedContent(paneId, tab.id, formatted);
        highlightFormatChanges(originalContent, formatted);
      }
      EditorStore.setStatus(formatted === originalContent ? "Already formatted" : "Formatted (Unsaved)", "success");
      GitService.fetchStatus();
    })["catch"](function (err) {
      EditorStore.setStatus("Format failed: " + (err && err.message ? err.message : err), "error");
    })["finally"](function () {
      setLoading(function (prev) { return _extends({}, prev, { format: false }); });
    });
  };

  // Format every open document across all panes.
  //
  // Each tab is formatted independently and a failure is collected rather than
  // thrown, so one unparseable file cannot stop the rest. Virtual tabs (diffs,
  // settings, the changelog) have no path on disk and are skipped.
  var handleFormatAll = function handleFormatAll() {
    // See TabManager's flush contract — the panes are read straight after.
    TabManager.flushContent();
    var targets = [];
    EditorStore.getState().panes.forEach(function (p) {
      p.tabs.forEach(function (t) {
        if (t.path && !t.path.startsWith('mbeditor://') && t.path !== '__settings__' && typeof t.content === 'string') {
          targets.push({ paneId: p.id, tab: t });
        }
      });
    });

    if (!targets.length) {
      EditorStore.setStatus("No open documents to format.", "warning");
      return;
    }

    setLoading(function (prev) { return _extends({}, prev, { format: true }); });
    EditorStore.setStatus("Formatting " + targets.length + " open document" + (targets.length === 1 ? "" : "s") + "...", "info");

    var changed = 0;
    var skipped = 0;
    var failures = [];

    Promise.all(targets.map(function (target) {
      return formatTabContent(target.tab).then(function (formatted) {
        if (formatted == null) { skipped += 1; return; }
        if (formatted === target.tab.content) return;
        applyFormattedContent(target.paneId, target.tab.id, formatted);
        changed += 1;
      })["catch"](function (err) {
        failures.push(target.tab.name + ": " + (err && err.message ? err.message.split('\n')[0] : err));
      });
    })).then(function () {
      var parts = [changed + " formatted"];
      if (skipped) parts.push(skipped + " skipped");
      if (failures.length) parts.push(failures.length + " failed");
      EditorStore.setStatus(
        parts.join(", ") + (changed ? " (Unsaved)" : "") + (failures.length ? " — " + failures[0] : ""),
        failures.length ? "error" : "success"
      );
      if (changed) GitService.fetchStatus();
    })["finally"](function () {
      setLoading(function (prev) { return _extends({}, prev, { format: false }); });
    });
  };

  var TEST_CACHE_PREFIX = 'mbeditor_test_result_';

  var saveCachedTestResult = function saveCachedTestResult(filePath, result) {
    try {
      localStorage.setItem(TEST_CACHE_PREFIX + filePath, JSON.stringify(result));
    } catch (e) {}
  };

  var executeTestRun = function executeTestRun(filePath, line) {
    setTestLoading(true);
    EditorStore.setStatus(line ? 'Running test at line ' + line + '...' : 'Running tests...', 'info');

    FileService.runTests(filePath, line).then(function (res) {
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

  var handleRerunTest = function handleRerunTest() {
    if (!activeTab || !activeTab.path) return;
    if (testLoading) return;
    executeTestRun(activeTab.path);
  };

  // Run only the test enclosing the cursor. Always re-runs (never serves the
  // cached whole-file result) since the filter changes with the cursor.
  var handleRunTestAtCursor = function handleRunTestAtCursor(line) {
    if (!activeTab || !activeTab.path) return;
    if (testLoading) return;
    executeTestRun(activeTab.path, line);
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
    setSearchCollapsedFiles({});
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
          // The registry holds {model, aviBase, ...} entries, not models. This
          // used to call setValue/isDisposed straight on the entry, which threw
          // into the .catch below — so an open tab kept its pre-replace text and
          // could save it back over the replacement.
          var entry = window.__mbeditorModels[relPath];
          var model = entry && entry.model;
          if (!model || model.isDisposed()) return;
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
    setSearchViewport(function (prev) {
      // Only the rows that moved in or out of the window matter, and those
      // change a row at a time. Comparing keeps a scroll gesture from
      // committing a render per pixel.
      if (prev.scrollTop === el.scrollTop && prev.height === el.clientHeight) return prev;
      return { scrollTop: el.scrollTop, height: el.clientHeight };
    });
  };

  var toggleGitPanel = function toggleGitPanel() {
    setShowGitPanel(function (prev) {
      if (!prev) GitService.fetchInfo();
      return !prev;
    });
  };

  var toggleLogPanel = function toggleLogPanel() {
    setShowLogPanel(function (prev) { return !prev; });
  };

  var toggleProblemsPanel = function toggleProblemsPanel() {
    setShowProblemsPanel(function (prev) { return !prev; });
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

  var finishImport = function finishImport(result, destFolder) {
    var written  = result.imported || [];
    var imported = written.length;
    var skipped  = (result.conflicts || []).length;
    var failed   = (result.errors || []).length;

    // Say where the files went. A bulk upload that reports only a count looks
    // the same whether it landed where you meant it to or in the workspace
    // root, and the destination is the whole question a folder import raises.
    var where = destFolder ? ' to ' + destFolder : ' to the workspace root';
    var parts = [imported + ' file' + (imported === 1 ? '' : 's') + ' imported' + (imported > 0 ? where : '')];
    if (skipped > 0) parts.push(skipped + ' skipped');
    if (failed > 0) parts.push(failed + ' failed');

    var level = failed === 0 ? 'success' : (imported === 0 ? 'error' : 'warning');
    EditorStore.setStatus(parts.join(', ') + '.', level);

    if (imported > 0) {
      // Expand down to what was just written, so the tree actually shows it —
      // importing into a collapsed folder otherwise leaves the explorer looking
      // untouched. Deliberately does not *select* the folder: the tree
      // selection is what the toolbar's Upload button reads for its default
      // destination, and pinning it here would make every later upload default
      // to this import's folder.
      var landed = parentDir(written[0].path);
      var toExpand = {};
      var bits = landed ? landed.split('/') : [];
      for (var i = 1; i <= bits.length; i++) toExpand[bits.slice(0, i).join('/')] = true;

      refreshProjectTree().then(function() {
        if (bits.length) setExpandedDirs(function (prev) { return Object.assign({}, prev, toExpand); });
        GitService.fetchStatus();
      });
    }
  };

  // A file dropped anywhere that isn't a drop target makes the browser
  // navigate away and open it, which loses the editor and every unsaved
  // buffer with it. Swallow those at the window so a near-miss is a no-op
  // rather than a disaster. Real targets stopPropagation before this runs.
  useEffect(function () {
    var swallow = function (e) {
      var types = (e.dataTransfer && e.dataTransfer.types) || [];
      if (Array.prototype.indexOf.call(types, 'Files') === -1) return;
      e.preventDefault();
      // dragover is left alone beyond preventDefault: setting dropEffect here
      // would override the 'copy' cursor the tree sets on a valid folder.
      if (e.type === 'drop') e.dataTransfer.dropEffect = 'none';
    };
    window.addEventListener('dragover', swallow);
    window.addEventListener('drop', swallow);
    return function () {
      window.removeEventListener('dragover', swallow);
      window.removeEventListener('drop', swallow);
    };
  }, []);

  // Files dragged in from outside the browser. Pass one reports conflicts
  // without touching them; if there are any, the modal collects a resolution
  // and pass two re-sends just those entries.
  var handleImportFiles = function handleImportFiles(entries, targetFolderPath, meta) {
    if (meta && meta.truncated) {
      EditorStore.setStatus('That drop holds more than ' + FileImport.MAX_ENTRIES +
        ' files — only the first ' + FileImport.MAX_ENTRIES + ' will be imported.', 'warning');
    } else if (meta && meta.foldersSkipped) {
      EditorStore.setStatus('This browser cannot read dropped folders — only loose files were imported.', 'warning');
    } else {
      EditorStore.setStatus('Importing ' + entries.length + ' file' +
        (entries.length === 1 ? '' : 's') + '...', 'info');
    }

    return FileService.importFiles(FileImport.buildFormData(entries, targetFolderPath, 'ask'))
      .then(function(result) {
        if (result.conflicts && result.conflicts.length > 0) {
          setImportConflict({ result: result, entries: entries, targetFolderPath: targetFolderPath });
        } else {
          finishImport(result, targetFolderPath);
        }
      })['catch'](function(err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Import failed: ' + message, 'error');
      });
  };

  var resolveImportConflict = function resolveImportConflict(mode) {
    var pending = importConflict;
    setImportConflict(null);
    if (!pending) return;

    if (mode === 'skip') { finishImport(pending.result, pending.targetFolderPath); return; }

    var retry = FileImport.conflictedEntries(
      pending.entries,
      pending.targetFolderPath,
      pending.result.conflicts
    );
    if (retry.length === 0) { finishImport(pending.result, pending.targetFolderPath); return; }

    FileService.importFiles(FileImport.buildFormData(retry, pending.targetFolderPath, mode))
      .then(function(second) {
        finishImport({
          imported: (pending.result.imported || []).concat(second.imported || []),
          conflicts: [],
          errors: (pending.result.errors || []).concat(second.errors || [])
        }, pending.targetFolderPath);
      })['catch'](function(err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Import failed: ' + message, 'error');
      });
  };

  // Downloads go straight through /raw?download=1 — the browser's own save
  // flow, so nothing is buffered client-side and a 5 MB file costs no memory.
  // A synthetic anchor rather than location.href: navigating away from the
  // editor to an attachment response leaves the page in a half-unloaded state
  // in Safari.
  var handleDownloadFile = function handleDownloadFile(node) {
    if (!node || node.type !== 'file') return;
    var link = document.createElement('a');
    link.href = window.mbeditorBasePath() + '/raw?download=1&path=' + encodeURIComponent(node.path);
    link.download = node.name;
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    EditorStore.setStatus('Downloading ' + node.name + '...', 'info');
  };

  // A file node means "upload alongside this file", so the dialog opens on its
  // parent — right-clicking a file to upload next to it is the common gesture.
  var openImportDialog = function openImportDialog(node) {
    var folder = '';
    if (node && node.type === 'folder') {
      folder = node.path;
    } else if (node && node.path) {
      folder = node.path.split('/').slice(0, -1).join('/');
    }
    setImportDialog({ initialFolder: folder });
  };

  var confirmImportDialog = function confirmImportDialog(entries, destFolder, meta) {
    setImportDialog(null);
    handleImportFiles(entries, destFolder, meta);
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
    if (action === 'download' && node) {
      handleDownloadFile(node);return;
    }
    if (action === 'upload') {
      openImportDialog(node);return;
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

  var handleActivityBarClick = function handleActivityBarClick(tab) {
    if (tab === 'settings') {
      openSettingsTab();
      return;
    }
    // The model graph is a view, not a panel: it takes over the central area
    // and needs the width. There is no sidebar half to show.
    if (tab === 'models') {
      openModelGraphTab();
      return;
    }
    if (!sidebarCollapsed && activeSidebarTab === tab) {
      setSidebarCollapsed(true);
    } else {
      setActiveSidebarTab(tab);
      setSidebarCollapsed(false);
    }
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

    if (removedTabIds.length) forgetClosedTabs();
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
        // We just wrote this file and know it is empty, so opening it does not
        // need to ask the server what is in it. noteLocalSave records the write
        // for the same reason a save does: the create's own broadcast comes
        // straight back as a files_changed naming this path, and without this
        // the external-change check read the file back off disk to ask whether
        // it had changed since we wrote it a moment earlier.
        if (FileService.seedPrefetch) FileService.seedPrefetch(createdPath, '');
        noteLocalSave(createdPath, '');
        handleNodeSelect({ path: createdPath, name: createdName, type: 'file' });
        EditorStore.setStatus('Created file: ' + createdName, 'success');
        // The optimistic node is already in the tree and the server's
        // structural broadcast refreshes it for real a moment later, so
        // walking the workspace here as well made one create cost three full
        // tree walks — and every write invalidates the server's tree cache, so
        // each one is a fresh recursive scan of the whole checkout. Same for
        // git status, which the same broadcast handler already refreshes.
        // Without a socket neither happens on its own, so keep both for that.
        if (_socketWillBroadcast()) {
          handleSelectFile(createdPath, createdName);
          return;
        }
        return refreshProjectTree().then(function () {
          handleSelectFile(createdPath, createdName);
          GitService.fetchStatusLite({ background: true });
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
        // See handleCreateConfirm's file branch — the broadcast covers both.
        if (_socketWillBroadcast()) return;
        return refreshProjectTree().then(function () {
          return GitService.fetchStatusLite({ background: true });
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
        GitService.fetchStatusLite({ background: true });
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
        GitService.fetchStatusLite({ background: true });
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
      // Diagnostics live in this map, not on the tab object — writing them onto
      // the tab would mutate a value inside EditorStore.
      markers: markers,
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
      },
      onCloseOthers: function (id) { handleCloseOtherTabs(paneId, id); },
      onCloseSaved: function () { handleCloseSavedTabs(paneId); },
      onCloseAll: function () { handleCloseEditorsInGroup(paneId); },
      onNewFile: function () { TabManager.openUntitledTab(paneId); }
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

  // The diagram lives in an editor tab, not the sidebar: a layered graph is
  // inherently wide and a ~300px panel can only ever show its first column.
  // The sidebar tab is the entry point and the searchable model list.
  var MODEL_GRAPH_TAB_ID = 'mbeditor://model-graph';
  function openModelGraphTab() {
    var st = EditorStore.getState();
    var paneId = st.focusedPaneId;

    var existing = null;
    st.panes.forEach(function (p) {
      if (!existing && p.tabs.some(function (t) { return t.id === MODEL_GRAPH_TAB_ID; })) {
        existing = p.id;
      }
    });
    if (existing) {
      EditorStore.setState({
        panes: st.panes.map(function (p) {
          return p.id === existing ? Object.assign({}, p, { activeTabId: MODEL_GRAPH_TAB_ID }) : p;
        }),
        focusedPaneId: existing
      });
      return;
    }

    var pane = st.panes.find(function (p) { return p.id === paneId; }) || st.panes[0];
    if (!pane) return;

    var newTab = {
      id: MODEL_GRAPH_TAB_ID, path: MODEL_GRAPH_TAB_ID, name: 'Model Graph',
      dirty: false, content: '', isModelGraph: true
    };
    EditorStore.setState({
      panes: st.panes.map(function (p) {
        return p.id === pane.id
          ? Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: MODEL_GRAPH_TAB_ID })
          : p;
      }),
      focusedPaneId: pane.id
    });
    loadModelGraph(false);
  }

  var CHANGELOG_TAB_ID = 'mbeditor://changelog';
  function openChangelogTab() {
    var st = EditorStore.getState();
    // Focus existing tab if already open
    var foundPaneId = null, foundTab = null;
    st.panes.forEach(function(p) {
      if (!foundTab) {
        var t = p.tabs.find(function(tab) { return tab.id === CHANGELOG_TAB_ID; });
        if (t) { foundTab = t; foundPaneId = p.id; }
      }
    });
    if (foundTab) {
      // If the tab was restored from a persisted state that didn't include
      // isChangelog (pre-v0.7.4), patch it so the pane renders ChangelogView.
      var switchPanes = st.panes.map(function(p) {
        if (p.id === foundPaneId) {
          var patchedTabs = p.tabs.map(function(t) {
            if (t.id === CHANGELOG_TAB_ID && !t.isChangelog) {
              return Object.assign({}, t, { isChangelog: true });
            }
            return t;
          });
          return Object.assign({}, p, { tabs: patchedTabs, activeTabId: CHANGELOG_TAB_ID });
        }
        return p;
      });
      EditorStore.setState({ panes: switchPanes, focusedPaneId: foundPaneId });
      return;
    }
    // Open in focused pane
    var paneId = st.focusedPaneId;
    var pane = st.panes.find(function(p) { return p.id === paneId; }) || st.panes[0];
    if (!pane) return;
    paneId = pane.id;
    var newTab = { id: CHANGELOG_TAB_ID, path: CHANGELOG_TAB_ID, name: "What's New", dirty: false, content: '', isChangelog: true };
    var newPanes = st.panes.map(function(p) {
      if (p.id === paneId) return Object.assign({}, p, { tabs: p.tabs.concat(newTab), activeTabId: CHANGELOG_TAB_ID });
      return p;
    });
    EditorStore.setState({ panes: newPanes, focusedPaneId: paneId });
    // Fetch content if not already loaded
    if (!changelogState || changelogState.error) {
      setChangelogState({ loading: true, content: null, error: null });
      FileService.getChangelog()
        .then(function(data) { setChangelogState({ loading: false, content: data.content || '', error: null }); })
        ['catch'](function() { setChangelogState({ loading: false, content: null, error: 'Could not load changelog.' }); });
    }
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
      // The slot claims all the room between the title and the buttons; the
      // search pill then takes 75% of it, centred. Sizing the pill against a
      // slot rather than against the title bar keeps it proportional to the
      // actual gap as the toolbar's button labels grow and shrink.
      React.createElement(
        'div',
        { className: 'ide-titlebar-search-slot' },
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
        )
      ),
      React.createElement(
        "div",
        { style: { marginLeft: "auto", display: "flex", gap: "4px", height: "100%", alignItems: "center" } },
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: function () {
              return activeTab && handleSave(focusedPane.id, activeTab);
            }, disabled: loading.save || !activeTab || !activeTab.dirty, 'aria-busy': !!loading.save,
            title: "Save the active file (Ctrl+S)" },
          !loading.save && React.createElement("i", { className: "fas fa-save" }),
          !toolbarIconOnly && !loading.save && " Save",
          !loading.save && activeTab && activeTab.dirty ? " ●" : ""
        ),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleSaveAll, disabled: loading.saveAll || !state.panes.flatMap(function (p) {
              return p.tabs;
            }).some(function (t) {
              return t.dirty;
            }), 'aria-busy': !!loading.saveAll, title: "Save every file with unsaved changes" },
          !loading.saveAll && React.createElement(
            "i",
            { className: "fas fa-save", style: { position: 'relative' } },
            React.createElement("i", { className: "fas fa-save", style: { position: 'absolute', top: '-2px', left: '3px', fontSize: '9px', opacity: 0.8 } })
          ),
          !toolbarIconOnly && !loading.saveAll && " Save All"
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          'div',
          { role: 'group' },
          React.createElement(
            "button",
            { className: "statusbar-btn", onClick: function() { var ed = window.__mbeditorActiveEditor; if (ed) ed.trigger('keyboard', 'undo', null); }, disabled: !activeTab || !state.canUndo, title: "Undo (Ctrl+Z)" },
            React.createElement("i", { className: "fas fa-undo" }),
            !toolbarIconOnly && " Undo"
          ),
          React.createElement(
            "button",
            { className: "statusbar-btn", onClick: function() { var ed = window.__mbeditorActiveEditor; if (ed) ed.trigger('keyboard', 'redo', null); }, disabled: !activeTab || !state.canRedo, title: "Redo (Ctrl+Y)" },
            React.createElement("i", { className: "fas fa-redo" }),
            !toolbarIconOnly && " Redo"
          )
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleFormat, disabled: loading.format || !canLintAndFormat, 'aria-busy': !!loading.format, title: "Format this document" },
          !loading.format && React.createElement("i", { className: "fas fa-magic" }),
          !toolbarIconOnly && !loading.format && " Format"
        ),
        React.createElement(
          "button",
          { className: "statusbar-btn", onClick: handleFormatAll, disabled: loading.format || !canLintAndFormat, 'aria-busy': !!loading.format, title: "Format all open documents" },
          React.createElement("i", { className: "fas fa-wand-magic-sparkles" }),
          !toolbarIconOnly && !loading.format && " Format All"
        ),
        hasGitBranch && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            { type: "button", className: "statusbar-btn", onClick: toggleGitPanel,
              title: (showGitPanel ? "Hide" : "Show") + " the git panel (Ctrl+Shift+G)" },
            React.createElement("i", { className: "fas fa-code-branch" }),
            !toolbarIconOnly && " Git"
          )
        ),
        // Collaboration trouble chip. Deliberately not shown when everything is
        // healthy and you are simply alone — that was the whole point of hiding
        // the solo chip. It appears only when a condition pairing needs has
        // actually failed, so silence means "nobody here" and never "quietly
        // broken", which is exactly the ambiguity that made a real pairing
        // failure impossible to diagnose from the other machine.
        collabTrouble && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            {
              type: "button",
              className: "statusbar-btn mbeditor-collab-trouble",
              title: "Pairing is not available — click for details",
              onClick: function () { setCollabDiagOpen(true); }
            },
            React.createElement("i", { className: "fas fa-user-slash" }),
            !toolbarIconOnly && " Pairing off"
          )
        ),
        // Your own chip appears only once someone else is actually connected.
        // Alone it told you nothing — Action Cable is up in any normal dev setup,
        // so it sat in the toolbar permanently announcing a session of one. While
        // pairing it earns its place: it is how your peers see you, and it is the
        // control for renaming yourself.
        collabEnabled && collabIdentity && collabPeerIds.length > 0 && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          React.createElement(
            "button",
            {
              type: "button",
              className: "statusbar-btn",
              onMouseEnter: function (e) { openCollabHover('__me__', e); },
              onMouseLeave: function () { setCollabHover(null); },
              onClick: function () { CollaborationIdentity.editName(); }
            },
            React.createElement("i", {
              className: "fas fa-circle collab-pulse",
              style: { color: collabIdentity.color, fontSize: "0.7em", marginRight: "2px" }
            }),
            !toolbarIconOnly && (" " + collabIdentity.name)
          )
        ),
        collabEnabled && collabPeerIds.length > 0 && React.createElement(
          React.Fragment,
          null,
          React.createElement("div", { className: "statusbar-sep" }),
          collabPeerIds.map(function (cid) {
            var peer = collabRoster[cid];
            var file = peer.current_file;
            var name = peer.name || 'Anonymous';
            var colour = peer.colour || '#888888';
            var following = followedClientId === cid;
            // Solid dot: they are in the file you are looking at, so their caret
            // is on screen. Hollow ring: they are somewhere else and there is
            // nothing to see — without this the chip looked identical either way
            // and a peer's caret just vanished with no explanation.
            var elsewhere = file !== presenceFile;
            return React.createElement(
              "button",
              {
                key: cid,
                type: "button",
                className: "statusbar-btn",
                style: following
                  ? { background: 'color-mix(in srgb, ' + colour + ' 28%, transparent)' }
                  : undefined,
                onMouseEnter: function (e) { openCollabHover(cid, e); },
                onMouseLeave: function () { setCollabHover(null); },
                onClick: function () { toggleFollow(cid); }
              },
              React.createElement("i", {
                className: (following ? "fas fa-eye" : (elsewhere ? "far fa-circle" : "fas fa-circle")) +
                  " collab-pulse",
                style: { color: colour, fontSize: "0.7em", marginRight: "2px" }
              }),
              collabPeerLabels && (" " + name),
              // Where they went, when they are not where you are. Basename only —
              // the chip has ~110px to spend and the full path is in the tooltip.
              collabPeerLabels && elsewhere && file && React.createElement(
                "span",
                { style: { opacity: 0.65, marginLeft: "4px" } },
                file.split('/').pop()
              )
            );
          })
        ),
        React.createElement("div", { className: "statusbar-sep" }),
        React.createElement(
          "button",
          { type: "button", className: "statusbar-btn", onClick: function () { return setShowHelp(true); }, title: "Keyboard shortcuts & help" },
          React.createElement("i", { className: "fas fa-keyboard" }),
          !toolbarIconOnly && " Help"
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
            !toolbarIconOnly && " Install"
          )
        )
      )
    ),
    collabHover && (function () {
      var isMe = collabHover.cid === '__me__';
      var peer = isMe ? null : collabRoster[collabHover.cid];
      // The peer can leave between hover and paint — the roster is the authority.
      if (!isMe && !peer) return null;

      var stats = isMe ? { rtt: ownRttRef.current } : (peerStatsRef.current[collabHover.cid] || {});
      var name = isMe ? collabIdentity.name : (peer.name || 'Anonymous');
      var colour = isMe ? collabIdentity.color : (peer.colour || '#888888');
      var file = isMe ? presenceFile : peer.current_file;
      // Server-measured against a monotonic clock, so it is not our arrival time
      // and no clock skew enters into it.
      var idle = typeof stats.idle === 'number' ? stats.idle : null;

      return React.createElement(
        'div',
        { className: 'collab-hovercard', style: { top: collabHover.top + 'px', right: collabHover.right + 'px' } },
        React.createElement(
          'div',
          { className: 'collab-hovercard-name' },
          React.createElement('span', { className: 'collab-hovercard-swatch', style: { background: colour } }),
          name,
          isMe && React.createElement('span', { style: { opacity: 0.6, fontWeight: 400 } }, ' (you)')
        ),
        React.createElement('div', { className: 'collab-hovercard-row' }, file || 'No file open'),
        typeof stats.rtt === 'number' && React.createElement(
          'div', { className: 'collab-hovercard-row' }, 'Latency ' + Math.round(stats.rtt) + ' ms'
        ),
        // Everyone in the roster is connected — the server evicts on disconnect —
        // so this is not a liveness warning. It says their heartbeat has slowed,
        // which is what a browser does to a backgrounded tab's timers, and is why
        // their caret may be behind. Silent under 20s, where it would only ever
        // read "5s ago".
        idle !== null && idle >= 20 && React.createElement(
          'div', { className: 'collab-hovercard-row' }, 'Idle ' + idle + 's'
        ),
        React.createElement(
          'div',
          { className: 'collab-hovercard-hint' },
          isMe ? 'Click to change your name'
               : (followedClientId === collabHover.cid ? 'Click to stop following' : 'Click to follow')
        )
      );
    })(),
    // The diagnostics panel. Every condition listed with its own state, because
    // the person who needs this is usually on the other machine and cannot paste
    // a console snippet back.
    collabDiagOpen && (function () {
      var d = CollaborationService.diagnostics();
      return React.createElement(
        'div',
        { className: 'mbeditor-modal-backdrop', onClick: function () { setCollabDiagOpen(false); } },
        React.createElement(
          'div',
          { className: 'mbeditor-collab-diag', onClick: function (e) { e.stopPropagation(); } },
          React.createElement('div', { className: 'mbeditor-collab-diag-title' }, 'Pair programming status'),
          React.createElement(
            'ul',
            { className: 'mbeditor-collab-diag-list' },
            d.checks.map(function (c) {
              return React.createElement(
                'li',
                { key: c.key, className: 'mbeditor-collab-diag-row' + (c.ok ? '' : ' is-bad') },
                React.createElement('i', { className: c.ok ? 'fas fa-check' : 'fas fa-times' }),
                React.createElement(
                  'div',
                  null,
                  React.createElement('div', { className: 'mbeditor-collab-diag-label' }, c.label),
                  !c.ok && React.createElement('div', { className: 'mbeditor-collab-diag-detail' }, c.detail)
                )
              );
            })
          ),
          React.createElement(
            'div',
            { className: 'mbeditor-collab-diag-foot' },
            d.ok
              ? 'Pairing is working.'
              : 'The first failing item above is the one to fix; the rest follow from it.'
          ),
          React.createElement('button', {
            type: 'button', className: 'ide-model-graph-btn',
            onClick: function () { setCollabDiagOpen(false); }
          }, 'Close')
        )
      );
    })(),
    showHelp && React.createElement(ShortcutHelp, { onClose: function () { return setShowHelp(false); } }),
    React.createElement(
      "div",
      { className: "ide-body", id: "ide-body-container" },
      /* Activity bar — always visible, 60px wide */
      !zenMode && React.createElement(
        "div",
        { className: "ide-activity-bar" },
        React.createElement(
          "div",
          { className: "ide-activity-bar-top" },
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-activity-btn" + (!sidebarCollapsed && activeSidebarTab === 'explorer' ? ' active' : ''),
              title: "Explorer",
              onClick: function() { handleActivityBarClick('explorer'); }
            },
            React.createElement("i", { className: "far fa-folder" })
          ),
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-activity-btn" + (!sidebarCollapsed && activeSidebarTab === 'search' ? ' active' : ''),
              title: "Search",
              onClick: function() { handleActivityBarClick('search'); }
            },
            React.createElement("i", { className: "fas fa-search" })
          ),
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-activity-btn" + (!sidebarCollapsed && activeSidebarTab === 'rails' ? ' active' : ''),
              title: "Rails",
              onClick: function() { handleActivityBarClick('rails'); }
            },
            React.createElement("i", { className: "far fa-gem" })
          ),
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-activity-btn" + (activeTab && activeTab.isModelGraph ? ' active' : ''),
              title: "Model graph",
              onClick: function() { handleActivityBarClick('models'); }
            },
            React.createElement("i", { className: "fas fa-project-diagram" })
          )
        ),
        React.createElement(
          "div",
          { className: "ide-activity-bar-bottom" },
          React.createElement(
            "button",
            {
              type: "button",
              className: "ide-activity-btn" + (activeTab && activeTab.isSettings ? ' active' : ''),
              title: "Editor Preferences",
              onClick: openSettingsTab
            },
            React.createElement("i", { className: "fas fa-cog" })
          )
        )
      ),
      /* Panel content — shown when not collapsed and not in zen mode */
      !sidebarCollapsed && !zenMode && React.createElement(
        "div",
        { className: "ide-sidebar", style: { width: sidebarWidth + "px" } },
        React.createElement("div", { className: "sidebar-panel-title" },
          activeSidebarTab === 'explorer' ? 'Explorer' :
          activeSidebarTab === 'search' ? 'Search' :
          activeSidebarTab === 'rails' ? 'Rails' : ''
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
                          // The name ellipsises in a narrow sidebar, so the row
                          // carries the full path the way file-tree rows do.
                          title: tab.path || tab.name,
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
                          // minWidth:0 on both the row's name cell and the label
                          // itself: without it a flex item refuses to shrink
                          // below its content, so a long filename pushed out
                          // under the (formerly absolute) action buttons.
                          { className: "tree-item-name", style: { display: 'flex', alignItems: 'center', minWidth: 0 } },
                          React.createElement(
                            "span",
                            { style: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', minWidth: 0 } },
                            tab.name
                          ),
                          tab.dirty && React.createElement("i", { className: "fas fa-circle", style: { fontSize: '5px', color: '#e3d286', marginLeft: '6px', marginTop: '1px', flexShrink: 0 } })
                        ),
                        React.createElement(
                          "div",
                          // In flow, not absolute — the buttons now claim their
                          // own width so the name truncates instead of running
                          // underneath them.
                          { className: "tab-actions", style: { display: 'flex', alignItems: 'center', flexShrink: 0, marginLeft: 'auto' } },
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
                              }, style: { padding: '0 4px', cursor: 'pointer', opacity: 0.6 },
                              // See TabBar: role="button" would pick up Pico's
                              // button skin from the host app and square this off.
                              title: "Close " + tab.name + (tab.dirty ? " (unsaved changes)" : "") },
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
                  title: "Refresh workspace",
                  iconClass: "fas fa-sync-alt",
                  ariaBusy: !!loading.refreshWorkspace,
                  onClick: handleRefreshWorkspace,
                  disabled: !!loading.refreshWorkspace
                }),
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
                  title: "Upload files",
                  iconClass: 'fas fa-upload',
                  onClick: function () {
                    return openImportDialog(selectedTreeNode);
                  }
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
              items: fileTreeItems,
              onSelect: handleSoftOpenFile,
              activePath: editorPrefs.autoRevealInExplorer !== false ? (activeTab && activeTab.path) : null,
              selectedPaths: selectedPaths,
              anchorPath: selectedTreePath,
              onNodeSelect: handleNodeSelect,
              onMultiSelect: handleMultiSelect,
              onMove: handleMoveNodes,
              onImportFiles: handleImportFiles,
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
            React.createElement("textarea", {
              className: "search-input search-query-input",
              rows: 2,
              placeholder: "Find in files…",
              value: searchQuery,
              onChange: handleSearchChange,
              // Enter triggers the search without inserting a newline; Shift+Enter
              // still adds one for multi-line queries.
              onKeyDown: function(e) {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault();
                  if (searchQuery) _debouncedSearch(searchQuery);
                }
              }
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

            // Grouped into a VS Code-style tree, then flattened straight back
            // into one row array: the windowing below is unchanged, it just
            // indexes rows instead of results. Every tier emits its hits file
            // by file, so a run of the same path is the whole group.
            var rows = [];
            var group = null;
            allResults.forEach(function (res, idx) {
              if (!group || group.file !== res.file) {
                group = { type: 'file', file: res.file, count: 0 };
                rows.push(group);
              }
              group.count += 1;
              if (!searchCollapsedFiles[res.file]) rows.push({ type: 'match', res: res, idx: idx });
            });
            var rowCount = rows.length;

            // Only the rows on screen (plus a small buffer either side) are
            // built. Everything else is represented by the height of the
            // spacer, so the scrollbar and every scroll position stay exactly
            // as they would be for the full list.
            var winStart = Math.max(0, Math.floor(searchViewport.scrollTop / SEARCH_ROW_HEIGHT) - SEARCH_ROW_BUFFER);
            var winEnd   = Math.min(rowCount, Math.ceil((searchViewport.scrollTop + (searchViewport.height || 600)) / SEARCH_ROW_HEIGHT) + SEARCH_ROW_BUFFER);
            var visible  = rows.slice(winStart, winEnd);

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
                    ref: attachSearchResults,
                    onScroll: handleSearchResultsScroll
                  },
                  React.createElement(
                    "div",
                    { style: { height: rowCount * SEARCH_ROW_HEIGHT, position: 'relative' } },
                    visible.map(function(row, vi) {
                      var i = winStart + vi;
                      var top = { position: 'absolute', top: i * SEARCH_ROW_HEIGHT, left: 0, right: 0 };

                      if (row.type === 'file') {
                        var fileName = row.file.split('/').pop();
                        var dir = row.file.slice(0, row.file.length - fileName.length).replace(/\/$/, '');
                        var collapsed = !!searchCollapsedFiles[row.file];
                        return React.createElement(
                          "div",
                          {
                            key: 'f:' + row.file,
                            className: "search-result-file-row",
                            style: top,
                            title: row.file,
                            onClick: (function(f) { return function() { toggleSearchFile(f); }; })(row.file)
                          },
                          React.createElement("i", { className: "codicon codicon-chevron-" + (collapsed ? "right" : "down") + " search-result-chevron" }),
                          React.createElement("i", { className: (window.getFileIcon ? window.getFileIcon(fileName) : 'far fa-file-code') + " search-result-icon" }),
                          React.createElement("span", { className: "search-result-file-name" }, fileName),
                          dir && React.createElement("span", { className: "search-result-file-dir" }, dir),
                          React.createElement("span", { className: "search-result-count" }, row.count)
                        );
                      }

                      var res = row.res;
                      return React.createElement(
                        "div",
                        {
                          key: 'm:' + row.idx,
                          className: "search-result-item",
                          style: top,
                          title: res.file + ":" + res.line,
                          // col..end_col selects the match and leaves the cursor
                          // just past it, which is where you want to start
                          // typing after jumping to a hit — not column 1.
                          onClick: (function(r) { return function() { handleSelectFile(r.file, r.file.split('/').pop(), r.line, r.col || r.end_col, r.end_col); }; })(res)
                        },
                        React.createElement("span", { className: "search-result-line-num" }, res.line),
                        (function () {
                          var parts = searchMatchParts(res);
                          if (!parts) return React.createElement("span", { className: "search-result-text" }, res.text);
                          return React.createElement(
                            "span",
                            { className: "search-result-text search-result-text-split" },
                            React.createElement("span", { className: "search-result-pre" }, parts[0]),
                            React.createElement("mark", { className: "search-result-match" }, parts[1]),
                            React.createElement("span", { className: "search-result-post" }, parts[2])
                          );
                        })()
                      );
                    })
                  ),
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
        ),
        activeSidebarTab === 'rails' && React.createElement(
          "div",
          { className: "rails-panel" },
          (function() {
            var labels = Object.keys(railsFilesMap).sort();
            if (labels.length === 0) {
              return React.createElement("div", { className: "rails-panel-empty" }, "Open a Rails file to see related files.");
            }
            var sections = labels.map(function(label) {
              var entry = railsFilesMap[label];
              var files = entry && entry.files;
              var loading = entry && entry.loading;
              if (loading && !files) {
                return React.createElement("div", { key: label + '_loading', className: "rails-panel-loading" },
                  React.createElement("i", { className: "fas fa-spinner fa-spin" }),
                  " Loading…"
                );
              }
              if (!files || Object.keys(files).length === 0) return null;
              var allFiles = [];
              ['model', 'controller', 'helper', 'concerns', 'tests', 'views'].forEach(function(key) {
                var group = files[key];
                if (group && group.length) allFiles = allFiles.concat(group);
              });
              var customGroups = files['custom'];
              if (customGroups && typeof customGroups === 'object') {
                Object.keys(customGroups).forEach(function(base) {
                  var grpFiles = customGroups[base];
                  if (grpFiles && grpFiles.length) allFiles = allFiles.concat(grpFiles);
                });
              }
              if (allFiles.length === 0) return null;
              var schemaBtn = React.createElement(
                'button',
                {
                  className: 'rails-schema-btn' + (schemaLoadingLabel === label ? ' rails-schema-btn-loading' : ''),
                  title: 'View database schema for ' + label,
                  onClick: (function(lbl) { return function(e) {
                    e.stopPropagation();
                    openSchemaModal(lbl);
                  }; })(label)
                },
                React.createElement('i', {
                  className: schemaLoadingLabel === label
                    ? 'fas fa-spinner fa-spin'
                    : 'fas fa-table'
                })
              );
              return React.createElement(
                CollapsibleSection,
                {
                  key: label,
                  title: label.toUpperCase(),
                  isCollapsed: !!railsGroupsCollapsed[label],
                  actions: schemaBtn,
                  onToggle: (function(captured) { return function(isCollapsed) {
                    setRailsGroupsCollapsed(function(prev) {
                      var next = Object.assign({}, prev);
                      next[captured] = isCollapsed;
                      return next;
                    });
                  }; })(label)
                },
                React.createElement(
                  "div",
                  null,
                  allFiles.map(function(f) {
                    return React.createElement(
                      "div", {
                        key: f.path,
                        className: "rails-group-item",
                        onClick: (function(file) { return function() { handleSelectFile(file.path, file.name); }; })(f),
                        title: f.path
                      },
                      React.createElement("i", { className: "tree-item-icon " + (window.getFileIcon ? window.getFileIcon(f.name) : 'far fa-file-code') + " tree-file-icon" }),
                      React.createElement("span", { className: "rails-group-item-name" }, f.name),
                      f.kind && React.createElement("span", { className: "rails-group-item-kind" }, f.kind),
                      dirtyPaths[f.path] && React.createElement("span", { className: "rails-group-item-dirty" }, "●")
                    );
                  })
                )
              );
            });
            if (railsOverflow > 0) {
              sections = sections.concat([React.createElement(
                "div", { key: '__overflow', className: "rails-panel-overflow" },
                "+" + railsOverflow + " more — close tabs to show all"
              )]);
            }
            return sections;
          })()
        )
      ),
      /* Sidebar resize divider — only when panel is open */
      !sidebarCollapsed && !zenMode && React.createElement("div", {
        className: "panel-divider sidebar-divider " + (activeResizeMode === 'sidebar' ? 'active' : ''),
        onMouseDown: startSidebarResize,
        role: "separator",
        "aria-orientation": "vertical",
        "aria-label": "Resize explorer panel"
      }),
      // Column wrapping the split panes and the bottom drawers. ide-main is a
      // row of panes, so the drawers need a vertical parent to push against;
      // as absolute overlays they covered the editor instead.
      React.createElement(
      "div",
      { className: "ide-center-column" },
      React.createElement(
        "div",
        {
          id: "ide-main-split-container",
          className: "ide-main",
          style: { position: 'relative', display: 'flex', flexDirection: 'row', width: '100%', flex: '1 1 auto', minHeight: 0, cursor: activeResizeMode === 'pane' ? 'col-resize' : 'default', userSelect: activeResizeMode ? 'none' : 'auto' },
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
        isSwitchingBranch && React.createElement('div', { className: 'branch-switch-overlay' },
          React.createElement('span', null, 'Switching branch…')
        ),
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
              } else if (pActiveTab.isModelGraph) {
                content = React.createElement(ModelGraph, {
                  graph: modelGraph,
                  loading: modelGraphLoading,
                  onRefresh: function () { loadModelGraph(true); },
                  onOpenModel: function (model) { openSchemaModal(model.name); }
                });
              } else if (pActiveTab.isChangelog) {
                content = React.createElement(ChangelogView, {
                  changelogState: changelogState,
                  onLoad: function() {
                    if (!changelogState || (!changelogState.content && !changelogState.loading && !changelogState.error)) {
                      setChangelogState({ loading: true, content: null, error: null });
                      FileService.getChangelog()
                        .then(function(data) { setChangelogState({ loading: false, content: data.content || '', error: null }); })
                        ['catch'](function() { setChangelogState({ loading: false, content: null, error: 'Could not load changelog.' }); });
                    }
                  }
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Color theme for the editor' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Editor font size in pixels (8–32)' },
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
                      'label', { className: 'ide-settings-row-full', title: 'Font stack used in the editor — the first font available on your system is used' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Number of spaces per indentation level (also sets Prettier tab width)' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Insert spaces instead of tab characters when pressing Tab' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'How long lines are handled — Off: scroll horizontally, On: wrap at viewport width, Column: wrap at a fixed column' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Show line numbers in the gutter — On, Off, or Relative (useful with Vim mode)' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Render whitespace characters visually — None, Selection only, Boundary (leading/trailing), or All' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Show a scaled-down overview of the file on the right edge of the editor' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Minimap'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.minimap),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { minimap: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Allow scrolling past the last line so it can be positioned at the top of the viewport' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Scroll past end'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.scrollBeyondLastLine),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { scrollBeyondLastLine: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Colorize matching bracket pairs with distinct colors to make nesting easier to read' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Bracket colors'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.bracketPairColorization),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { bracketPairColorization: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Enable Vim keybindings (Normal/Insert/Visual modes). Press Escape to return to Normal mode.' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Shape of the text cursor in the editor' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Cursor animation style — Blink (on/off), Smooth (fade), Phase (offset fade), Expand (grow), or Solid (no animation)' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Re-indent and auto-close blocks as you type (e.g. after pressing Enter inside {})' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Format on type'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.formatOnType === true,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { formatOnType: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Format the file before every save — RuboCop -A for Ruby, Prettier for JS/JSX/CSS/HTML/Markdown' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Format on save'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.formatOnSave === true,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { formatOnSave: v }); }); }
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Prettier: maximum line length before wrapping (40–200)' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Prettier: add trailing commas in multi-line expressions — All (ES2017+), ES5 (objects/arrays only), or None' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Prettier: add semicolons at the end of statements' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Semicolons'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.prettierSemi !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { prettierSemi: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: "Prettier: use single quotes instead of double quotes for strings" },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Single quotes'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!editorPrefs.prettierSingleQuote,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { prettierSingleQuote: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Prettier: add spaces inside object literal braces, e.g. { a: 1 } vs {a: 1}' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Automatically scroll the file explorer to reveal and highlight the file you are editing' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Explorer follows active file'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.autoRevealInExplorer),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { autoRevealInExplorer: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Jump to a file in the explorer by typing its name when the sidebar is focused' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Explorer type-ahead'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.fileTreeTypeahead !== false),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { fileTreeTypeahead: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Show hidden files and directories (those starting with a dot, e.g. .env, .gitignore) in the file explorer' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Show dotfiles'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.showDotFiles),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { showDotFiles: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-half', title: 'Scroll: tabs overflow horizontally with a scrollbar; Wrap: tabs flow onto multiple rows' },
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
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Include folder names in the Quick Open picker (Ctrl+P / Cmd+P) results, not just files' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Quick Open: show folders'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: !!(editorPrefs.quickOpenShowFolders),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { quickOpenShowFolders: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Hide toolbar button labels and show only icons, giving more horizontal space' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Toolbar: icons only'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        // The stored preference, not the derived value: at a
                        // narrow width the box would otherwise show as checked
                        // and unchecking it would appear to do nothing.
                        checked: !!(editorPrefs.toolbarIconOnly),
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { toolbarIconOnly: v }); }); }
                      })
                    ),

                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Keep the search/replace text when switching between files in the editor' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Persist find state across files'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.persistFindState !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { persistFindState: v }); }); }
                      })
                    ),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Save which files are open per branch and restore them when switching branches. Disable to always start with a clean slate when switching.' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Restore tabs on branch switch'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.branchStateRestore !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { branchStateRestore: v }); }); }
                      })
                    ),

                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Show the verb and path that route to each controller action after its def line, and mark public actions nothing routes to' },
                      React.createElement('span', { className: 'ide-settings-label' }, 'Controller route hints'),
                      React.createElement('input', {
                        type: 'checkbox',
                        className: 'ide-settings-checkbox',
                        checked: editorPrefs.routeHints !== false,
                        onChange: function(e) { var v = e.target.checked; setEditorPrefs(function(p) { return Object.assign({}, p, { routeHints: v }); }); }
                      })
                    ),

                    /* ── RuboCop ─────────────────────────────────── */
                    React.createElement('div', { className: 'ide-settings-section-header' }, 'RuboCop'),
                    React.createElement(
                      'label', { className: 'ide-settings-row ide-settings-row-check', title: 'Run RuboCop in the background and show lint warnings/errors as markers in the editor gutter' },
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
                        title: 'Restore every editor preference on this page to its default',
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
                  treeData: treeData,
                  testResult: testResult,
                  testPanelFile: testPanelFile,
                  testInlineVisible: testInlineVisible,
                  editorPrefs: editorPrefs,
                  monacoReady: monacoReady,
                  onFormat: function() { onFormatRef.current(); },
                  onSave: function() { handleSave(pane.id, pActiveTab); },
                  onRunTestAtCursor: handleRunTestAtCursor,
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
                React.createElement(FileReloadBanner, {
                  pendingReloads: (state.pendingReloads || []).filter(function (r) { return r.paneId === pane.id; }),
                  onSaveAndReload: handleSaveAndReload,
                  onDiscardAndReload: handleDiscardAndReload,
                  onKeepMine: handleKeepMine
                }),
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
      showLogPanel && !zenMode && React.createElement(window.LogPanel || LogPanel, {
        onClose: function () { setShowLogPanel(false); }
      }),
      showProblemsPanel && !zenMode && React.createElement(window.ProblemsPanel || ProblemsPanel, {
        onClose: function () { setShowProblemsPanel(false); },
        onOpenFile: function (path, line, col) {
          handleSelectFile(path, path.split('/').pop(), line, col);
        },
        // `rubocop -a` writes through a subprocess, so the server's
        // files_changed broadcast is the only notice — and there is no
        // broadcast at all without a cable connection. Re-read every open tab
        // here too: clean tabs take the corrected text (and re-lint), dirty
        // ones get the usual reload prompt instead of being silently clobbered.
        onFilesRewritten: function () { checkOpenTabsForExternalChanges(); }
      }),
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
      ),
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
      React.createElement(
        "button",
        {
          type: "button",
          className: "statusbar-btn statusbar-problems" + (showProblemsPanel ? " active" : ""),
          onClick: toggleProblemsPanel,
          title: problemCounts.errors + " error(s), " + problemCounts.warnings +
            " warning(s) in open files — click to open Problems"
        },
        React.createElement("i", { className: "fas fa-bug statusbar-problems-error-icon" }),
        React.createElement("span", { className: "statusbar-problems-count" }, problemCounts.errors),
        React.createElement("i", { className: "fas fa-exclamation-triangle statusbar-problems-warning-icon" }),
        React.createElement("span", { className: "statusbar-problems-count" }, problemCounts.warnings)
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
      React.createElement(
        "button",
        {
          type: "button",
          className: "statusbar-btn statusbar-logs-btn" + (showLogPanel ? " active" : ""),
          onClick: toggleLogPanel,
          title: "Toggle Rails log (Ctrl+Shift+L)"
        },
        React.createElement("i", { className: "fas fa-stream" }),
        " Logs"
      ),
      React.createElement(
        "button",
        {
          type: "button",
          className: "statusbar-btn" + (editorPrefs.renderWhitespace === 'all' ? " active" : ""),
          title: editorPrefs.renderWhitespace === 'all'
            ? "Hide whitespace characters"
            : "Show whitespace characters (tabs, spaces, control characters)",
          "aria-pressed": editorPrefs.renderWhitespace === 'all',
          onClick: function () {
            setEditorPrefs(function (p) {
              return _extends({}, p, {
                renderWhitespace: p.renderWhitespace === 'all' ? 'none' : 'all'
              });
            });
          }
        },
        React.createElement("i", { className: "fas fa-paragraph" })
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
        "button",
        { type: "button", className: "statusbar-version statusbar-btn", onClick: openChangelogTab, title: "What's New — click to open changelog" },
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
        contextMenu.node && contextMenu.node.type === 'file' && React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('download');
            } },
          React.createElement("i", { className: "fas fa-download context-menu-icon" }),
          " Download"
        ),
        React.createElement(
          "div",
          { className: "context-menu-item", onClick: function () {
              return handleContextMenuAction('upload');
            } },
          React.createElement("i", { className: "fas fa-upload context-menu-icon" }),
          " Upload Files Here..."
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
    ),

    /* ── Upload dialog ─────────────────────────────────────────────────── */
    importDialog && React.createElement(ImportDialog, {
      initialFolder: importDialog.initialFolder,
      docs: SearchService.allDocs(),
      onCancel: function () { setImportDialog(null); },
      onImport: confirmImportDialog
    }),

    /* ── Import conflict modal ─────────────────────────────────────────── */
    importConflict && React.createElement(ImportConflictModal, {
      conflicts: importConflict.result.conflicts,
      errors: importConflict.result.errors,
      onResolve: resolveImportConflict
    }),

    /* ── Schema modal ──────────────────────────────────────────────────── */
    schemaModal && React.createElement(
      'div',
      {
        className: 'schema-modal-overlay',
        onClick: function() { setSchemaModal(null); }
      },
      React.createElement(
        'div',
        {
          className: 'schema-modal',
          onClick: function(e) { e.stopPropagation(); }
        },
        /* Header */
        React.createElement(
          'div', { className: 'schema-modal-header' },
          React.createElement(
            'div', { className: 'schema-modal-title' },
            React.createElement('i', { className: 'fas fa-table', style: { marginRight: '8px', opacity: 0.7 } }),
            schemaModal.label,
            !schemaModal.error && schemaModal.data && React.createElement(
              'span', { className: 'schema-modal-table-name' }, schemaModal.data.table
            )
          ),
          React.createElement(
            'button',
            { className: 'schema-modal-close', onClick: function() { setSchemaModal(null); }, title: 'Close' },
            React.createElement('i', { className: 'fas fa-times' })
          )
        ),
        /* Body */
        React.createElement(
          'div', { className: 'schema-modal-body' },
          schemaModal.error
            ? React.createElement('div', { className: 'schema-modal-error' },
                React.createElement('i', { className: 'fas fa-exclamation-circle', style: { marginRight: '8px' } }),
                schemaModal.error
              )
            : [
              /* Columns table */
              React.createElement(
                'table', { key: 'cols', className: 'schema-table' },
                React.createElement(
                  'thead', null,
                  React.createElement(
                    'tr', null,
                    React.createElement('th', null, 'Column'),
                    React.createElement('th', null, 'Type'),
                    React.createElement('th', null, 'Options')
                  )
                ),
                React.createElement(
                  'tbody', null,
                  schemaModal.data.columns.map(function(col) {
                    var opts = [];
                    if (col.null === false) opts.push('NOT NULL');
                    if (col.default !== undefined && col.default !== null) opts.push('default: ' + col.default);
                    if (col.limit) opts.push('limit: ' + col.limit);
                    if (col.precision) opts.push('precision: ' + col.precision + (col.scale ? ', scale: ' + col.scale : ''));
                    if (col.primary_key) opts.push('PK');
                    return React.createElement(
                      'tr', { key: col.name },
                      React.createElement('td', { className: 'schema-col-name' }, col.name),
                      React.createElement('td', { className: 'schema-col-type schema-type-' + col.type }, col.type),
                      React.createElement('td', { className: 'schema-col-opts' }, opts.join(' · ') || '—')
                    );
                  })
                )
              ),
              /* Indexes */
              schemaModal.data.indexes && schemaModal.data.indexes.length > 0 && React.createElement(
                'div', { key: 'idxs', className: 'schema-indexes' },
                React.createElement('div', { className: 'schema-indexes-header' }, 'Indexes'),
                schemaModal.data.indexes.map(function(idx, i) {
                  return React.createElement(
                    'div', { key: idx.name || i, className: 'schema-index-row' },
                    React.createElement('span', { className: 'schema-index-cols' },
                      React.createElement('i', { className: 'fas fa-key', style: { fontSize: '9px', marginRight: '5px', opacity: 0.5 } }),
                      idx.columns.join(', ')
                    ),
                    idx.unique && React.createElement('span', { className: 'schema-index-unique' }, 'UNIQUE'),
                    idx.name && React.createElement('span', { className: 'schema-index-name' }, idx.name)
                  );
                })
              )
            ]
        )
      )
    )
  );
};

window.MbeditorApp = MbeditorApp;
/* TITLE BAR */ /* SIDEBAR */ /* EDITOR AREA */ /* STATUS BAR */ /* Right-click context menu */
