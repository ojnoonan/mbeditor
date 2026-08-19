'use strict';

// TestRunPanel — bottom drawer for a whole-suite run.
//
// Deliberately not a modal, unlike the per-file TestResultsPanel: a suite run
// takes minutes, and a backdrop that blocks the editor for the duration turns
// the wait into dead time. This docks alongside Problems and the log, so you
// can keep reading code while it runs and keep the failures on screen while
// you fix them.
//
// Structure and CSS are shared with ProblemsPanel on purpose — same drawer,
// same header, same clickable rows — rather than a second near-identical
// stylesheet.
var TestRunPanel = (function () {
  var STATUS_ICON = {
    pass: 'fa-check-circle',
    fail: 'fa-times-circle',
    error: 'fa-exclamation-circle',
    skip: 'fa-forward'
  };
  var STATUS_KIND = { fail: 'error', error: 'error', skip: 'info', pass: 'info' };

  function isFailure(t) { return t.status === 'fail' || t.status === 'error'; }

  // Closing the drawer unmounts it, so the result is kept outside the
  // component. localStorage rather than a module variable, to match the
  // per-file test cache in MbeditorApp — a suite run is the most expensive
  // thing the editor can ask for, and losing it to a page reload is the same
  // annoyance as losing it to a close.
  var CACHE_KEY = 'mbeditor_test_result_suite';
  // The runner's raw output is unbounded — a verbose suite easily runs to
  // megabytes, and a quota error means nothing is cached at all, which is the
  // exact failure this is here to prevent. The tail is the part worth keeping:
  // failures and the summary line are at the end.
  var RAW_CACHE_LIMIT = 200000;

  function loadCached() {
    try {
      var stored = window.localStorage.getItem(CACHE_KEY);
      return stored ? JSON.parse(stored) : null;
    } catch (e) {
      return null;
    }
  }

  function saveCached(result) {
    try {
      var raw = result && result.raw;
      var slim = (raw && raw.length > RAW_CACHE_LIMIT)
        ? Object.assign({}, result, { raw: '…output truncated…\n' + raw.slice(-RAW_CACHE_LIMIT) })
        : result;
      window.localStorage.setItem(CACHE_KEY, JSON.stringify(slim));
    } catch (e) { /* quota or storage blocked — the run still shows, just isn't kept */ }
  }

  function clearCached() {
    try { window.localStorage.removeItem(CACHE_KEY); } catch (e) {}
  }

  function ranAtLabel(result) {
    if (!result || !result.cachedAt) return null;
    try {
      return 'ran ' + new Date(result.cachedAt).toLocaleTimeString();
    } catch (e) {
      return null;
    }
  }

  // Failures grouped by the file they live in — the unit you actually open.
  // Anything the server could not resolve to a workspace-relative path is
  // still listed, just not openable.
  function byFile(tests) {
    var order = [];
    var groups = {};
    tests.filter(isFailure).forEach(function (t) {
      var key = t.file || '';
      if (!groups[key]) { groups[key] = []; order.push(key); }
      groups[key].push(t);
    });
    return order.map(function (k) { return { path: k, tests: groups[k] }; });
  }

  var Panel = function TestRunPanelComponent(_ref) {
    var onClose = _ref.onClose;
    var onOpenFile = _ref.onOpenFile;

    var _result = React.useState(loadCached);
    var result = _result[0], setResult = _result[1];
    var _running = React.useState(false);
    var running = _running[0], setRunning = _running[1];
    var _showRaw = React.useState(false);
    var showRaw = _showRaw[0], setShowRaw = _showRaw[1];

    // Elapsed seconds while a run is in flight. A suite run is long enough
    // that a spinner with no number reads as "hung".
    var _elapsed = React.useState(0);
    var elapsed = _elapsed[0], setElapsed = _elapsed[1];
    React.useEffect(function () {
      if (!running) return;
      var started = Date.now();
      var id = setInterval(function () {
        setElapsed(Math.round((Date.now() - started) / 1000));
      }, 1000);
      return function () { clearInterval(id); };
    }, [running]);

    var run = function () {
      if (running) return;
      setRunning(true);
      setElapsed(0);
      var finish = function (data) {
        var stamped = Object.assign({}, data, { cachedAt: Date.now() });
        setResult(stamped);
        saveCached(stamped);
      };
      FileService.runAllTests()
        .then(finish)
        ["catch"](function (e) {
          var res = e && e.response && e.response.data;
          finish(res || { ok: false, error: (e && e.message) || 'Test run failed', tests: [] });
        })
        .then(function () { setRunning(false); });
    };

    var failures = byFile((result && result.tests) || []);
    var openable = failures.filter(function (g) { return g.path; });

    var openFailing = function () {
      if (!onOpenFile) return;
      openable.forEach(function (g) {
        onOpenFile(g.path, (g.tests[0] && g.tests[0].line) || 1, 1);
      });
    };

    // A checkout changes what the suite would even run, so the old result is
    // dropped rather than left looking current — same rule as the RuboCop
    // snapshot in the Problems panel.
    React.useEffect(function () {
      var onBranchChanged = function () { setResult(null); clearCached(); };
      window.addEventListener('mbeditor:branch-changed', onBranchChanged);
      return function () { window.removeEventListener('mbeditor:branch-changed', onBranchChanged); };
    }, []);

    var MIN_HEIGHT = 120;
    var _height = React.useState(function () {
      var saved = parseInt(window.localStorage.getItem('mbeditorTestRunHeight'), 10);
      return (saved && saved >= MIN_HEIGHT) ? saved : 260;
    });
    var height = _height[0], setHeight = _height[1];
    var heightRef = React.useRef(height);
    heightRef.current = height;

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
        window.localStorage.setItem('mbeditorTestRunHeight', String(heightRef.current));
      };
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    };

    var summary = result && result.summary;
    var failCount = failures.reduce(function (n, g) { return n + g.tests.length; }, 0);

    return React.createElement(
      'div',
      { className: 'ide-problems-drawer ide-testrun-drawer', style: { height: height + 'px' } },
      React.createElement('div', {
        className: 'ide-problems-resize', title: 'Drag to resize', onMouseDown: onResizeMouseDown
      }),
      React.createElement(
        'div',
        { className: 'ide-problems-header' },
        React.createElement('i', { className: 'fas fa-flask' }),
        React.createElement('span', { className: 'ide-problems-title' }, 'Test Run'),
        summary && React.createElement(
          'div',
          { className: 'ide-problems-severity-filter' },
          React.createElement('span', { className: 'ide-testrun-stat ide-testrun-pass' },
            (summary.passed || 0) + ' passed'),
          React.createElement('span', { className: 'ide-testrun-stat ide-testrun-fail' },
            ((summary.failed || 0) + (summary.errored || 0)) + ' failed'),
          (summary.skipped || 0) > 0 && React.createElement('span', { className: 'ide-testrun-stat' },
            summary.skipped + ' skipped'),
          summary.duration != null && React.createElement('span', { className: 'ide-testrun-stat' },
            summary.duration + 's'),
          ranAtLabel(result) && React.createElement('span', { className: 'ide-testrun-stat' },
            ranAtLabel(result))
        ),
        React.createElement(
          'div',
          { className: 'ide-problems-actions' },
          React.createElement('button', {
            type: 'button', className: 'ide-problems-btn',
            disabled: running,
            title: 'Run the whole test suite',
            onClick: run
          },
            React.createElement('i', { className: running ? 'fas fa-spinner fa-spin' : 'fas fa-play' }),
            React.createElement('span', null, running ? ' Running ' + elapsed + 's' : ' Run all')),
          React.createElement('button', {
            type: 'button', className: 'ide-problems-btn',
            disabled: openable.length === 0,
            title: openable.length
              ? 'Open all ' + openable.length + ' file(s) with failures'
              : 'No failing files to open',
            onClick: openFailing
          },
            React.createElement('i', { className: 'fas fa-folder-open' }),
            React.createElement('span', null, ' Open failing' + (openable.length ? ' (' + openable.length + ')' : ''))),
          result && result.raw && React.createElement('button', {
            type: 'button',
            className: 'ide-problems-btn' + (showRaw ? ' is-on' : ''),
            title: 'Show the runner’s raw output',
            'aria-pressed': showRaw ? 'true' : 'false',
            onClick: function () { setShowRaw(function (p) { return !p; }); }
          },
            React.createElement('i', { className: 'fas fa-terminal' }),
            React.createElement('span', null, ' Output'))
        ),
        React.createElement('button', {
          type: 'button', className: 'ide-problems-btn',
          title: 'Close', onClick: onClose
        }, React.createElement('i', { className: 'fas fa-times' }))
      ),
      React.createElement(
        'div',
        { className: 'ide-problems-body' },
        result && result.error && React.createElement('div',
          { className: 'ide-problems-empty' }, 'Test run failed: ' + result.error),
        showRaw && result && result.raw
          ? React.createElement('pre', { className: 'ide-testrun-raw' }, result.raw)
          : !result && !running
            ? React.createElement('div', { className: 'ide-problems-empty' },
                'Press Run all to run the whole suite')
            : running && !result
              ? React.createElement('div', { className: 'ide-problems-empty' },
                  'Running the suite… ' + elapsed + 's')
              : failCount === 0 && result && !result.error
                ? React.createElement('div', { className: 'ide-problems-empty' }, 'No failing tests')
                : failures.map(function (group) {
                    return React.createElement(
                      'div',
                      { className: 'ide-problems-file', key: 'tr:' + (group.path || '(unknown)') },
                      React.createElement(
                        'div',
                        { className: 'ide-problems-file-name' },
                        React.createElement('i', { className: 'fas fa-flask', 'aria-hidden': 'true' }),
                        ' ' + (group.path || 'Unknown file'),
                        React.createElement('span', { className: 'ide-problems-file-count' }, group.tests.length)
                      ),
                      group.tests.map(function (t, i) {
                        var kind = STATUS_KIND[t.status] || 'info';
                        return React.createElement(
                          'button',
                          {
                            type: 'button',
                            className: 'ide-problems-item ide-problems-item-' + kind,
                            key: 'tr:' + (group.path || '') + ':' + i,
                            disabled: !group.path,
                            title: t.name + (t.message ? '\n' + t.message : ''),
                            'aria-label': t.status + ': ' + t.name +
                              (group.path ? ', ' + group.path + ' line ' + (t.line || 1) : ''),
                            onClick: function () {
                              if (group.path && onOpenFile) onOpenFile(group.path, t.line || 1, 1);
                            }
                          },
                          React.createElement('i', {
                            className: 'fas ' + (STATUS_ICON[t.status] || 'fa-circle') + ' ide-problems-icon',
                            'aria-hidden': 'true'
                          }),
                          React.createElement('span', { className: 'ide-problems-msg' }, t.name),
                          t.message && React.createElement('code', { className: 'ide-problems-code' },
                            t.message.split('\n')[0]),
                          t.line && React.createElement('span', { className: 'ide-problems-loc' }, '[' + t.line + ']')
                        );
                      })
                    );
                  })
      )
    );
  };

  return Panel;
})();

window.TestRunPanel = TestRunPanel;
