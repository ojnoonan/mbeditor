"use strict";

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i["return"]) _i["return"](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError("Invalid attempt to destructure non-iterable instance"); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var QuickOpenDialog = function QuickOpenDialog(_ref) {
  var onSelect = _ref.onSelect;
  var onClose = _ref.onClose;

  var _useState = useState("");

  var _useState2 = _slicedToArray(_useState, 2);

  var query = _useState2[0];
  var setQuery = _useState2[1];

  var _useState3 = useState([]);

  var _useState32 = _slicedToArray(_useState3, 2);

  var results = _useState32[0];
  var setResults = _useState32[1];

  var _useState4 = useState(0);

  var _useState42 = _slicedToArray(_useState4, 2);

  var selectedIndex = _useState42[0];
  var setSelectedIndex = _useState42[1];

  var inputRef = useRef(null);

  var clearQuery = function clearQuery() {
    setQuery('');
    setResults([]);
    setSelectedIndex(0);
    if (inputRef.current) inputRef.current.focus();
  };

  var getQuickOpenIcon = function getQuickOpenIcon(path, name) {
    var iconClass = window.getFileIcon ? window.getFileIcon(path || name || '') : 'far fa-file-code';
    return React.createElement('i', { className: iconClass + ' quick-open-result-icon', 'aria-hidden': 'true' });
  };

  useEffect(function () {
    if (inputRef.current) inputRef.current.focus();
  }, []);

  useEffect(function () {
    var res = SearchService.searchFiles(query);
    setResults(res.slice(0, 20)); // cap at 20
    setSelectedIndex(0);
  }, [query]);

  var handleKeyDown = function handleKeyDown(e) {
    if (e.key === "Escape") onClose();
    if (e.key === "ArrowDown") setSelectedIndex(function (i) {
      return Math.min(i + 1, results.length - 1);
    });
    if (e.key === "ArrowUp") setSelectedIndex(function (i) {
      return Math.max(i - 1, 0);
    });
    if (e.key === "Enter" && results[selectedIndex]) {
      var res = results[selectedIndex];
      onSelect(res.path, res.name);
    }
  };

  return React.createElement(
    "div",
    { className: "quick-open-overlay", onClick: onClose },
    React.createElement(
      "div",
      { className: "quick-open-box", onClick: function (e) {
          return e.stopPropagation();
        } },
      React.createElement(
        "div",
        { className: "quick-open-input-wrap" },
        React.createElement("input", {
          ref: inputRef,
          type: "text",
          className: "quick-open-input",
          placeholder: "Search files by name (Ctrl+P)...",
          value: query,
          onChange: function (e) {
            return setQuery(e.target.value);
          },
          onKeyDown: handleKeyDown
        }),
        query && React.createElement(
          "button",
          {
            type: "button",
            className: "quick-open-clear-btn",
            onClick: clearQuery,
            title: "Clear search",
            "aria-label": "Clear search"
          },
          React.createElement("i", { className: "fas fa-times" })
        )
      ),
      React.createElement(
        "div",
        { className: "quick-open-results" },
        results.map(function (res, i) {
          return React.createElement(
            "div",
            {
              key: res.id,
              className: "quick-open-result " + (i === selectedIndex ? "selected" : ""),
              onClick: function () {
                return onSelect(res.path, res.name);
              },
              onMouseEnter: function () {
                return setSelectedIndex(i);
              }
            },
            getQuickOpenIcon(res.path, res.name),
            React.createElement(
              "div",
              { className: "quick-open-result-body" },
              React.createElement(
                "div",
                { className: "quick-open-result-name" },
                res.name
              ),
              React.createElement(
                "div",
                { className: "quick-open-result-path" },
                res.path
              )
            )
          );
        }),
        query && results.length === 0 && React.createElement(
          "div",
          { style: { padding: "12px 16px", color: "#666", fontSize: "12px" } },
          "No matching files."
        )
      )
    )
  );
};

window.QuickOpenDialog = QuickOpenDialog;