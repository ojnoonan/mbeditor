'use strict';

// Renders the raw unified diff text produced by `git diff` for multiple files.
// Each line is colored (green = addition, red = deletion, blue = hunk header,
// dimmed = file header) giving a VS Code "Open Changes" style read-only view.
var CombinedDiffViewer = function CombinedDiffViewer(_ref) {
  var diffText = _ref.diffText;
  var label    = _ref.label;
  var isLoading = _ref.isLoading;

  var containerRef = React.useRef(null);

  // Track which file sections are collapsed.  Key = "diff --git …" header line.
  var _us = React.useState({});
  var collapsed = _us[0]; var setCollapsed = _us[1];

  if (isLoading) {
    return React.createElement(
      'div',
      { className: 'combined-diff-viewer combined-diff-loading-wrap' },
      React.createElement('span', { className: 'combined-diff-loading-msg' }, 'Loading\u2026')
    );
  }

  if (!diffText || !diffText.trim()) {
    return React.createElement(
      'div',
      { className: 'combined-diff-viewer combined-diff-empty' },
      React.createElement('i', { className: 'fas fa-check-circle', style: { marginRight: 8, color: '#89d185' } }),
      'No changes.'
    );
  }

  // Split the raw diff into per-file segments, each starting at "diff --git".
  var segments = [];
  var current = null;
  diffText.split('\n').forEach(function (line) {
    if (line.startsWith('diff --git ')) {
      if (current) segments.push(current);
      current = { header: line, lines: [line] };
    } else if (current) {
      current.lines.push(line);
    }
  });
  if (current) segments.push(current);

  // Extract a clean display path from the "diff --git a/foo b/foo" header
  function extractPath(headerLine) {
    var m = headerLine.match(/^diff --git a\/(.+) b\/(.+)$/);
    return m ? m[2] : headerLine.replace('diff --git ', '');
  }

  function renderSegment(seg, si) {
    var filePath = extractPath(seg.header);
    var parts = filePath.split('/');
    var fileName = parts.pop();
    var fileDir = parts.join('/');

    var isCollapsed = !!collapsed[si];

    var lineNodes = [];
    var inHunk = false;
    seg.lines.forEach(function (line, li) {
      // Skip the boring "diff --git / index / --- / +++" boilerplate at the top
      if (li === 0) return; // "diff --git" — shown in header
      if (line.startsWith('index ') || line.startsWith('old mode') || line.startsWith('new mode') || line.startsWith('new file') || line.startsWith('deleted file') || line.startsWith('Binary') || line.startsWith('rename ')) {
        lineNodes.push(React.createElement('div', { key: li, className: 'cdiff-line cdiff-meta' }, line));
        return;
      }
      if (line.startsWith('--- ') || line.startsWith('+++ ')) {
        lineNodes.push(React.createElement('div', { key: li, className: 'cdiff-line cdiff-file-header' }, line));
        inHunk = false;
        return;
      }
      if (line.startsWith('@@')) {
        inHunk = true;
        lineNodes.push(React.createElement('div', { key: li, className: 'cdiff-line cdiff-hunk' }, line));
        return;
      }
      if (!inHunk) return;
      var cls = 'cdiff-line';
      if (line.startsWith('+')) cls += ' cdiff-add';
      else if (line.startsWith('-')) cls += ' cdiff-del';
      else cls += ' cdiff-ctx';
      lineNodes.push(React.createElement('div', { key: li, className: cls }, line || '\u00a0'));
    });

    return React.createElement(
      'div',
      { key: si, className: 'cdiff-file-segment' },
      // File header bar
      React.createElement(
        'div',
        {
          className: 'cdiff-file-bar',
          onClick: function () {
            setCollapsed(function (prev) {
              var next = Object.assign({}, prev);
              next[si] = !prev[si];
              return next;
            });
          }
        },
        React.createElement('i', {
          className: 'fas ' + (isCollapsed ? 'fa-chevron-right' : 'fa-chevron-down') + ' cdiff-chevron'
        }),
        React.createElement('i', { className: 'fas fa-file-code cdiff-file-icon' }),
        React.createElement('span', { className: 'cdiff-file-name' }, fileName),
        fileDir ? React.createElement('span', { className: 'cdiff-file-dir' }, fileDir) : null
      ),
      !isCollapsed && React.createElement(
        'div',
        { className: 'cdiff-file-body' },
        lineNodes
      )
    );
  }

  return React.createElement(
    'div',
    { className: 'combined-diff-viewer' },
    // Toolbar
    React.createElement(
      'div',
      { className: 'combined-diff-toolbar' },
      React.createElement('i', { className: 'fas fa-exchange-alt', style: { color: '#569cd6', marginRight: 8 } }),
      React.createElement('span', { className: 'combined-diff-label' }, label || 'All Changes'),
      React.createElement('span', { className: 'combined-diff-file-count' }, segments.length + ' file' + (segments.length === 1 ? '' : 's'))
    ),
    // Body
    React.createElement(
      'div',
      { className: 'combined-diff-body', ref: containerRef },
      segments.map(function (seg, si) { return renderSegment(seg, si); })
    )
  );
};

window.CombinedDiffViewer = CombinedDiffViewer;
