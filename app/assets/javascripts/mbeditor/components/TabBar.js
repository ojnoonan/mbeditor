'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var TabBar = function TabBar(_ref) {
  var tabs = _ref.tabs;
  var activeId = _ref.activeId;
  var onSelect = _ref.onSelect;
  var onClose = _ref.onClose;
  var onTabDragStart = _ref.onTabDragStart;
  var onTabDragEnd = _ref.onTabDragEnd;
  var onHardenTab = _ref.onHardenTab;
  var onShowHistory = _ref.onShowHistory;

  var containerRef = useRef(null);

  var _useState = useState(null);

  var _useState2 = _slicedToArray(_useState, 2);

  var draggingTabId = _useState2[0];
  var setDraggingTabId = _useState2[1];

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

  return React.createElement(
    'div',
    { className: 'tab-bar', ref: containerRef, onWheel: function (e) {
        if (containerRef.current) {
          containerRef.current.scrollLeft += e.deltaY;
        }
      } },
    tabs.map(function (tab) {
      var isSpecial = tab.isCommitGraph || tab.isDiff || tab.isPreview || tab.isSettings;
      return React.createElement(
        'div',
        {
          key: tab.id,
          className: 'tab-item ' + (activeId === tab.id ? 'active' : '') + ' ' + (tab.isSoftOpen ? 'tab-soft' : '') + ' ' + getTabMarkerClass(tab) + ' ' + (draggingTabId === tab.id ? 'dragging' : ''),
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
            if (onTabDragEnd) onTabDragEnd();
          },
          onContextMenu: function (e) {
            if (isSpecial) return;
            e.preventDefault();
            if (onShowHistory) onShowHistory(tab.path);
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
  );
};

window.TabBar = TabBar;