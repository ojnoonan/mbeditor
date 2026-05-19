'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

function _toConsumableArray(arr) { if (Array.isArray(arr)) { for (var i = 0, arr2 = Array(arr.length); i < arr.length; i++) arr2[i] = arr[i]; return arr2; } else { return Array.from(arr); } }

function _defineProperty(obj, key, value) { if (key in obj) { Object.defineProperty(obj, key, { value: value, enumerable: true, configurable: true, writable: true }); } else { obj[key] = value; } return obj; }

var _React = React;
var useState = _React.useState;
var useRef = _React.useRef;
var useEffect = _React.useEffect;
var useMemo = _React.useMemo;

function formatSize(bytes) {
  if (typeof bytes !== 'number' || bytes < 0) return '';
  if (bytes < 1024)        return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

var FileTree = function FileTree(_ref) {
  var items = _ref.items;
  var onSelect = _ref.onSelect;
  var activePath = _ref.activePath;
  var selectedPaths = _ref.selectedPaths;   // Set<string> — all selected paths
  var anchorPath = _ref.anchorPath;         // string — anchor for shift-click range
  var onNodeSelect = _ref.onNodeSelect;     // fn(node) — single select (also clears multi)
  var onMultiSelect = _ref.onMultiSelect;   // fn(Set<string>) — multi-select update
  var onMove = _ref.onMove;                 // fn(srcPaths[], destFolderPath) — DnD move
  var gitFiles = _ref.gitFiles;
  var expandedDirs = _ref.expandedDirs;
  var onExpandedDirsChange = _ref.onExpandedDirsChange;
  var onFileDoubleClick = _ref.onFileDoubleClick;
  var onContextMenu = _ref.onContextMenu;
  var pendingCreate = _ref.pendingCreate;
  var onCreateConfirm = _ref.onCreateConfirm;
  var onCreateCancel = _ref.onCreateCancel;
  var pendingRename = _ref.pendingRename;
  var onRenameConfirm = _ref.onRenameConfirm;
  var onRenameCancel = _ref.onRenameCancel;
  var typeaheadEnabled = _ref.typeaheadEnabled !== false;

  var _useState = useState('');

  var _useState2 = _slicedToArray(_useState, 2);

  var inlineValue = _useState2[0];
  var setInlineValue = _useState2[1];

  var _useStateDnD = useState(null);
  var _useStateDnD2 = _slicedToArray(_useStateDnD, 2);
  var dragOverFolder = _useStateDnD2[0];
  var setDragOverFolder = _useStateDnD2[1];

  var inlineRef = useRef(null);
  var committedRef = useRef(false);
  var containerRef = useRef(null);
  var typeaheadBufferRef = useRef('');
  var typeaheadTimerRef = useRef(null);
  var hoverTimerRef = useRef(null);
  var hoverPathRef = useRef(null);
  // Ref that always points to the latest onNodeSelect prop, avoiding stale closures in the effect.
  var onNodeSelectRef = useRef(onNodeSelect);
  onNodeSelectRef.current = onNodeSelect;
  // Refs that track pending create/rename state for the typeahead guard.
  // Since these props are not in the effect's dependency array, we use refs to
  // always read the current values without stale closures.
  var pendingCreateRef = useRef(pendingCreate);
  var pendingRenameRef = useRef(pendingRename);
  pendingCreateRef.current = pendingCreate;
  pendingRenameRef.current = pendingRename;
  // Tracks whether the user's most recent mousedown was inside the sidebar.
  // Monaco re-steals keyboard focus after any click so e.target on keydown is
  // always Monaco's textarea — the only reliable "is the user in the explorer?"
  // signal is where they last clicked.
  var sidebarActiveRef = useRef(false);

  // Virtual scroll state
  var ROW_HEIGHT = 22;
  var BUFFER = 5;
  var flatItemsRef = useRef([]);
  var scrollParentRef = useRef(null);

  var _scrollState = useState(0);
  var scrollTop = _scrollState[0];
  var setScrollTop = _scrollState[1];

  var _heightState = useState(400);
  var containerHeight = _heightState[0];
  var setContainerHeight = _heightState[1];

  // Scroll item at idx into view via the parent scroll container
  var scrollToItem = function scrollToItem(idx) {
    var parent = scrollParentRef.current;
    if (!parent || !containerRef.current) return;
    var parentTop = parent.getBoundingClientRect().top;
    var treeTop = containerRef.current.getBoundingClientRect().top;
    var treeOffset = parent.scrollTop + (treeTop - parentTop);
    var itemAbsTop = treeOffset + idx * ROW_HEIGHT;
    var itemAbsBottom = itemAbsTop + ROW_HEIGHT;
    if (itemAbsTop < parent.scrollTop || itemAbsBottom > parent.scrollTop + parent.clientHeight) {
      parent.scrollTop = Math.max(0, itemAbsTop - Math.floor((parent.clientHeight - ROW_HEIGHT) / 2));
    }
  };

  // Scroll the highlighted node into view when anchorPath changes (e.g. Find in Explorer)
  useEffect(function () {
    if (!anchorPath) return;
    var timer = setTimeout(function () {
      var idx = flatItemsRef.current.findIndex(function(item) { return item.kind === 'node' && item.node.path === anchorPath; });
      if (idx >= 0) scrollToItem(idx);
    }, 60);
    return function () { clearTimeout(timer); };
  }, [anchorPath]);

  // Auto-reveal: when activePath changes, expand all ancestor dirs and scroll into view
  useEffect(function () {
    if (!activePath) return;

    // Expand every ancestor directory of the active file
    var parts = activePath.split('/');
    if (parts.length > 1) {
      var ancestors = {};
      for (var i = 1; i < parts.length; i++) {
        ancestors[parts.slice(0, i).join('/')] = true;
      }
      if (onExpandedDirsChange) {
        onExpandedDirsChange(Object.assign({}, expandedDirs || {}, ancestors));
      }
    }

    // After the DOM updates, scroll the active item into view only if not already visible
    var timer = setTimeout(function () {
      var idx = flatItemsRef.current.findIndex(function(item) { return item.kind === 'node' && item.node.path === activePath; });
      if (idx >= 0) scrollToItem(idx);
    }, 80);
    return function () { clearTimeout(timer); };
  }, [activePath]);

  var renameSelectionEnd = function renameSelectionEnd(name) {
    var value = String(name || '');
    var dotIndex = value.indexOf('.');
    return dotIndex > 0 ? dotIndex : value.length;
  };

  // Auto-focus the inline input whenever pendingCreate is set
  useEffect(function () {
    if (pendingRename) {
      setInlineValue(pendingRename.currentName || '');
      committedRef.current = false;
      setTimeout(function () {
        if (!inlineRef.current) return;
        var input = inlineRef.current;
        input.focus();
        var end = renameSelectionEnd(pendingRename.currentName);
        input.setSelectionRange(0, end);
      }, 0);
      return;
    }

    if (pendingCreate) {
      setInlineValue('');
      committedRef.current = false;
      var createIdx = flatItemsRef.current.findIndex(function(item) { return item.kind === 'create'; });
      if (createIdx >= 0) scrollToItem(createIdx);
      setTimeout(function () {
        if (inlineRef.current) inlineRef.current.focus();
      }, 0);
    }
  }, [pendingCreate, pendingRename]);

  // Clear any pending hover timer when the component unmounts to prevent
  // a prefetch from firing against an unmounted component.
  useEffect(function() {
    return function() { clearTimeout(hoverTimerRef.current); };
  }, []);

  // Track the parent scroll container (.ide-sidebar-scrollable) for virtual scroll.
  // The file-tree-root itself does not scroll — the parent does.
  useEffect(function() {
    if (!containerRef.current) return;
    var parent = containerRef.current.closest('.ide-sidebar-scrollable');
    if (!parent) return;
    scrollParentRef.current = parent;

    var update = function() {
      if (!containerRef.current || !parent) return;
      var parentRect = parent.getBoundingClientRect();
      var treeRect = containerRef.current.getBoundingClientRect();
      var treeOffset = parent.scrollTop + (treeRect.top - parentRect.top);
      setScrollTop(Math.max(0, parent.scrollTop - treeOffset));
      setContainerHeight(parent.clientHeight);
    };

    parent.addEventListener('scroll', update, { passive: true });
    var obs = new ResizeObserver(update);
    obs.observe(parent);
    obs.observe(containerRef.current);
    update();

    return function() {
      parent.removeEventListener('scroll', update);
      obs.disconnect();
    };
  }, []);

  var toggleFolder = function toggleFolder(path, e) {
    e.stopPropagation();
    var next = !(expandedDirs && expandedDirs[path]);
    if (onExpandedDirsChange) onExpandedDirsChange(Object.assign({}, expandedDirs || {}, _defineProperty({}, path, next)));
  };

  var selectNode = function selectNode(node) {
    if (!node || !onNodeSelect) return;
    onNodeSelect({ path: node.path, name: node.name, type: node.type });
  };

  // Build an O(1) lookup map from gitFiles so large trees don't do O(n) scans per row
  var gitStatusMap = useMemo(function () {
    var map = new Map();
    (gitFiles || []).forEach(function (f) { map.set(f.path, f.status); });
    return map;
  }, [gitFiles]);

  var getGitStatus = function getGitStatus(path) {
    return gitStatusMap.get(path) || null;
  };

  var getTreeStatusMeta = function getTreeStatusMeta(status) {
    var raw = (status || '').trim();
    if (!raw) return null;
    if (raw === '??') return { badge: 'N', cssKey: 'A', title: 'Untracked (new file)' };
    if (raw.startsWith('R')) return { badge: 'R', cssKey: 'R', title: 'Renamed' };

    var key = raw.charAt(0);
    var titleMap = {
      M: 'Modified',
      A: 'Added',
      D: 'Deleted',
      U: 'Unmerged'
    };

    return { badge: key || '?', cssKey: key || 'Q', title: titleMap[key] || 'Status' };
  };

  // Returns all visible paths in depth-first render order (for shift+click range select)
  var computeVisiblePaths = function computeVisiblePaths(_nodes) {
    return flatItemsRef.current
      .filter(function(item) { return item.kind === 'node'; })
      .map(function(item) { return item.node.path; });
  };

  // Global type-ahead: tracks the last mousedown to know if the user is "in the explorer",
  // then intercepts keystrokes accordingly. Checking e.target on keydown is unreliable because
  // Monaco aggressively calls editor.focus() after every interaction, so e.target is always
  // Monaco's hidden textarea — even after clicking the sidebar.
  useEffect(function() {
    function onGlobalMouseDown(e) {
      // Activate when any click lands inside .ide-sidebar; deactivate otherwise.
      var sidebar = document.querySelector('.ide-sidebar');
      sidebarActiveRef.current = !!(sidebar && sidebar.contains(e.target));
    }

    function onGlobalKeyDown(e) {
      if (!typeaheadEnabled) return;
      if (!sidebarActiveRef.current) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      // Prevent typeahead from jumping files while typing a new name in inline create/rename.
      if (pendingCreateRef.current || pendingRenameRef.current) return;
      if (e.key.length !== 1) return;
      // Still skip when an inline rename/create input is the actual focused element.
      if (e.target && e.target.tagName === 'INPUT') return;
      if (!containerRef.current) return;

      e.preventDefault();
      clearTimeout(typeaheadTimerRef.current);
      typeaheadBufferRef.current += e.key.toLowerCase();
      typeaheadTimerRef.current = setTimeout(function() {
        typeaheadBufferRef.current = '';
      }, 600);

      var prefix = typeaheadBufferRef.current;
      var flat = flatItemsRef.current;
      for (var i = 0; i < flat.length; i++) {
        var fItem = flat[i];
        if (fItem.kind !== 'node') continue;
        if (fItem.node.name.toLowerCase().indexOf(prefix) === 0) {
          scrollToItem(i);
          if (onNodeSelectRef.current) {
            onNodeSelectRef.current({ path: fItem.node.path, name: fItem.node.name, type: fItem.node.type });
          }
          break;
        }
      }
    }

    window.addEventListener('mousedown', onGlobalMouseDown, true);
    window.addEventListener('keydown', onGlobalKeyDown, true);
    return function() {
      window.removeEventListener('mousedown', onGlobalMouseDown, true);
      window.removeEventListener('keydown', onGlobalKeyDown, true);
    };
  }, [typeaheadEnabled]);

  var handleInlineKeyDown = function handleInlineKeyDown(e) {
    var isRename = !!pendingRename;
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      committedRef.current = true;
      var rawValue = e && e.currentTarget ? e.currentTarget.value : inlineValue;
      var val = String(rawValue || '').trim();
      if (val) {
        if (isRename && onRenameConfirm) onRenameConfirm(val, pendingRename);
        if (!isRename && onCreateConfirm) onCreateConfirm(val);
      } else {
        if (isRename && onRenameCancel) onRenameCancel();
        if (!isRename && onCreateCancel) onCreateCancel();
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      committedRef.current = true;
      if (isRename && onRenameCancel) onRenameCancel();
      if (!isRename && onCreateCancel) onCreateCancel();
    }
  };

  var handleInlineBlur = function handleInlineBlur() {
    var isRename = !!pendingRename;
    setTimeout(function () {
      if (!committedRef.current) {
        if (isRename && onRenameCancel) onRenameCancel();
        if (!isRename && onCreateCancel) onCreateCancel();
      }
      committedRef.current = false;
    }, 150);
  };

  var renderInlineRow = function renderInlineRow() {
    var isFolder = pendingCreate.type === 'folder';
    var iconClass = isFolder ? 'fas fa-folder tree-folder-icon' : window.getFileIcon(inlineValue || '') + ' tree-file-icon';
    return React.createElement(
      'div',
      { key: '__inline-create__', className: 'tree-item tree-item-inline-create' },
      React.createElement(
        'div',
        { className: 'tree-item-icon' },
        React.createElement('i', { className: iconClass })
      ),
      React.createElement('input', {
        ref: inlineRef,
        className: 'tree-inline-input',
        type: 'text',
        value: inlineValue,
        onChange: function (e) {
          return setInlineValue(e.target.value);
        },
        onKeyDown: handleInlineKeyDown,
        onBlur: handleInlineBlur,
        autoComplete: 'off',
        spellCheck: false,
        placeholder: isFolder ? 'folder name' : 'file name'
      })
    );
  };

  var renderInlineRenameRow = function renderInlineRenameRow(node) {
    var isFolder = node.type === 'folder';
    var iconClass = isFolder ? 'fas fa-folder tree-folder-icon' : window.getFileIcon(inlineValue || node.name || '') + ' tree-file-icon';
    return React.createElement(
      'div',
      { className: 'tree-item tree-item-inline-create' },
      React.createElement(
        'div',
        { className: 'tree-item-icon' },
        React.createElement('i', { className: iconClass })
      ),
      React.createElement('input', {
        ref: inlineRef,
        className: 'tree-inline-input',
        type: 'text',
        value: inlineValue,
        onChange: function (e) {
          return setInlineValue(e.target.value);
        },
        onKeyDown: handleInlineKeyDown,
        onBlur: handleInlineBlur,
        autoComplete: 'off',
        spellCheck: false,
        placeholder: 'name'
      })
    );
  };

  // Flatten the visible tree into a linear array for virtual scrolling.
  var flattenVisible = function flattenVisible(nodes, depth, parentPath) {
    var result = [];
    var sorted = [].concat(_toConsumableArray(nodes)).sort(function(a, b) {
      if (a.type !== b.type) return a.type === 'folder' ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    sorted.forEach(function(node) {
      result.push({ kind: 'node', node: node, depth: depth });
      if (node.type === 'folder' && expandedDirs && expandedDirs[node.path] && node.children) {
        var children = flattenVisible(node.children, depth + 1, node.path);
        for (var ci = 0; ci < children.length; ci++) result.push(children[ci]);
      }
    });
    if (pendingCreate && pendingCreate.parentPath === parentPath) {
      result.push({ kind: 'create', depth: depth });
    }
    return result;
  };

  var flatItems = flattenVisible(items || [], 0, '');
  flatItemsRef.current = flatItems;

  var totalHeight = flatItems.length * ROW_HEIGHT;
  var startIdx = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - BUFFER);
  var endIdx = Math.min(flatItems.length - 1, Math.ceil((scrollTop + containerHeight) / ROW_HEIGHT) + BUFFER);

  var renderRow = function renderRow(item, idx) {
    var indentPx = 8 + item.depth * 12;

    if (item.kind === 'create') {
      return React.createElement(
        'div',
        { key: '__inline-create__', style: { position: 'absolute', top: idx * ROW_HEIGHT, left: 0, right: 0 } },
        React.createElement('div', { style: { paddingLeft: indentPx } }, renderInlineRow())
      );
    }

    var node = item.node;
    var isFolder = node.type === 'folder';
    var isExpanded = !!(expandedDirs && expandedDirs[node.path]);
    var isRenamingThisNode = !!(pendingRename && pendingRename.path === node.path);
    var isOpenFile = activePath === node.path;
    var isSelected = !!(selectedPaths && selectedPaths.has(node.path));
    var isDragOver = isFolder && dragOverFolder === node.path;
    var status = getGitStatus(node.path);
    var statusMeta = getTreeStatusMeta(status);
    var isModified = statusMeta && (statusMeta.cssKey === 'M' || statusMeta.cssKey === 'A');

    var classNames = 'tree-item' +
      (isOpenFile ? ' active' : '') +
      (isSelected ? ' selected' : '') +
      (isModified ? ' modified' : '') +
      (isDragOver ? ' drag-over' : '');

    return React.createElement(
      'div',
      { key: node.path, style: { position: 'absolute', top: idx * ROW_HEIGHT, left: 0, right: 0 } },
      isRenamingThisNode
        ? React.createElement('div', { style: { paddingLeft: indentPx } }, renderInlineRenameRow(node))
        : React.createElement(
          'div',
          {
            className: classNames,
            style: { paddingLeft: indentPx },
            'data-path': node.path,
            'data-name': node.name,
            'data-type': node.type,
            draggable: true,
            onDragStart: function(e) {
              var srcPaths = (selectedPaths && selectedPaths.has(node.path) && selectedPaths.size > 1)
                ? Array.from(selectedPaths)
                : [node.path];
              e.dataTransfer.setData('text/plain', JSON.stringify(srcPaths));
              e.dataTransfer.effectAllowed = 'move';
            },
            onDragOver: function(e) {
              if (!isFolder) return;
              e.preventDefault();
              e.stopPropagation();
              e.dataTransfer.dropEffect = 'move';
              if (dragOverFolder !== node.path) setDragOverFolder(node.path);
            },
            onDragLeave: function() {
              if (dragOverFolder === node.path) setDragOverFolder(null);
            },
            onDrop: function(e) {
              e.preventDefault();
              e.stopPropagation();
              setDragOverFolder(null);
              if (!isFolder) return;
              try {
                var srcPaths = JSON.parse(e.dataTransfer.getData('text/plain'));
                if (onMove && srcPaths && srcPaths.length > 0) onMove(srcPaths, node.path);
              } catch (err) {}
            },
            onDragEnd: function() { setDragOverFolder(null); },
            onClick: function(e) {
              if (e.ctrlKey || e.metaKey) {
                if (onMultiSelect) {
                  var newPaths = new Set(selectedPaths || []);
                  if (newPaths.has(node.path)) { newPaths.delete(node.path); } else { newPaths.add(node.path); }
                  onMultiSelect(newPaths);
                }
              } else if (e.shiftKey && anchorPath) {
                if (onMultiSelect) {
                  var visiblePaths = computeVisiblePaths(items);
                  var anchorIdx2 = visiblePaths.indexOf(anchorPath);
                  var currentIdx2 = visiblePaths.indexOf(node.path);
                  if (anchorIdx2 >= 0 && currentIdx2 >= 0) {
                    var start = Math.min(anchorIdx2, currentIdx2);
                    var end = Math.max(anchorIdx2, currentIdx2);
                    onMultiSelect(new Set(visiblePaths.slice(start, end + 1)));
                  } else {
                    selectNode(node);
                  }
                }
              } else {
                selectNode(node);
                if (isFolder) { toggleFolder(node.path, e); } else { onSelect(node.path, node.name); }
                if (containerRef.current) containerRef.current.focus();
              }
            },
            onDoubleClick: function(e) {
              if (!isFolder && onFileDoubleClick) { e.stopPropagation(); onFileDoubleClick(node.path, node.name); }
            },
            onMouseEnter: function() {
              if (isFolder) return;
              clearTimeout(hoverTimerRef.current);
              hoverTimerRef.current = setTimeout(function() {
                hoverPathRef.current = node.path;
                FileService.prefetch(node.path);
              }, 200);
            },
            onMouseLeave: function() {
              if (isFolder) return;
              clearTimeout(hoverTimerRef.current);
              FileService.cancelPrefetch(hoverPathRef.current);
              hoverPathRef.current = null;
            },
            onContextMenu: function(e) {
              e.preventDefault();
              e.stopPropagation();
              selectNode(node);
              if (onContextMenu) onContextMenu(e, node);
            }
          },
          React.createElement(
            'div', { className: 'tree-item-icon' },
            isFolder
              ? React.createElement('i', { className: 'fas fa-folder' + (isExpanded ? '-open' : '') + ' tree-folder-icon' })
              : React.createElement('i', { className: window.getFileIcon(node.name) + ' tree-file-icon' })
          ),
          React.createElement(
            'div',
            { className: 'tree-item-name', title: node.type === 'file' && node.size != null ? node.path + ' — ' + formatSize(node.size) : node.path },
            node.name
          ),
          statusMeta && React.createElement(
            'div',
            { className: 'git-status-badge git-' + statusMeta.cssKey, title: statusMeta.title },
            statusMeta.badge
          )
        )
    );
  };

  var visibleRows = [];
  for (var vi = startIdx; vi <= endIdx; vi++) {
    visibleRows.push(renderRow(flatItems[vi], vi));
  }

  return React.createElement(
    'div',
    { className: 'file-tree file-tree-root', ref: containerRef, tabIndex: 0, style: { outline: 'none', padding: 0 } },
    React.createElement(
      'div',
      { style: { height: totalHeight, position: 'relative' } },
      visibleRows
    )
  );
};

// Wrap FileTree in React.memo with a custom comparator that only checks
// the data props that affect what's rendered. Function prop references
// (event handlers) are re-created on every parent render but do not
// change the visual output, so we intentionally ignore them here.
// This prevents O(n) tree traversal on every MbeditorApp re-render
// caused by unrelated state changes (status messages, git polls, etc.).
var FileTreeMemo = React.memo(FileTree, function(prev, next) {
  return prev.items === next.items &&
    prev.activePath === next.activePath &&
    prev.selectedPaths === next.selectedPaths &&
    prev.anchorPath === next.anchorPath &&
    prev.gitFiles === next.gitFiles &&
    prev.expandedDirs === next.expandedDirs &&
    prev.pendingCreate === next.pendingCreate &&
    prev.pendingRename === next.pendingRename;
});

// Expose globally for sprockets require
window.FileTree = FileTreeMemo;