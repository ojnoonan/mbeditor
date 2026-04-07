'use strict';

var TestResultsPanel = function TestResultsPanel(_ref) {
  var result = _ref.result;
  var testFile = _ref.testFile;
  var isLoading = _ref.isLoading;
  var onClose = _ref.onClose;
  var showInline = _ref.showInline;
  var onToggleInline = _ref.onToggleInline;
  var onOpenTestFile = _ref.onOpenTestFile;
  var onRerun = _ref.onRerun;

  if (!result && !isLoading) return null;

  var summary = result && result.summary;
  var tests = result && result.tests || [];
  var error = result && result.error;

  var statusIcon = function statusIcon(status) {
    if (status === 'pass') return React.createElement('i', { className: 'fas fa-check-circle', style: { color: '#4ec9b0', marginRight: '6px' } });
    if (status === 'fail') return React.createElement('i', { className: 'fas fa-times-circle', style: { color: '#f14c4c', marginRight: '6px' } });
    if (status === 'error') return React.createElement('i', { className: 'fas fa-exclamation-circle', style: { color: '#cca700', marginRight: '6px' } });
    if (status === 'skip') return React.createElement('i', { className: 'fas fa-forward', style: { color: '#888', marginRight: '6px' } });
    return React.createElement('i', { className: 'fas fa-circle', style: { color: '#888', marginRight: '6px' } });
  };

  return React.createElement(
    React.Fragment,
    null,
    React.createElement('div', { className: 'ide-modal-backdrop', onClick: onClose }),
    React.createElement(
    'div',
    { className: 'ide-modal-panel' },
    React.createElement(
      'div',
      { className: 'ide-file-history-header' },
      React.createElement(
        'div',
        { className: 'ide-file-history-title' },
        React.createElement('i', { className: isLoading ? 'fas fa-spinner fa-spin' : 'fas fa-flask' }),
        React.createElement(
          'span',
          null,
          'Tests: ',
          testFile ? testFile.split('/').pop() : 'Results'
        )
      ),
      React.createElement(
        'div',
        { style: { display: 'flex', alignItems: 'center', gap: '6px' } },
        !isLoading && onRerun && React.createElement(
          'button',
          {
            className: 'ide-icon-btn',
            onClick: onRerun,
            title: 'Run Again',
            style: { fontSize: '11px', padding: '2px 6px', background: 'rgba(255,255,255,0.08)', border: 'none', color: '#ccc', cursor: 'pointer', borderRadius: '3px' }
          },
          React.createElement('i', { className: 'fas fa-redo', style: { marginRight: '4px' } }),
          'Run Again'
        ),
        onToggleInline && React.createElement(
          'button',
          {
            className: 'ide-icon-btn' + (showInline ? ' active' : ''),
            onClick: onToggleInline,
            title: showInline ? 'Hide inline markers' : 'Show inline markers',
            style: { fontSize: '11px', padding: '2px 5px', opacity: showInline ? 1 : 0.6, background: showInline ? 'rgba(255,255,255,0.1)' : 'transparent', border: 'none', color: '#ccc', cursor: 'pointer', borderRadius: '3px' }
          },
          React.createElement('i', { className: 'fas fa-map-marker-alt' })
        ),
        onOpenTestFile && React.createElement(
          'button',
          {
            className: 'ide-icon-btn',
            onClick: onOpenTestFile,
            title: 'Open test file',
            style: { fontSize: '11px', padding: '2px 5px', background: 'transparent', border: 'none', color: '#ccc', cursor: 'pointer', borderRadius: '3px' }
          },
          React.createElement('i', { className: 'fas fa-external-link-alt', style: { marginRight: '4px' } }),
          'Open Test File'
        ),
        React.createElement(
          'button',
          { className: 'ide-icon-btn', onClick: onClose, title: 'Close Test Results' },
          React.createElement('i', { className: 'fas fa-times' })
        )
      )
    ),
    React.createElement(
      'div',
      { className: 'ide-file-history-content' },
      isLoading ? React.createElement(
        'div',
        { className: 'ide-loading-state' },
        React.createElement('i', { className: 'fas fa-spinner fa-spin' }),
        ' Running tests...'
      ) : error ? React.createElement(
        'div',
        { className: 'ide-error-state' },
        error
      ) : !summary ? React.createElement(
        'div',
        { className: 'ide-empty-state' },
        'No test results.'
      ) : React.createElement(
        'div',
        null,
        React.createElement(
          'div',
          { style: { padding: '8px 12px', borderBottom: '1px solid #3c3c3c', fontSize: '12px', color: '#ccc', display: 'flex', gap: '12px', flexWrap: 'wrap' } },
          React.createElement('span', null, React.createElement('strong', null, summary.total), ' total'),
          summary.passed > 0 && React.createElement('span', { style: { color: '#4ec9b0' } }, React.createElement('i', { className: 'fas fa-check-circle', style: { marginRight: '3px' } }), summary.passed, ' passed'),
          summary.failed > 0 && React.createElement('span', { style: { color: '#f14c4c' } }, React.createElement('i', { className: 'fas fa-times-circle', style: { marginRight: '3px' } }), summary.failed, ' failed'),
          summary.errored > 0 && React.createElement('span', { style: { color: '#cca700' } }, React.createElement('i', { className: 'fas fa-exclamation-circle', style: { marginRight: '3px' } }), summary.errored, ' errors'),
          summary.skipped > 0 && React.createElement('span', { style: { color: '#888' } }, summary.skipped, ' skipped'),
          summary.duration != null && React.createElement('span', { style: { color: '#888' } }, summary.duration, 's'),
          result.cachedAt && React.createElement('span', { style: { color: '#666', marginLeft: 'auto', fontSize: '10px' } }, 'ran ', new Date(result.cachedAt).toLocaleTimeString())
        ),
        tests.length > 0 ? React.createElement(
          'div',
          { className: 'git-list' },
          tests.map(function (t, i) {
            return React.createElement(
              'div',
              { key: i, className: 'git-commit-item', style: { cursor: 'default' } },
              React.createElement(
                'div',
                { className: 'git-commit-title', style: { display: 'flex', alignItems: 'center' } },
                statusIcon(t.status),
                React.createElement('span', { title: t.name }, t.name)
              ),
              t.message && React.createElement(
                'div',
                { className: 'git-commit-meta', style: { color: '#f14c4c', whiteSpace: 'pre-wrap', fontFamily: 'monospace', fontSize: '11px', marginTop: '4px', maxHeight: '120px', overflow: 'auto' } },
                t.message
              ),
              t.line && React.createElement(
                'div',
                { className: 'git-commit-meta' },
                'Line ',
                t.line
              )
            );
          })
        ) : React.createElement(
          'div',
          { style: { padding: '8px 12px', fontSize: '12px', color: '#888' } },
          summary.total > 0 ? 'All tests passed.' : 'No test details available. Check raw output.'
        ),
        result && result.raw && tests.length === 0 && React.createElement(
          'details',
          { style: { padding: '8px 12px' } },
          React.createElement('summary', { style: { cursor: 'pointer', color: '#888', fontSize: '11px' } }, 'Raw output'),
          React.createElement('pre', { style: { fontSize: '11px', color: '#ccc', whiteSpace: 'pre-wrap', maxHeight: '300px', overflow: 'auto', marginTop: '6px' } }, result.raw)
        )
      )
    )
  )
  );
};

window.TestResultsPanel = TestResultsPanel;
