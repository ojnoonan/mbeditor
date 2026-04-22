'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var TabBar = function TabBar(_ref) {
  var tabs = _ref.tabs;
  var activeId = _ref.activeId;
  var paneId = _ref.paneId;
  var onSelect = _ref.onSelect;
  var onClose = _ref.onClose;
  var onTabDragStart = _ref.onTabDragStart;
  var onTabDragEnd = _ref.onTabDragEnd;
  var onHardenTab = _ref.onHardenTab;
  var onShowHistory = _ref.onShowHistory;
  var onRevealInExplorer = _ref.onRevealInExplorer;
  var tabDisplayMode = _ref.tabDisplayMode || 'scroll';

  var containerRef = useRef(null);

  var _useState = useState(null);

  var _useState2 = _slicedToArray(_useState, 2);

  var draggingTabId = _useState2[0];
  var setDraggingTabId = _useState2[1];

  var _useState3 = useState(null);

  var _useState4 = _slicedToArray(_useState3, 2);

  var tabContextMenu = _useState4[0];
  var setTabContextMenu = _useState4[1];

  var _useState5 = useState(null);
  var _useState6 = _slicedToArray(_useState5, 2);
  var dropTargetTabId = _useState6[0];
  var setDropTargetTabId = _useState6[1];

  var _useState7 = useState(null);
  var _useState8 = _slicedToArray(_useState7, 2);
  var dropTargetSide = _useState8[0];
  var setDropTargetSide = _useState8[1];

  var getTabMarkerClass = function getTabMarkerClass(tab) {
    var tabMarkers = tab.markers || [];
    if (!tabMarkers.length) return '';

    var hasError = tabMarkers.some(function (marker) {
      var severity = String(marker && marker.severity || '').toLowerCase();
      return severity === 'error' || severity === 'fatal';
    });
    if (hasError) return 'tab-has-error';

    var hasWarning = tabMarkers.some(function (marker) {
      var severity = String(marker && marker.severity || '').toLowerCase();
      return severity !== 'error' && severity !== 'fatal';
    });
    if (hasWarning) return 'tab-has-warning';

    return '';
  };

  // Scroll active tab into view
  useEffect(function () {
    if (containerRef.current) {
      var activeEl = containerRef.current.querySelector('.tab-item.active');
      if (activeEl) {
        activeEl.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
      }
    }
  }, [activeId, tabs]);

  // Close context menu on outside click (bubble phase so onMouseDown on the menu can stop it)
  useEffect(function () {
    if (!tabContextMenu) return;
    var handler = function () { setTabContextMenu(null); };
    document.addEventListener('mousedown', handler);
    return function () { document.removeEventListener('mousedown', handler); };
  }, [tabContextMenu]);

  return React.createElement(
    React.Fragment,
    null,
    React.createElement(
    'div',
    { className: 'tab-bar tab-bar-' + tabDisplayMode, ref: containerRef, onWheel: function (e) {
        if (tabDisplayMode !== 'wrap' && containerRef.current) {
          containerRef.current.scrollLeft += e.deltaY;
        }
      } },
    tabs.map(function (tab) {
      var isSpecial = tab.isCommitGraph || tab.isDiff || tab.isPreview || tab.isSettings;
      return React.createElement(
        'div',
        {
          key: tab.id,
          className: 'tab-item ' + (activeId === tab.id ? 'active' : '') + ' ' + (tab.isSoftOpen ? 'tab-soft' : '') + ' ' + getTabMarkerClass(tab) + ' ' + (draggingTabId === tab.id ? 'dragging' : '') + ' ' + (dropTargetTabId === tab.id && dropTargetSide === 'left' ? 'drop-before' : '') + ' ' + (dropTargetTabId === tab.id && dropTargetSide === 'right' ? 'drop-after' : ''),
          onClick: function () {
            return onSelect(tab.id);
          },
          onDoubleClick: function () {
            if (tab.isSoftOpen && onHardenTab) onHardenTab(tab.id);
          },
          title: tab.path + ' - Drag to move to another pane',
          draggable: true,
          onDragStart: function (e) {
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('application/x-mbeditor-tab', tab.id);
            setDraggingTabId(tab.id);
            if (onTabDragStart) onTabDragStart(tab.id);
          },
          onDragEnd: function () {
            setDraggingTabId(null);
            setDropTargetTabId(null);
            setDropTargetSide(null);
            if (onTabDragEnd) onTabDragEnd();
          },
          onDragOver: function (e) {
            if (!draggingTabId || draggingTabId === tab.id) return;
            e.preventDefault();
            e.stopPropagation();
            e.dataTransfer.dropEffect = 'move';
            var rect = e.currentTarget.getBoundingClientRect();
            var side = e.clientX < rect.left + rect.width / 2 ? 'left' : 'right';
            if (dropTargetTabId !== tab.id || dropTargetSide !== side) {
              setDropTargetTabId(tab.id);
              setDropTargetSide(side);
            }
          },
          onDragLeave: function (e) {
            if (e.currentTarget.contains(e.relatedTarget)) return;
            setDropTargetTabId(null);
            setDropTargetSide(null);
          },
          onDrop: function (e) {
            if (!draggingTabId || draggingTabId === tab.id || !paneId) return;
            e.stopPropagation();
            var rect = e.currentTarget.getBoundingClientRect();
            var side = e.clientX < rect.left + rect.width / 2 ? 'left' : 'right';
            var tabIndex = tabs.findIndex(function (t) { return t.id === tab.id; });
            var insertBeforeTabId;
            if (side === 'left') {
              insertBeforeTabId = tab.id;
            } else {
              insertBeforeTabId = tabIndex + 1 < tabs.length ? tabs[tabIndex + 1].id : null;
            }
            TabManager.reorderTabInPane(paneId, draggingTabId, insertBeforeTabId);
            setDropTargetTabId(null);
            setDropTargetSide(null);
          },
          onContextMenu: function (e) {
            if (isSpecial) return;
            e.preventDefault();
            setTabContextMenu({ x: e.clientX, y: e.clientY, tab: tab });
          }
        },
        React.createElement('i', { className: 'tab-item-icon ' + (tab.isSettings ? 'fas fa-cog' : (window.getFileIcon ? window.getFileIcon(tab.name) : 'far fa-file-code')) }),
        React.createElement(
          'div',
          { className: 'tab-item-name' },
          tab.name
        ),
        tab.dirty && React.createElement(
          'div',
          { className: 'tab-dirty-dot' },
          '●'
        ),
        React.createElement(
          'div',
          {
            className: 'tab-close',
            onClick: function (e) {
              e.stopPropagation();
              onClose(tab.id);
            }
          },
          React.createElement('i', { className: 'fas fa-times' })
        )
      );
    })
  ),
  tabContextMenu && React.createElement(
    'div',
    {
      className: 'ide-tab-context-menu',
      style: {
        position: 'fixed',
        top: tabContextMenu.y,
        left: tabContextMenu.x,
        zIndex: 9999,
        background: '#252526',
        border: '1px solid #454545',
        borderRadius: '4px',
        boxShadow: '0 4px 12px rgba(0,0,0,0.5)',
        minWidth: '160px',
        padding: '4px 0'
      },
      onMouseDown: function(e) { e.stopPropagation(); }
    },
    onShowHistory && React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() {
          setTabContextMenu(null);
          onShowHistory(tabContextMenu.tab.path);
        }
      },
      React.createElement('i', { className: 'fas fa-history', style: { width: '14px', textAlign: 'center' } }),
      'File History'
    ),
    onRevealInExplorer && React.createElement(
      'div',
      {
        className: 'ide-tab-context-menu-item',
        style: { padding: '6px 14px', cursor: 'pointer', color: '#ccc', fontSize: '12px', display: 'flex', alignItems: 'center', gap: '8px' },
        onMouseEnter: function(e) { e.currentTarget.style.background = '#094771'; },
        onMouseLeave: function(e) { e.currentTarget.style.background = 'transparent'; },
        onClick: function() {
          setTabContextMenu(null);
          onRevealInExplorer(tabContextMenu.tab.path);
        }
      },
      React.createElement('i', { className: 'fas fa-sitemap', style: { width: '14px', textAlign: 'center' } }),
      'Find in Explorer'
    )
  )
  );
};

window.TabBar = TabBar;