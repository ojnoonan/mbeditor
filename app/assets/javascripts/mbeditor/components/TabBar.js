'use strict';


var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var menuItem = function menuItem(icon, label, onClick) {
  return React.createElement(
    'div',
    { className: 'ide-tab-context-menu-item', onClick: onClick },
    React.createElement('i', { className: icon }),
    label
  );
};

// Clamps a position:fixed, content-sized popup menu into the viewport.
// The menu is already rendered at its raw (possibly off-screen) cursor
// position via inline style, so its size can only be known by measuring
// the real element — nudge it back on-screen if it overflows. Shared by
// the tab-strip menu here and the explorer context menu in MbeditorApp.js.
window.clampMenuIntoView = function clampMenuIntoView(el) {
  if (!el) return;
  var MARGIN = 4;
  var rect = el.getBoundingClientRect();
  var left = rect.left;
  var top = rect.top;

  if (rect.right > window.innerWidth - MARGIN) {
    left = Math.max(MARGIN, window.innerWidth - MARGIN - rect.width);
  }
  if (rect.bottom > window.innerHeight - MARGIN) {
    var above = rect.top - rect.height;
    top = above >= MARGIN ? above : MARGIN;
  }
  if (left < MARGIN) left = MARGIN;
  if (top < MARGIN) top = MARGIN;

  if (left !== rect.left) el.style.left = left + 'px';
  if (top !== rect.top) el.style.top = top + 'px';
};

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
  var onCloseOthers = _ref.onCloseOthers;
  var onCloseSaved = _ref.onCloseSaved;
  var onCloseAll = _ref.onCloseAll;
  var onNewFile = _ref.onNewFile;
  var markers = _ref.markers || {};
  var tabDisplayMode = _ref.tabDisplayMode || 'scroll';

  var containerRef = useRef(null);

  var _useState = useState(null);


  var draggingTabId = _useState[0];
  var setDraggingTabId = _useState[1];

  var _useState3 = useState(null);


  var tabContextMenu = _useState3[0];
  var setTabContextMenu = _useState3[1];
  var tabContextMenuRef = useRef(null);

  var _useState5 = useState(null);
  var dropTargetTabId = _useState5[0];
  var setDropTargetTabId = _useState5[1];

  var _useState7 = useState(null);
  var dropTargetSide = _useState7[0];
  var setDropTargetSide = _useState7[1];

  var getTabMarkerClass = function getTabMarkerClass(tab) {
    var tabMarkers = markers[tab.id] || [];
    if (!tabMarkers.length) return '';

    var hasError = tabMarkers.some(function (marker) {
      var severity = String(marker && marker.severity || '').toLowerCase();
      return severity === 'error' || severity === 'fatal';
    });
    if (hasError) return 'tab-has-error';

    // Only real warnings tint the tab. Convention and refactor offenses grade
    // as info/hint and are far too common to be worth an amber tab — a tint
    // that's always on tells you nothing.
    var hasWarning = tabMarkers.some(function (marker) {
      return String(marker && marker.severity || '').toLowerCase() === 'warning';
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
  // tabs.length, not tabs: the array is fresh on every content change, so
  // depending on it fired a smooth scroll per keystroke. Only opening, closing
  // or switching a tab can move the active one out of view.
  }, [activeId, tabs.length]);

  // Close context menu on outside click (bubble phase so onMouseDown on the menu can stop it)
  useEffect(function () {
    if (!tabContextMenu) return;
    var handler = function () { setTabContextMenu(null); };
    document.addEventListener('mousedown', handler);
    return function () { document.removeEventListener('mousedown', handler); };
  }, [tabContextMenu]);

  // Clamp into view whenever the menu opens at a new position.
  useEffect(function () {
    if (tabContextMenu) window.clampMenuIntoView(tabContextMenuRef.current);
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
          },
          onMouseDown: function (e) {
            if (e.button === 1) e.preventDefault();
          },
          onAuxClick: function (e) {
            if (e.button === 1) {
              e.preventDefault();
              onClose(tab.id);
            }
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
            // No role="button" here: the host app's Pico CSS skins
            // [role=button] with a primary background and form padding, which
            // turns this into a blue square. It is a plain div with a tooltip,
            // as it was — Ctrl+W is the keyboard path.
            title: 'Close ' + tab.name + (tab.dirty ? ' (unsaved changes)' : ''),
            onClick: function (e) {
              e.stopPropagation();
              onClose(tab.id);
            }
          },
          React.createElement('i', { className: 'fas fa-times' })
        )
      );
    })
    ,
    onNewFile && React.createElement(
      'div',
      {
        className: 'tab-new-file-btn',
        title: 'New File',
        onClick: function (e) { e.stopPropagation(); onNewFile(); }
      },
      React.createElement('i', { className: 'fas fa-plus' })
    )
  ),
  tabContextMenu && React.createElement(
    'div',
    {
      className: 'ide-tab-context-menu',
      ref: tabContextMenuRef,
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
    menuItem('fas fa-times', 'Close', function() { setTabContextMenu(null); onClose(tabContextMenu.tab.id); }),
    onCloseOthers && menuItem('fas fa-times-circle', 'Close Others', function() { setTabContextMenu(null); onCloseOthers(tabContextMenu.tab.id); }),
    onCloseSaved && menuItem('fas fa-check', 'Close Saved', function() { setTabContextMenu(null); onCloseSaved(); }),
    onCloseAll && menuItem('fas fa-times', 'Close All', function() { setTabContextMenu(null); onCloseAll(); }),
    React.createElement('div', { style: { height: '1px', background: '#454545', margin: '4px 0' } }),
    onShowHistory && menuItem('fas fa-history', 'File History', function() {
      setTabContextMenu(null);
      onShowHistory(tabContextMenu.tab.path);
    }),
    onRevealInExplorer && menuItem('fas fa-sitemap', 'Find in Explorer', function() {
      setTabContextMenu(null);
      onRevealInExplorer(tabContextMenu.tab.path);
    })
  )
  );
};

window.TabBar = TabBar;