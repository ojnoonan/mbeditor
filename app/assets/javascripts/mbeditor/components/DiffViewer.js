'use strict';

var DiffViewer = function DiffViewer(_ref) {
  var path = _ref.path;
  var original = _ref.original;
  var modified = _ref.modified;
  var isDark = _ref.isDark;
  var onClose = _ref.onClose;
  // If path is a diff:// URI (diff://baseSha..headSha/actual/file.rb), extract
  // just the file path portion for display so the title bar shows a clean name.
  var _rawDisplayPath = _ref.displayPath || path;
  var displayPath = _rawDisplayPath;
  if (!_ref.displayPath && _rawDisplayPath && _rawDisplayPath.indexOf('diff://') === 0) {
    var _rest = _rawDisplayPath.slice(7); // strip 'diff://'
    var _sep = _rest.indexOf('/');
    if (_sep !== -1) displayPath = _rest.slice(_sep + 1);
  }

  var containerRef = React.useRef(null);
  var editorRef = React.useRef(null);
  var currentChangeRef = React.useRef(-1);

  React.useEffect(function () {
    if (!window.monaco || !containerRef.current) return;

    var modelOriginal = window.monaco.editor.createModel(original, getLanguageForPath(displayPath));
    var modelModified = window.monaco.editor.createModel(modified, getLanguageForPath(displayPath));

    var diffEditor = window.monaco.editor.createDiffEditor(containerRef.current, {
      theme: isDark ? 'vs-dark' : 'vs',
      readOnly: true,
      automaticLayout: true,
      originalEditable: false,
      renderSideBySide: true,
      useInlineViewWhenSpaceIsLimited: false,
      ignoreTrimWhitespace: false,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Menlo', 'Consolas', monospace",
      fontSize: 13
    });

    diffEditor.setModel({
      original: modelOriginal,
      modified: modelModified
    });

    editorRef.current = diffEditor;
    currentChangeRef.current = -1;

    diffEditor.onDidUpdateDiff(function () {
      currentChangeRef.current = -1;
    });

    return function () {
      if (editorRef.current) {
        editorRef.current.dispose();
        editorRef.current = null;
      }
      modelOriginal.dispose();
      modelModified.dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [original, modified, displayPath, isDark]);

  var handleNextDiff = function handleNextDiff() {
    if (!editorRef.current) return;
    var changes = editorRef.current.getLineChanges() || [];
    if (!changes.length) return;
    currentChangeRef.current = (currentChangeRef.current + 1) % changes.length;
    var change = changes[currentChangeRef.current];
    editorRef.current.getModifiedEditor().revealLineInCenter(change.modifiedStartLineNumber);
  };

  var handlePrevDiff = function handlePrevDiff() {
    if (!editorRef.current) return;
    var changes = editorRef.current.getLineChanges() || [];
    if (!changes.length) return;
    currentChangeRef.current = (currentChangeRef.current - 1 + changes.length) % changes.length;
    var change = changes[currentChangeRef.current];
    editorRef.current.getModifiedEditor().revealLineInCenter(change.modifiedStartLineNumber);
  };

  function getLanguageForPath(filePath) {
    if (!filePath) return 'plaintext';
    var fileName = filePath.split('/').pop().toLowerCase();
    if (fileName === 'gemfile' || fileName === 'gemfile.lock' || fileName === 'rakefile') return 'ruby';
    var ext = filePath.split('.').pop().toLowerCase();
    var map = {
      'rb': 'ruby', 'js': 'javascript', 'jsx': 'javascript',
      'ts': 'typescript', 'tsx': 'typescript',
      'json': 'json', 'yml': 'yaml', 'yaml': 'yaml',
      'css': 'css', 'scss': 'scss', 'html': 'html',
      'xml': 'xml', 'md': 'markdown', 'sh': 'shell'
    };
    return map[ext] || 'plaintext';
  }

  var pathParts = (displayPath || '').split('/');
  var fileName = pathParts.pop() || displayPath || '';
  var fileDir = pathParts.join('/');

  return React.createElement(
    'div',
    { className: 'ide-diff-viewer' },
    React.createElement(
      'div',
      { className: 'ide-diff-toolbar' },
      React.createElement(
        'div',
        { className: 'ide-diff-title' },
        React.createElement('i', { className: 'fas fa-file-contract' }),
          React.createElement(
            'div',
            { className: 'ide-diff-title-info', title: displayPath },
            React.createElement('div', { className: 'ide-diff-title-name' }, fileName),
            fileDir ? React.createElement('div', { className: 'ide-diff-title-dir' }, fileDir) : null
          )
      ),
      React.createElement(
        'div',
        { className: 'ide-diff-actions' },
        onClose && React.createElement(
          'button',
          { className: 'ide-diff-btn', onClick: onClose, title: 'Close diff (or click × on the tab)' },
          React.createElement('i', { className: 'fas fa-times' })
        ),
        React.createElement(
          'button',
          { className: 'ide-diff-btn', onClick: handlePrevDiff, title: 'Previous Change' },
          React.createElement('i', { className: 'fas fa-arrow-up' })
        ),
        React.createElement(
          'button',
          { className: 'ide-diff-btn', onClick: handleNextDiff, title: 'Next Change' },
          React.createElement('i', { className: 'fas fa-arrow-down' })
        )
      )
    ),
    React.createElement('div', { className: 'ide-diff-editor-container', ref: containerRef })
  );
};

window.DiffViewer = DiffViewer;
