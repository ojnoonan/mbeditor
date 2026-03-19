'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var IMAGE_EXTENSIONS = ['png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp', 'bmp', 'avif'];

var EditorPanel = function EditorPanel(_ref) {
  var tab = _ref.tab;
  var paneId = _ref.paneId;
  var onContentChange = _ref.onContentChange;
  var markers = _ref.markers;

  var editorRef = useRef(null);
  var monacoRef = useRef(null);

  var _useState = useState('');

  var _useState2 = _slicedToArray(_useState, 2);

  var markup = _useState2[0];
  var setMarkup = _useState2[1];

  var findTabByPath = function findTabByPath(path) {
    if (!path) return null;
    var state = EditorStore.getState();
    for (var i = 0; i < state.panes.length; i += 1) {
      var pane = state.panes[i];
      var match = pane.tabs.find(function (t) {
        return t.path === path;
      });
      if (match) return match;
    }
    return null;
  };

  useEffect(function () {
    if (tab.isPreview) return;
    if (!editorRef.current || !window.monaco) return;

    if (window.MbeditorEditorPlugins && window.MbeditorEditorPlugins.registerGlobalExtensions) {
      window.MbeditorEditorPlugins.registerGlobalExtensions(window.monaco);
    }

    var parts = tab.path.split('.');
    var extension = parts.length > 1 ? parts.pop().toLowerCase() : '';
    var language = 'plaintext';
    switch (extension) {
      case 'rb':case 'ruby':case 'gemspec':case 'rakefile':
        language = 'ruby';break;
      case 'js':case 'jsx':
        language = 'javascript';break;
      case 'ts':case 'tsx':
        language = 'typescript';break;
      case 'css':case 'scss':case 'sass':
        language = 'css';break;
      case 'html':case 'erb':
        language = 'html';break;
      case 'json':
        language = 'json';break;
      case 'yaml':case 'yml':
        language = 'yaml';break;
      case 'md':case 'markdown':
        language = 'markdown';break;
      case 'sh':case 'bash':case 'zsh':
        language = 'shell';break;
      case 'png':case 'jpg':case 'jpeg':case 'gif':case 'svg':case 'ico':case 'webp':case 'bmp':case 'avif':
        language = 'image';break;
    }

    if (language === 'image') return;

    var editor = window.monaco.editor.create(editorRef.current, {
      value: tab.content,
      language: language,
      theme: 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      renderLineHighlight: 'none',
      bracketPairColorization: { enabled: true },
      fontFamily: "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
      fontSize: 13,
      tabSize: 4,
      insertSpaces: true,
      wordWrap: 'on',
      linkedEditing: true, // Enables Auto-Rename Tag natively!
      fixedOverflowWidgets: true,
      hover: { above: false },
      autoClosingBrackets: 'always',
      autoClosingQuotes: 'always',
      autoIndent: 'full',
      formatOnPaste: true,
      formatOnType: true
    });

    if (tab.viewState) {
      editor.restoreViewState(tab.viewState);
    }

    monacoRef.current = editor;
    window.__mbeditorActiveEditor = editor;

    if (window.CollabService) {
      window.CollabService.join(tab.path, editor);
    }

    var modelObj = editor.getModel();

    var editorPluginDisposable = null;
    if (window.MbeditorEditorPlugins && window.MbeditorEditorPlugins.attachEditorFeatures) {
      editorPluginDisposable = window.MbeditorEditorPlugins.attachEditorFeatures(editor, language);
    }

    // Change listener
    var contentDisposable = modelObj.onDidChangeContent(function (e) {
      var val = editor.getValue();
      var currentContent = monacoRef.current._latestContent || '';

      // Normalize before comparing to prevent false positive dirty edits
      var vNorm = val.replace(/\r\n/g, '\n');
      var cNorm = currentContent.replace(/\r\n/g, '\n');
      if (vNorm !== cNorm) {
        onContentChange(val);
      }
    });

    return function () {
      TabManager.saveTabViewState(tab.id, editor.saveViewState());
      if (window.__mbeditorActiveEditor === editor) {
        window.__mbeditorActiveEditor = null;
      }
      if (window.CollabService) {
        window.CollabService.leave(tab.path);
      }
      if (editorPluginDisposable) editorPluginDisposable.dispose();
      contentDisposable.dispose();
      editor.dispose();
    };
  }, [tab.id, tab.isPreview]); // re-run ONLY on tab switch, not on content change (Monaco handles its own content state)

  // Listen for external content changes (e.g. after Format/Save/Load)
  useEffect(function () {
    var editor = monacoRef.current;
    if (editor) editor._latestContent = tab.content; // update ref for closure

    if (editor && editor.getValue() !== tab.content) {
      if (typeof tab.content !== 'string') return;
      // Normalize before comparing to prevent false positive dirty edits
      var vNorm = editor.getValue().replace(/\r\n/g, '\n');
      var cNorm = tab.content.replace(/\r\n/g, '\n');
      if (vNorm === cNorm) return;

      var model = editor.getModel();
      if (model) {
        if (!vNorm) {
          // If the editor is currently completely empty, treat it as an initial load.
          // setValue clears the undo stack which is correct for initial load.
          editor.setValue(tab.content);
        } else {
          // Keep undo stack for formats or replaces by using executeEdits
          editor.pushUndoStop();
          editor.executeEdits("external", [{
            range: model.getFullModelRange(),
            text: tab.content
          }]);
          editor.pushUndoStop();
        }
      }
    }
  }, [tab.content]);

  // Jump to line if specified
  useEffect(function () {
    if (tab.gotoLine && monacoRef.current) {
      (function () {
        var editor = monacoRef.current;
        setTimeout(function () {
          editor.revealLineInCenter(tab.gotoLine);
          editor.setPosition({ lineNumber: tab.gotoLine, column: 1 });
          editor.focus();

          TabManager.saveTabViewState(tab.id, editor.saveViewState());
          TabManager.clearGotoLine(paneId, tab.path);
        }, 50);
      })();
    }
  }, [tab.gotoLine, tab.content]); // need tab.content in dep array so if it loads asynchronously, the jump happens AFTER content loads

  // Apply RuboCop markers
  useEffect(function () {
    if (monacoRef.current && window.monaco) {
      var model = monacoRef.current.getModel();
      if (model) {
        var monacoMarkers = markers.map(function (m) {
          return {
            severity: m.severity === 'error' ? window.monaco.MarkerSeverity.Error : window.monaco.MarkerSeverity.Warning,
            message: m.message,
            startLineNumber: m.startLine,
            startColumn: m.startCol,
            endLineNumber: m.endLine,
            endColumn: m.endCol
          };
        });
        window.monaco.editor.setModelMarkers(model, 'rubocop', monacoMarkers);
      }
    }
  }, [markers, tab.id]);

  var sourceTab = tab.isPreview ? findTabByPath(tab.previewFor) : null;
  var markdownContent = tab.isPreview ? sourceTab && sourceTab.content || tab.content || '' : tab.content || '';

  var sourcePath = tab.isPreview ? tab.previewFor || tab.path : tab.path;
  var parts = sourcePath.split('.');
  var ext = parts.length > 1 ? parts.pop().toLowerCase() : '';
  var isImage = tab.isImage || IMAGE_EXTENSIONS.includes(ext);
  var isMarkdown = ['md', 'markdown'].includes(ext);

  useEffect(function () {
    if (isMarkdown && window.marked) {
      (function () {
        var renderer = new window.marked.Renderer();
        var escapeHtml = function escapeHtml(str) {
          return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        };
        renderer.html = function (token) {
          return '<pre>' + escapeHtml(typeof token === 'object' ? token.text : token) + '</pre>';
        };
        setMarkup(window.marked.parse(markdownContent, { renderer: renderer }));
      })();
    }
  }, [markdownContent, isMarkdown]);

  if (isImage) {
    var basePath = (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
    return React.createElement(
      'div',
      { className: 'monaco-container', style: { display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#1e1e1e' } },
      React.createElement('img', { src: basePath + '/raw?path=' + encodeURIComponent(tab.path), style: { maxWidth: '90%', maxHeight: '90%', objectFit: 'contain' }, alt: tab.name })
    );
  }

  if (tab.isPreview && isMarkdown) {
    return React.createElement('div', { className: 'markdown-preview markdown-preview-full', dangerouslySetInnerHTML: { __html: markup } });
  }

  return React.createElement('div', { ref: editorRef, className: 'monaco-container' });
};

window.EditorPanel = EditorPanel;