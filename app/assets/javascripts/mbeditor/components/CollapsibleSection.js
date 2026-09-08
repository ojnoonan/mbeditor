"use strict";


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


  var localCollapsed = _useState[0];
  var setLocalCollapsed = _useState[1];

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
        // The title truncates away entirely on a narrow sidebar, so it carries
        // its own tooltip — otherwise the section becomes unidentifiable.
        { className: "collapsible-title", title: typeof title === 'string' ? title : undefined },
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