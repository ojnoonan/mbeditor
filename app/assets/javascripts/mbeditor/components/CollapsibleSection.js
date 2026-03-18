"use strict";

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i["return"]) _i["return"](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError("Invalid attempt to destructure non-iterable instance"); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;

var CollapsibleSection = function CollapsibleSection(_ref) {
  var title = _ref.title;
  var children = _ref.children;
  var _ref$isCollapsed = _ref.isCollapsed;
  var isCollapsed = _ref$isCollapsed === undefined ? false : _ref$isCollapsed;
  var _ref$onToggle = _ref.onToggle;
  var onToggle = _ref$onToggle === undefined ? null : _ref$onToggle;
  var _ref$icon = _ref.icon;
  var icon = _ref$icon === undefined ? null : _ref$icon;
  var _ref$actions = _ref.actions;
  var actions = _ref$actions === undefined ? null : _ref$actions;

  var _useState = useState(isCollapsed);

  var _useState2 = _slicedToArray(_useState, 2);

  var localCollapsed = _useState2[0];
  var setLocalCollapsed = _useState2[1];

  // Sync parent isCollapsed prop to local state when it changes
  useEffect(function () {
    setLocalCollapsed(isCollapsed);
  }, [isCollapsed]);

  var toggleCollapsed = function toggleCollapsed(e) {
    e.stopPropagation();
    var newState = !localCollapsed;
    setLocalCollapsed(newState);
    if (onToggle) {
      onToggle(newState);
    }
  };

  return React.createElement(
    "div",
    { className: "collapsible-section" },
    React.createElement(
      "div",
      { className: "collapsible-header", onClick: toggleCollapsed },
      React.createElement("i", { className: "collapsible-toggle fas fa-chevron-" + (localCollapsed ? 'right' : 'down') }),
      icon && React.createElement("i", { className: "collapsible-icon " + icon }),
      React.createElement(
        "span",
        { className: "collapsible-title" },
        title
      ),
      actions && React.createElement(
        "div",
        { className: "collapsible-actions", onClick: function (e) {
            return e.stopPropagation();
          } },
        actions
      )
    ),
    !localCollapsed && React.createElement(
      "div",
      { className: "collapsible-content" },
      children
    )
  );
};

window.CollapsibleSection = CollapsibleSection;