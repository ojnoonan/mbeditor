'use strict';

var DiffViewer = function DiffViewer(_ref) {
  var path = _ref.path;
  var original = _ref.original;
  var modified = _ref.modified;
  var isDark = _ref.isDark;
  var onClose = _ref.onClose;
  var editorPrefs = _ref.editorPrefs || {};
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
      fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', 'Menlo', 'Consolas', monospace",
      fontSize: editorPrefs.fontSize || 13,
      wordWrap: editorPrefs.wordWrap || 'off'
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

  // Update font/wrap options live when editorPrefs changes, without recreating the editor
  React.useEffect(function () {
    if (!editorRef.current) return;
    editorRef.current.updateOptions({
      fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', 'Menlo', 'Consolas', monospace",
      fontSize: editorPrefs.fontSize || 13,
      wordWrap: editorPrefs.wordWrap || 'off'
    });
  }, [editorPrefs]);

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
    // Compound extensions — check before single-extension lookup
    if (/\.js\.erb$/.test(fileName)) return 'js-erb';
    if (/\.ts\.erb$/.test(fileName)) return 'typescript';
    if (/\.html\.erb$/.test(fileName)) return 'erb';
    if (/\.html\.haml$/.test(fileName)) return 'haml';
    if (/\.js\.haml$/.test(fileName)) return 'javascript';
    if (/\.css\.erb$/.test(fileName)) return 'css';
    var ext = fileName.split('.').pop();
    var map = {
      'rb': 'ruby', 'gemspec': 'ruby',
      'js': 'javascript', 'jsx': 'javascript',
      'ts': 'typescript', 'tsx': 'typescript',
      'json': 'json', 'yml': 'yaml', 'yaml': 'yaml',
      'css': 'css', 'scss': 'css', 'sass': 'css',
      'html': 'html', 'erb': 'erb', 'haml': 'haml',
      'xml': 'xml', 'md': 'markdown', 'markdown': 'markdown',
      'sh': 'shell', 'bash': 'shell', 'zsh': 'shell'
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
