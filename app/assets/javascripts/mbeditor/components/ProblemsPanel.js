'use strict';

// ProblemsPanel — bottom drawer listing the diagnostics Monaco is holding for
// the files you have open: rubocop and ruby-lsp for Ruby, the TypeScript
// worker's syntax errors for JS/JSX, and anything else that writes markers.
//
// Scope is deliberately "open tabs", not the workspace: markers only exist for
// models Monaco has loaded, so a count over anything wider would be a lie.
// Closing a tab drops its problems, same as VS Code with an unopened file.
var ProblemsPanel = (function () {
  var SEVERITY_ERROR = 8;
  var SEVERITY_WARNING = 4;
  // Long enough to recognise the statement, short enough not to push the
  // location off the end of the row.
  var CODE_PREVIEW_LIMIT = 120;

  // The offending source line, trimmed, for display beside the message. Markers
  // can outlive the edit that invalidated them by a frame, so a line number
  // past the end of the buffer yields nothing rather than throwing.
  function codePreview(model, lineNumber) {
    if (!lineNumber || lineNumber < 1 || lineNumber > model.getLineCount()) return '';

    var text = model.getLineContent(lineNumber).trim();
    return text.length > CODE_PREVIEW_LIMIT ? text.slice(0, CODE_PREVIEW_LIMIT) + '…' : text;
  }

  // Reading markers means walking every model, so callers that only want the
  // counts share this one pass. Exposed on the component for the status bar.
  function collect() {
    var monaco = window.monaco;
    if (!monaco || !monaco.editor) return { errors: [], warnings: [], byFile: [] };

    var errors = [];
    var warnings = [];
    var byFile = [];

    monaco.editor.getModels().forEach(function (model) {
      var path = model._mbeditorPath;
      if (!path || model.isDisposed()) return;

      var markers = monaco.editor.getModelMarkers({ resource: model.uri }).filter(function (m) {
        return m.severity === SEVERITY_ERROR || m.severity === SEVERITY_WARNING;
      });
      if (markers.length === 0) return;

      markers.sort(function (a, b) { return a.startLineNumber - b.startLineNumber; });

      // Carry the source line alongside the marker: read here, while the model
      // is in hand, rather than looking the model up again at render time.
      var entries = markers.map(function (m) {
        (m.severity === SEVERITY_ERROR ? errors : warnings).push(m);
        return { marker: m, code: codePreview(model, m.startLineNumber) };
      });

      byFile.push({ path: path, markers: entries });
    });

    byFile.sort(function (a, b) { return a.path < b.path ? -1 : a.path > b.path ? 1 : 0; });
    return { errors: errors, warnings: warnings, byFile: byFile };
  }

  function counts() {
    var all = collect();
    return { errors: all.errors.length, warnings: all.warnings.length };
  }

  var Panel = function ProblemsPanelComponent(_ref) {
    var onClose = _ref.onClose;
    var onOpenFile = _ref.onOpenFile;

    var _problems = React.useState(collect);
    var problems = _problems[0], setProblems = _problems[1];
    var _filter = React.useState('');
    var filter = _filter[0], setFilter = _filter[1];

    var MIN_HEIGHT = 120;
    var _height = React.useState(function () {
      var saved = parseInt(window.localStorage.getItem('mbeditorProblemsHeight'), 10);
      return (saved && saved >= MIN_HEIGHT) ? saved : 240;
    });
    var height = _height[0], setHeight = _height[1];
    var heightRef = React.useRef(height);
    heightRef.current = height;

    // Same delta-based resize as the log drawer.
    var onResizeMouseDown = function (e) {
      e.preventDefault();
      var startY = e.clientY;
      var startHeight = heightRef.current;
      var onMove = function (ev) {
        var vh = window.innerHeight || document.documentElement.clientHeight || 0;
        var maxH = vh > 0 ? Math.round(vh * 0.85) : Infinity;
        setHeight(Math.min(maxH, Math.max(MIN_HEIGHT, startHeight + (startY - ev.clientY))));
      };
      var onUp = function () {
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
        window.localStorage.setItem('mbeditorProblemsHeight', String(heightRef.current));
      };
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    };

    React.useEffect(function () {
      if (!window.monaco || !window.monaco.editor) return;
      var refresh = function () { setProblems(collect()); };
      var sub = window.monaco.editor.onDidChangeMarkers(refresh);
      refresh();
      return function () { sub.dispose(); };
    }, []);

    var needle = filter.trim().toLowerCase();
    var shown = needle
      ? problems.byFile.map(function (entry) {
          return {
            path: entry.path,
            markers: entry.markers.filter(function (item) {
              return (item.marker.message + ' ' + item.code + ' ' + entry.path)
                .toLowerCase().indexOf(needle) !== -1;
            })
          };
        }).filter(function (entry) { return entry.markers.length > 0; })
      : problems.byFile;

    var total = problems.errors.length + problems.warnings.length;

    return React.createElement(
      'div',
      { className: 'ide-problems-drawer', style: { height: height + 'px' } },
      React.createElement('div', {
        className: 'ide-problems-resize',
        title: 'Drag to resize',
        onMouseDown: onResizeMouseDown
      }),
      React.createElement(
        'div',
        { className: 'ide-problems-header' },
        React.createElement('i', { className: 'fas fa-bug' }),
        React.createElement('span', { className: 'ide-problems-title' }, 'Problems'),
        React.createElement(
          'span',
          { className: 'ide-problems-summary' },
          problems.errors.length + ' error' + (problems.errors.length === 1 ? '' : 's') +
            ', ' + problems.warnings.length + ' warning' + (problems.warnings.length === 1 ? '' : 's') +
            ' in open files'
        ),
        React.createElement('input', {
          className: 'ide-problems-filter',
          type: 'text',
          placeholder: 'Filter…',
          value: filter,
          onChange: function (e) { setFilter(e.target.value); }
        }),
        React.createElement('button', {
          type: 'button', className: 'ide-problems-btn',
          title: 'Close', onClick: onClose
        }, React.createElement('i', { className: 'fas fa-times' }))
      ),
      React.createElement(
        'div',
        { className: 'ide-problems-body' },
        total === 0
          ? React.createElement('div', { className: 'ide-problems-empty' }, 'No problems in the open files')
          : shown.length === 0
            ? React.createElement('div', { className: 'ide-problems-empty' }, 'No problems match the filter')
            : shown.map(function (entry) {
                return React.createElement(
                  'div',
                  { className: 'ide-problems-file', key: entry.path },
                  React.createElement(
                    'div',
                    { className: 'ide-problems-file-name' },
                    entry.path,
                    React.createElement('span', { className: 'ide-problems-file-count' }, entry.markers.length)
                  ),
                  entry.markers.map(function (item, index) {
                    var marker = item.marker;
                    var isError = marker.severity === SEVERITY_ERROR;
                    return React.createElement(
                      'button',
                      {
                        type: 'button',
                        className: 'ide-problems-item ide-problems-item-' + (isError ? 'error' : 'warning'),
                        key: entry.path + ':' + marker.startLineNumber + ':' + index,
                        'aria-label': (isError ? 'Error' : 'Warning') + ': ' + marker.message +
                          ', ' + entry.path + ' line ' + marker.startLineNumber +
                          (item.code ? ', source: ' + item.code : ''),
                        onClick: function () {
                          if (onOpenFile) onOpenFile(entry.path, marker.startLineNumber, marker.startColumn);
                        }
                      },
                      React.createElement('i', {
                        className: 'fas ' + (isError ? 'fa-bug' : 'fa-exclamation-triangle') + ' ide-problems-icon',
                        'aria-hidden': 'true'
                      }),
                      React.createElement('span', { className: 'ide-problems-msg' }, marker.message),
                      item.code && React.createElement('code', { className: 'ide-problems-code' }, item.code),
                      marker.source && React.createElement('span', { className: 'ide-problems-source' }, marker.source),
                      React.createElement(
                        'span',
                        { className: 'ide-problems-loc' },
                        '[' + marker.startLineNumber + ', ' + marker.startColumn + ']'
                      )
                    );
                  })
                );
              })
      )
    );
  };

  Panel.collect = collect;
  Panel.counts = counts;
  return Panel;
})();

window.ProblemsPanel = ProblemsPanel;
