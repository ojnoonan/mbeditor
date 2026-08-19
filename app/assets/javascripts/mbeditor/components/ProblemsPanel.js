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
  var SEVERITY_INFO = 2;
  var SEVERITY_HINT = 1;

  // Info and Hint share a row style: both mean "worth knowing, not worth
  // stopping for", and two shades of grey would be a distinction without a
  // difference in a list this dense.
  var SEVERITY_KIND = { 8: 'error', 4: 'warning', 2: 'info', 1: 'info' };
  var SEVERITY_ICON = {
    error: 'fa-bug',
    warning: 'fa-exclamation-triangle',
    info: 'fa-info-circle'
  };
  var SEVERITY_LABEL = { error: 'Error', warning: 'Warning', info: 'Info' };
  // RuboCop's own severity names (the /rubocop JSON carries strings, not the
  // numeric Monaco severities the markers use).
  var COP_SEVERITY_KIND = {
    fatal: 'error', error: 'error', warning: 'warning',
    convention: 'info', refactor: 'info', info: 'info'
  };

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
    if (!monaco || !monaco.editor) return { errors: [], warnings: [], infos: [], byFile: [] };

    var errors = [];
    var warnings = [];
    // RuboCop's convention and refactor offenses grade as Info, and its own
    // `info` level as Hint. Listing only errors and warnings would hide the
    // majority of a lint run.
    var infos = [];
    var byFile = [];

    monaco.editor.getModels().forEach(function (model) {
      var path = model._mbeditorPath;
      if (!path || model.isDisposed()) return;

      var markers = monaco.editor.getModelMarkers({ resource: model.uri }).filter(function (m) {
        return m.severity === SEVERITY_ERROR || m.severity === SEVERITY_WARNING ||
               m.severity === SEVERITY_INFO || m.severity === SEVERITY_HINT;
      });
      if (markers.length === 0) return;

      markers.sort(function (a, b) { return a.startLineNumber - b.startLineNumber; });

      // Carry the source line alongside the marker: read here, while the model
      // is in hand, rather than looking the model up again at render time.
      var entries = markers.map(function (m) {
        var bucket = m.severity === SEVERITY_ERROR ? errors
          : m.severity === SEVERITY_WARNING ? warnings
          : infos;
        bucket.push(m);
        return { marker: m, code: codePreview(model, m.startLineNumber) };
      });

      byFile.push({ path: path, markers: entries });
    });

    byFile.sort(function (a, b) { return a.path < b.path ? -1 : a.path > b.path ? 1 : 0; });
    return { errors: errors, warnings: warnings, infos: infos, byFile: byFile };
  }

  // The status bar deliberately tallies only errors and warnings: a count that
  // included every convention offense would be a number nobody acts on.
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

    // Which severities the list shows. Multi-select rather than a single
    // dropdown: "errors and warnings, but not the convention noise" is the
    // view people actually want, and a one-of-three picker can't express it.
    // Persisted, because a filter you have to re-set every time you open the
    // panel is one you stop using.
    var _severities = React.useState(function () {
      try {
        var saved = JSON.parse(window.localStorage.getItem('mbeditorProblemsSeverities'));
        if (saved && typeof saved === 'object') {
          return { error: saved.error !== false, warning: saved.warning !== false, info: saved.info !== false };
        }
      } catch (e) { /* unparseable or storage blocked — fall through to the default */ }
      return { error: true, warning: true, info: true };
    });
    var severities = _severities[0], setSeverities = _severities[1];

    var toggleSeverity = function (kind) {
      setSeverities(function (prev) {
        var next = Object.assign({}, prev);
        next[kind] = !next[kind];
        // Turning the last one off would show an empty panel with no hint as
        // to why, so the final active severity stays latched on.
        if (!next.error && !next.warning && !next.info) return prev;
        try { window.localStorage.setItem('mbeditorProblemsSeverities', JSON.stringify(next)); } catch (e) {}
        return next;
      });
    };

    // Exceptions raised by the host app. Unlike markers these are not per-model
    // — a runtime failure isn't a property of a file you happen to have open —
    // so they live in their own section above the marker list.
    var _exceptions = React.useState([]);
    var exceptions = _exceptions[0], setExceptions = _exceptions[1];

    React.useEffect(function () {
      var cancelled = false;
      if (FileService.getExceptions) {
        FileService.getExceptions().then(function (data) {
          if (!cancelled) setExceptions((data && data.exceptions) || []);
        })["catch"](function () { /* older host, or capture disabled */ });
      }

      // Live push while the panel is open.
      var onException = function (e) {
        setExceptions(function (prev) {
          return [e.detail].concat(prev).slice(0, 50);
        });
      };
      window.addEventListener('mbeditor:exception', onException);
      return function () {
        cancelled = true;
        window.removeEventListener('mbeditor:exception', onException);
      };
    }, []);

    var clearExceptions = function () {
      setExceptions([]);
      if (FileService.clearExceptions) FileService.clearExceptions()["catch"](function () {});
    };

    // Whole-workspace rubocop. Separate from `problems` above: markers only
    // exist for models Monaco has loaded, so this is the only view that can
    // see a file nobody has opened.
    var _workspace = React.useState(null);
    var workspace = _workspace[0], setWorkspace = _workspace[1];
    var _running = React.useState(null);
    var running = _running[0], setRunning = _running[1];

    var runRubocop = function (mode) {
      if (running) return;
      setRunning(mode);
      FileService.runRubocop(mode)
        .then(function (data) { setWorkspace(data); })
        ["catch"](function (e) {
          var res = e && e.response && e.response.data;
          setWorkspace(res || { ok: false, error: (e && e.message) || 'RuboCop failed', files: [] });
        })
        .then(function () { setRunning(null); });
    };

    // The workspace list is a snapshot of one run against one working tree.
    // After a checkout it describes files that may no longer have those
    // offenses — or no longer exist — so it is dropped rather than left to
    // look current.
    React.useEffect(function () {
      var onBranchChanged = function () { setWorkspace(null); };
      window.addEventListener('mbeditor:branch-changed', onBranchChanged);
      return function () { window.removeEventListener('mbeditor:branch-changed', onBranchChanged); };
    }, []);

    var openAllOffending = function () {
      if (!workspace || !onOpenFile) return;
      var files = workspace.files || [];
      // Each open is a Monaco model plus a tab; a default-config run over a
      // real app returns hundreds, which would wedge the editor silently.
      if (files.length > 20 && !window.confirm('Open ' + files.length + ' files?')) return;
      files.forEach(function (f) {
        onOpenFile(f.path, (f.offenses[0] && f.offenses[0].line) || 1, 1);
      });
    };

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
    var allSeverities = severities.error && severities.warning && severities.info;
    var shown = (needle || !allSeverities)
      ? problems.byFile.map(function (entry) {
          return {
            path: entry.path,
            markers: entry.markers.filter(function (item) {
              if (!severities[SEVERITY_KIND[item.marker.severity] || 'info']) return false;
              if (!needle) return true;
              return (item.marker.message + ' ' + item.code + ' ' + entry.path)
                .toLowerCase().indexOf(needle) !== -1;
            })
          };
        }).filter(function (entry) { return entry.markers.length > 0; })
      : problems.byFile;

    var total = problems.errors.length + problems.warnings.length + problems.infos.length;

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
        // No prose summary: the severity chips below carry the same three
        // counts, and restating them was the longest thing in the header.
        React.createElement(
          'div',
          { className: 'ide-problems-severity-filter' },
          [
            { kind: 'error', count: problems.errors.length },
            { kind: 'warning', count: problems.warnings.length },
            { kind: 'info', count: problems.infos.length }
          ].map(function (s) {
            var on = severities[s.kind];
            return React.createElement(
              'button',
              {
                key: s.kind,
                type: 'button',
                className: 'ide-problems-sev-chip ide-problems-sev-' + s.kind + (on ? ' is-on' : ''),
                title: (on ? 'Hide' : 'Show') + ' ' + SEVERITY_LABEL[s.kind].toLowerCase() + 's',
                'aria-pressed': on ? 'true' : 'false',
                onClick: function () { toggleSeverity(s.kind); }
              },
              React.createElement('i', { className: 'fas ' + SEVERITY_ICON[s.kind] }),
              React.createElement('span', null, s.count)
            );
          })
        ),
        React.createElement(
          'div',
          { className: 'ide-problems-actions' },
          React.createElement('button', {
            type: 'button', className: 'ide-problems-btn',
            disabled: !!running,
            title: 'Run rubocop over the whole workspace',
            onClick: function () { runRubocop('check'); }
          },
            React.createElement('i', { className: running === 'check' ? 'fas fa-spinner fa-spin' : 'fas fa-play' }),
            React.createElement('span', null, ' RuboCop')),
          React.createElement('button', {
            type: 'button', className: 'ide-problems-btn',
            // Nothing to correct until a run says so, and rerunning `-a` on a
            // clean tree is a slow no-op.
            disabled: !!running || !workspace || !workspace.correctable,
            title: workspace && workspace.correctable
              ? 'Safe-autocorrect ' + workspace.correctable + ' offense(s) and rerun'
              : 'Run RuboCop first',
            onClick: function () { runRubocop('autocorrect'); }
          },
            React.createElement('i', { className: running === 'autocorrect' ? 'fas fa-spinner fa-spin' : 'fas fa-magic' }),
            React.createElement('span', null, ' Fix')),
          React.createElement('button', {
            type: 'button', className: 'ide-problems-btn',
            disabled: !workspace || !(workspace.files || []).length,
            title: workspace && (workspace.files || []).length
              ? 'Open all ' + workspace.files.length + ' file(s) with offenses'
              : 'Run RuboCop first',
            onClick: openAllOffending
          },
            React.createElement('i', { className: 'fas fa-folder-open' }),
            React.createElement('span', null, ' Open all'))
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
        workspace && React.createElement(
          'div',
          { className: 'ide-problems-workspace' },
          workspace.error
            ? React.createElement('div', { className: 'ide-problems-empty' }, 'RuboCop: ' + workspace.error)
            : (workspace.files || []).length === 0
              ? React.createElement('div', { className: 'ide-problems-empty' }, 'RuboCop found no offenses in the workspace')
              : workspace.files.map(function (file) {
                  return React.createElement(
                    'div',
                    { className: 'ide-problems-file', key: 'ws:' + file.path },
                    React.createElement(
                      'div',
                      { className: 'ide-problems-file-name' },
                      React.createElement('i', { className: 'fas fa-gavel', 'aria-hidden': 'true' }),
                      ' ' + file.path,
                      React.createElement('span', { className: 'ide-problems-file-count' }, file.offenses.length)
                    ),
                    file.offenses.map(function (o, i) {
                      var kind = COP_SEVERITY_KIND[o.severity] || 'info';
                      return React.createElement(
                        'button',
                        {
                          type: 'button',
                          className: 'ide-problems-item ide-problems-item-' + kind,
                          key: 'ws:' + file.path + ':' + i,
                          title: o.message + '\n' + file.path + ':' + o.line,
                          'aria-label': SEVERITY_LABEL[kind] + ': ' + o.message + ', ' + file.path + ' line ' + o.line,
                          onClick: function () { if (onOpenFile) onOpenFile(file.path, o.line, o.column); }
                        },
                        React.createElement('i', {
                          className: 'fas ' + SEVERITY_ICON[kind] + ' ide-problems-icon', 'aria-hidden': 'true'
                        }),
                        React.createElement('span', { className: 'ide-problems-msg' }, o.message),
                        React.createElement('span', { className: 'ide-problems-source' }, o.copName),
                        o.correctable && React.createElement('span', { className: 'ide-problems-source' }, 'fixable'),
                        React.createElement('span', { className: 'ide-problems-loc' }, '[' + o.line + ', ' + o.column + ']')
                      );
                    })
                  );
                })
        ),
        exceptions.length > 0 && React.createElement(
          'div',
          { className: 'ide-problems-file ide-problems-exceptions' },
          React.createElement(
            'div',
            { className: 'ide-problems-file-name' },
            React.createElement('i', { className: 'fas fa-bolt', 'aria-hidden': 'true' }),
            ' Exceptions',
            React.createElement('span', { className: 'ide-problems-file-count' }, exceptions.length),
            React.createElement('button', {
              type: 'button', className: 'ide-problems-btn ide-problems-clear',
              title: 'Clear recorded exceptions', onClick: clearExceptions
            }, React.createElement('i', { className: 'fas fa-times' }))
          ),
          exceptions.map(function (ex) {
            return React.createElement(
              'div',
              { className: 'ide-problems-exception', key: ex.id },
              React.createElement(
                'div',
                { className: 'ide-problems-item ide-problems-item-error ide-problems-exception-head' },
                React.createElement('i', { className: 'fas fa-bolt ide-problems-icon', 'aria-hidden': 'true' }),
                React.createElement('span', { className: 'ide-problems-msg' }, ex.klass + ': ' + ex.message),
                (ex.controller || ex.path) && React.createElement(
                  'span',
                  { className: 'ide-problems-source' },
                  ex.controller ? ex.controller + '#' + ex.action : ex.path
                )
              ),
              // Only workspace frames survive the server side, so every one of
              // these is a file this editor can actually open.
              (ex.frames || []).map(function (f, i) {
                return React.createElement(
                  'button',
                  {
                    type: 'button',
                    className: 'ide-problems-item ide-problems-frame',
                    key: ex.id + ':' + i,
                    title: 'Open ' + f.file + ':' + f.line,
                    'aria-label': 'Open ' + f.file + ' line ' + f.line,
                    onClick: function () { if (onOpenFile) onOpenFile(f.file, f.line, 1); }
                  },
                  React.createElement('span', { className: 'ide-problems-code' }, f.file),
                  React.createElement('span', { className: 'ide-problems-loc' }, '[' + f.line + ']')
                );
              })
            );
          })
        ),
        total === 0 && (exceptions.length > 0 || workspace)
          ? null
          : total === 0
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
                    var kind = SEVERITY_KIND[marker.severity] || 'info';
                    var docsHref = marker.code && marker.code.target
                      ? String(marker.code.target)
                      : null;
                    return React.createElement(
                      'button',
                      {
                        type: 'button',
                        className: 'ide-problems-item ide-problems-item-' + kind,
                        key: entry.path + ':' + marker.startLineNumber + ':' + index,
                        // The message ellipsises in a short panel, so the full
                        // text is on hover as well as on the label.
                        title: marker.message + '\n' + entry.path + ':' + marker.startLineNumber +
                          (item.code ? ' — ' + item.code : ''),
                        'aria-label': SEVERITY_LABEL[kind] + ': ' + marker.message +
                          ', ' + entry.path + ' line ' + marker.startLineNumber +
                          (item.code ? ', source: ' + item.code : ''),
                        onClick: function () {
                          if (onOpenFile) onOpenFile(entry.path, marker.startLineNumber, marker.startColumn);
                        }
                      },
                      React.createElement('i', {
                        className: 'fas ' + SEVERITY_ICON[kind] + ' ide-problems-icon',
                        'aria-hidden': 'true'
                      }),
                      React.createElement('span', { className: 'ide-problems-msg' }, marker.message),
                      item.code && React.createElement('code', { className: 'ide-problems-code' }, item.code),
                      // RuboCop ships a docs URL per cop; when the marker carries
                      // one, the cop name becomes a link out to it. stopPropagation
                      // so following it doesn't also jump the editor to the offense.
                      docsHref && React.createElement('a', {
                        className: 'ide-problems-docs',
                        href: docsHref,
                        target: '_blank',
                        rel: 'noopener noreferrer',
                        title: 'Documentation for ' + marker.code.value,
                        onClick: function (e) { e.stopPropagation(); }
                      }, marker.code.value),
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
