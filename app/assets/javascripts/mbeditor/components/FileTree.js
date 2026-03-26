'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

function _toConsumableArray(arr) { if (Array.isArray(arr)) { for (var i = 0, arr2 = Array(arr.length); i < arr.length; i++) arr2[i] = arr[i]; return arr2; } else { return Array.from(arr); } }

function _defineProperty(obj, key, value) { if (key in obj) { Object.defineProperty(obj, key, { value: value, enumerable: true, configurable: true, writable: true }); } else { obj[key] = value; } return obj; }

var _React = React;
var useState = _React.useState;
var useRef = _React.useRef;
var useEffect = _React.useEffect;
var useMemo = _React.useMemo;

var FileTree = function FileTree(_ref) {
  var items = _ref.items;
  var onSelect = _ref.onSelect;
  var activePath = _ref.activePath;
  var selectedPath = _ref.selectedPath;
  var onNodeSelect = _ref.onNodeSelect;
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

  var _useState = useState('');

  var _useState2 = _slicedToArray(_useState, 2);

  var inlineValue = _useState2[0];
  var setInlineValue = _useState2[1];

  var inlineRef = useRef(null);
  var committedRef = useRef(false);
  var containerRef = useRef(null);

  // Scroll the highlighted node into view when selectedPath changes (e.g. Find in Explorer)
  useEffect(function () {
    if (!selectedPath || !containerRef.current) return;
    var timer = setTimeout(function () {
      var el = containerRef.current && containerRef.current.querySelector('.tree-item.selected');
      if (el) el.scrollIntoView({ block: 'nearest' });
    }, 60);
    return function () { clearTimeout(timer); };
  }, [selectedPath]);

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
      setTimeout(function () {
        if (inlineRef.current) inlineRef.current.focus();
      }, 0);
    }
  }, [pendingCreate, pendingRename]);

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

  var renderTree = function renderTree(nodes, folderPath) {
    var sortedNodes = [].concat(_toConsumableArray(nodes)).sort(function (a, b) {
      if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    var rows = sortedNodes.map(function (node) {
      var isFolder = node.type === "folder";
      var isExpanded = !!(expandedDirs && expandedDirs[node.path]);
      var isRenamingThisNode = !!(pendingRename && pendingRename.path === node.path);
      var isOpenFile = activePath === node.path;
      var isSelected = selectedPath === node.path;
      var status = getGitStatus(node.path);
      var statusMeta = getTreeStatusMeta(status);
      var isModified = statusMeta && (statusMeta.cssKey === "M" || statusMeta.cssKey === "A");

      return React.createElement(
        'div',
        { key: node.path, className: 'file-tree' },
        isRenamingThisNode ? renderInlineRenameRow(node) : React.createElement(
          'div',
          {
            className: 'tree-item ' + (isOpenFile ? "active" : "") + ' ' + (isSelected ? "selected" : "") + ' ' + (isModified ? "modified" : ""),
            onClick: function (e) {
              selectNode(node);
              if (isFolder) {
                toggleFolder(node.path, e);
              } else {
                onSelect(node.path, node.name);
              }
            },
            onDoubleClick: function (e) {
              if (!isFolder && onFileDoubleClick) {
                e.stopPropagation();
                onFileDoubleClick(node.path, node.name);
              }
            },
            onContextMenu: function (e) {
              e.preventDefault();
              e.stopPropagation();
              selectNode(node);
              if (onContextMenu) onContextMenu(e, node);
            }
          },
          React.createElement(
            'div',
            { className: 'tree-item-icon' },
            isFolder ? React.createElement('i', { className: 'fas fa-folder' + (isExpanded ? "-open" : "") + ' tree-folder-icon' }) : React.createElement('i', { className: window.getFileIcon(node.name) + ' tree-file-icon' })
          ),
          React.createElement(
            'div',
            { className: 'tree-item-name', title: node.path },
            node.name
          ),
          statusMeta && React.createElement(
            'div',
            { className: 'git-status-badge git-' + statusMeta.cssKey, title: statusMeta.title },
            statusMeta.badge
          )
        ),
        isFolder && isExpanded && node.children && React.createElement(
          'div',
          { style: { paddingLeft: "12px" } },
          renderTree(node.children, node.path)
        )
      );
    });

    // Inject inline create row at the end of this directory's list
    if (pendingCreate && pendingCreate.parentPath === folderPath) {
      rows.push(renderInlineRow());
    }

    return rows;
  };

  return React.createElement(
    'div',
    { className: 'file-tree-root', ref: containerRef },
    renderTree(items, '')
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
    prev.selectedPath === next.selectedPath &&
    prev.gitFiles === next.gitFiles &&
    prev.expandedDirs === next.expandedDirs &&
    prev.pendingCreate === next.pendingCreate &&
    prev.pendingRename === next.pendingRename;
});

// Expose globally for sprockets require
window.FileTree = FileTreeMemo;