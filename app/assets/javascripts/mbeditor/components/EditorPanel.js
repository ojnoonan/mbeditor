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
  var gitAvailable = _ref.gitAvailable === true;
  var testAvailable = _ref.testAvailable === true;
  var onFormat = _ref.onFormat;
  var onRunTest = _ref.onRunTest;
  var onShowHistory = _ref.onShowHistory;
  var testResult = _ref.testResult;
  var testPanelFile = _ref.testPanelFile;
  var testLoading = _ref.testLoading;
  var testInlineVisible = _ref.testInlineVisible;
  var editorPrefs = _ref.editorPrefs || {};

  var editorRef = useRef(null);
  var monacoRef = useRef(null);
  var latestContentRef = useRef('');

  var _useState = useState('');
  var _useState2 = _slicedToArray(_useState, 2);
  var markup = _useState2[0];
  var setMarkup = _useState2[1];

  var _useState3 = useState(false);
  var _useState4 = _slicedToArray(_useState3, 2);
  var isBlameVisible = _useState4[0];
  var setIsBlameVisible = _useState4[1];

  var _useState5 = useState(null);
  var _useState6 = _slicedToArray(_useState5, 2);
  var blameData = _useState6[0];
  var setBlameData = _useState6[1];

  var _useState7 = useState(false);
  var _useState8 = _slicedToArray(_useState7, 2);
  var isBlameLoading = _useState8[0];
  var setIsBlameLoading = _useState8[1];

  var blameDecorationsRef = useRef([]);
  var blameZoneIdsRef = useRef([]);
  var testDecorationIdsRef = useRef([]);
  var testZoneIdsRef = useRef([]);

  var _useState9 = useState(false);
  var _useState10 = _slicedToArray(_useState9, 2);
  var editorReady = _useState10[0];
  var setEditorReady = _useState10[1];

  var onFormatRef = useRef(onFormat);
  onFormatRef.current = onFormat;

  var clearTestZones = function clearTestZones(editor) {
    if (!editor) return;
    if (testZoneIdsRef.current.length === 0) return;
    editor.changeViewZones(function(accessor) {
      testZoneIdsRef.current.forEach(function(zoneId) {
        accessor.removeZone(zoneId);
      });
    });
    testZoneIdsRef.current = [];
  };

  var clearBlameZones = function clearBlameZones(editor) {
    if (!editor) return;
    if (blameZoneIdsRef.current.length === 0) return;

    editor.changeViewZones(function(accessor) {
      blameZoneIdsRef.current.forEach(function(zoneId) {
        accessor.removeZone(zoneId);
      });
    });
    blameZoneIdsRef.current = [];
  };

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

    var fileName = tab.path.split('/').pop() || '';
    var parts = fileName.split('.');
    var extension = parts.length > 1 ? parts.pop().toLowerCase() : '';
    var language = 'plaintext';
    switch (fileName.toLowerCase()) {
      case 'gemfile':
      case 'gemfile.lock':
      case 'rakefile':
        language = 'ruby';break;
      default:
        switch (extension) {
      case 'rb':case 'ruby':case 'gemspec':
          language = 'ruby';break;
      case 'js':case 'jsx':
        language = 'javascript';break;
      case 'ts':case 'tsx':
        language = 'typescript';break;
      case 'css':case 'scss':case 'sass':
        language = 'css';break;
      case 'html':case 'erb':
        language = 'html';break;
      case 'haml':
        language = 'plaintext';break;
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
    }

    if (language === 'image') return;

    var editor = window.monaco.editor.create(editorRef.current, {
      value: tab.content,
      language: language,
      theme: editorPrefs.theme || 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      renderLineHighlight: 'none',
      bracketPairColorization: { enabled: true },
      fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
      fontSize: editorPrefs.fontSize || 13,
      tabSize: editorPrefs.tabSize || 4,
      insertSpaces: typeof editorPrefs.insertSpaces === 'boolean' ? editorPrefs.insertSpaces : false,
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
    setEditorReady(true);

    // Stash the workspace-relative path on the model so code-action providers
    // can identify which file they are operating on without needing React state.
    var modelObj = editor.getModel();
    if (modelObj) modelObj._mbeditorPath = tab.path;

    var formatActionDisposable = editor.addAction({
      id: 'mbeditor.formatDocument',
      label: 'Format Document',
      contextMenuGroupId: '1_modification',
      contextMenuOrder: 1.5,
      run: function() {
        if (onFormatRef.current) onFormatRef.current();
      }
    });

    var editorPluginDisposable = null;
    if (window.MbeditorEditorPlugins && window.MbeditorEditorPlugins.attachEditorFeatures) {
      editorPluginDisposable = window.MbeditorEditorPlugins.attachEditorFeatures(editor, language);
    }

    // Change listener
    var contentDisposable = modelObj.onDidChangeContent(function (e) {
      var val = editor.getValue();
      var currentContent = latestContentRef.current;

      // Normalize before comparing to prevent false positive dirty edits
      var vNorm = val.replace(/\r\n/g, '\n');
      var cNorm = currentContent.replace(/\r\n/g, '\n');
      if (vNorm !== cNorm) {
        onContentChange(val);
      }
    });

    return function () {
      blameDecorationsRef.current = editor.deltaDecorations(blameDecorationsRef.current, []);
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, []);
      clearBlameZones(editor);
      clearTestZones(editor);
      TabManager.saveTabViewState(tab.id, editor.saveViewState());
      if (window.__mbeditorActiveEditor === editor) {
        window.__mbeditorActiveEditor = null;
      }
      if (editorPluginDisposable) editorPluginDisposable.dispose();
      formatActionDisposable.dispose();
      contentDisposable.dispose();
      editor.dispose();
    };
  }, [tab.id, tab.isPreview]); // re-run ONLY on tab switch, not on content change (Monaco handles its own content state)

  // Listen for external content changes (e.g. after Format/Save/Load)
  useEffect(function () {
    var editor = monacoRef.current;
    if (editor) latestContentRef.current = tab.content; // keep ref in sync for closure

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

  // Apply editorPrefs changes to a running editor without remounting
  useEffect(function () {
    if (!window.monaco) return;
    var theme = editorPrefs.theme || 'vs-dark';
    window.monaco.editor.setTheme(theme);
    if (monacoRef.current) {
      monacoRef.current.updateOptions({
        fontSize: editorPrefs.fontSize || 13,
        fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
        tabSize: editorPrefs.tabSize || 4,
        insertSpaces: typeof editorPrefs.insertSpaces === 'boolean' ? editorPrefs.insertSpaces : false
      });
    }
  }, [editorPrefs]);

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
          var sev = m.severity === 'error'
            ? window.monaco.MarkerSeverity.Error
            : window.monaco.MarkerSeverity.Warning;
          return {
            severity: sev,
            source: 'rubocop',
            code: m.copName || '',
            message: m.message,
            startLineNumber: m.startLine,
            startColumn: m.startCol,
            endLineNumber: m.endLine,
            endColumn: m.endCol
          };
        });
        window.monaco.editor.setModelMarkers(model, 'rubocop', monacoMarkers);
        // Track which cops are autocorrectable so the quick-fix provider can
        // skip lightbulbs for cops that can never be machine-fixed.
        model._mbeditorCorrectableCops = new Set(
          markers.filter(function(m) { return m.correctable && m.copName; }).map(function(m) { return m.copName; })
        );
      }
    }
  }, [markers, tab.id]);

  // Reset blame + test decorations when file path changes
  useEffect(function () {
    setBlameData(null);
    setIsBlameLoading(false);

    if (monacoRef.current && monacoRef.current.getModel()) {
      clearBlameZones(monacoRef.current);
      clearTestZones(monacoRef.current);
      blameDecorationsRef.current = monacoRef.current.deltaDecorations(blameDecorationsRef.current, []);
      testDecorationIdsRef.current = monacoRef.current.deltaDecorations(testDecorationIdsRef.current, []);
    }
  }, [tab.path]);

  // Handle Blame data fetching
  useEffect(function () {
    if (!isBlameVisible) {
      if (monacoRef.current && monacoRef.current.getModel()) {
        clearBlameZones(monacoRef.current);
        blameDecorationsRef.current = monacoRef.current.deltaDecorations(blameDecorationsRef.current, []);
      }
      return;
    }
    
    if (!blameData && !isBlameLoading) {
      setIsBlameLoading(true);
      GitService.fetchBlame(tab.path).then(function(data) {
        var lines = data && Array.isArray(data.lines) ? data.lines : [];
        setBlameData(lines);
        if (lines.length === 0) {
          EditorStore.setStatus('No blame data available for this file', 'warning');
        } else {
          EditorStore.setStatus('Loaded blame for ' + lines.length + ' lines', 'info');
        }
        setIsBlameLoading(false);
      }).catch(function(err) {
        var status = err.response && err.response.status;
        var msg = status === 404
          ? "File is not tracked by git"
          : "Failed to load blame: " + ((err.response && err.response.data && err.response.data.error) || err.message);
        EditorStore.setStatus(msg, "error");
        setBlameData([]);
        setIsBlameLoading(false);
      });
    }
  }, [isBlameVisible, tab.path, blameData, isBlameLoading]);

  // Render Blame block headers (author + summary) above contiguous commit regions.
  useEffect(function () {
    if (!monacoRef.current || !window.monaco || !isBlameVisible || !blameData) return;

    var editor = monacoRef.current;
    var model = editor.getModel();
    var lineCount = model ? model.getLineCount() : 0;

    try {
      // Clear previous render before rebuilding.
      clearBlameZones(editor);
      blameDecorationsRef.current = editor.deltaDecorations(blameDecorationsRef.current, []);

      var normalized = blameData.map(function(lineData) {
        var ln = Number(lineData && lineData.line);
        if (!model || !ln || ln < 1 || ln > lineCount) return null;

        var sha = lineData && lineData.sha || '';
        var author = lineData && lineData.author || 'Unknown';
        var summary = lineData && lineData.summary || 'No commit message';
        var isUncommitted = sha.substring(0, 8) === '00000000';

        return {
          line: ln,
          sha: sha,
          author: isUncommitted ? 'Not Committed' : author,
          summary: summary,
          isUncommitted: isUncommitted
        };
      }).filter(Boolean);

      normalized.sort(function(a, b) { return a.line - b.line; });

      var blocks = [];
      normalized.forEach(function(item) {
        var current = blocks.length > 0 ? blocks[blocks.length - 1] : null;
        if (!current || current.sha !== item.sha || item.line !== current.endLine + 1) {
          blocks.push({
            sha: item.sha,
            author: item.author,
            summary: item.summary,
            isUncommitted: item.isUncommitted,
            startLine: item.line,
            endLine: item.line
          });
          return;
        }
        current.endLine = item.line;
      });

      var zoneIds = [];
      editor.changeViewZones(function(accessor) {
        blocks.forEach(function(block, idx) {
          var header = document.createElement('div');
          header.className = block.isUncommitted
            ? 'ide-blame-block-header ide-blame-block-header-uncommitted'
            : 'ide-blame-block-header';
          header.textContent = block.author + ' - ' + block.summary;

          var zoneId = accessor.addZone({
            afterLineNumber: block.startLine > 1 ? block.startLine - 1 : 0,
            heightInLines: 1,
            domNode: header,
            suppressMouseDown: true
          });
          zoneIds.push(zoneId);
        });
      });
      blameZoneIdsRef.current = zoneIds;
    } catch (err) {
      var message = err && err.message ? err.message : 'Unknown decoration error';
      EditorStore.setStatus('Failed to render blame annotations: ' + message, 'error');
      clearBlameZones(editor);
      blameDecorationsRef.current = editor.deltaDecorations(blameDecorationsRef.current, []);
    }

  // Include tab.content so blame re-renders once async file contents finish loading.
  }, [blameData, isBlameVisible, tab.id, tab.content]);

  // Check whether the current tab is the source file for the test that was run.
  // e.g. testPanelFile = "test/controllers/theme_controller_test.rb"
  //      tab.path      = "app/controllers/theme_controller.rb"
  var isSourceForTest = function(tabPath, testFilePath) {
    if (!tabPath || !testFilePath) return false;
    var norm = function(p) { return p.replace(/^\/+/, ''); };
    // Direct match (viewing the test file itself)
    if (norm(tabPath) === norm(testFilePath)) return true;
    // Derive the expected source path from the test file path
    var derived = norm(testFilePath)
      .replace(/^test\//, '').replace(/^spec\//, '')
      .replace(/_test\.rb$/, '.rb').replace(/_spec\.rb$/, '.rb');
    var src = norm(tabPath).replace(/^app\//, '');
    return src === derived;
  };

  // Map a test method name to the best-matching line in the source file.
  // Extracts keywords from the test name and scores each source line.
  var mapTestToSourceLine = function(testName, sourceContent) {
    var name = (testName || '').replace(/^test_/, '').replace(/^(it |should )/, '');
    var tokens = name.split('_').filter(function(t) { return t.length > 1; });
    if (tokens.length === 0) return 1;

    var lines = sourceContent.split('\n');
    var bestLine = 1;
    var bestScore = 0;

    lines.forEach(function(line, idx) {
      var lineNum = idx + 1;
      var lower = line.toLowerCase();
      var score = 0;
      tokens.forEach(function(tok) {
        if (lower.indexOf(tok.toLowerCase()) !== -1) score++;
      });
      // Prefer def/attr/constant lines
      if (score > 0 && (/\bdef\b/.test(lower) || /\battr_/.test(lower) || /^  [A-Z]/.test(line))) {
        score += 0.5;
      }
      if (score > bestScore) { bestScore = score; bestLine = lineNum; }
    });

    return bestLine;
  };

  // Render test result annotations above source lines (same pattern as blame zones).
  useEffect(function () {
    if (!monacoRef.current || !window.monaco) return;

    var editor = monacoRef.current;
    var model = editor.getModel();
    var lineCount = model ? model.getLineCount() : 0;

    var showHere = testPanelFile && tab.path && isSourceForTest(tab.path, testPanelFile);

    if (!testResult || !testInlineVisible || !showHere) {
      clearTestZones(editor);
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, []);
      return;
    }

    try {
      clearTestZones(editor);
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, []);

      var normPath = function(p) { return p ? p.replace(/^\/+/, '') : ''; };
      var viewingTestFile = normPath(tab.path) === normPath(testPanelFile);

      var tests = testResult.tests || [];
      var testsWithStatus = tests.filter(function (t) {
        return t.status === 'pass' || t.status === 'fail' || t.status === 'error';
      });

      if (testsWithStatus.length === 0) return;

      // Determine line number for each test
      var sourceContent = tab.content || '';
      var mapped = testsWithStatus.map(function(t) {
        var line;
        if (viewingTestFile && t.line && t.line >= 1 && t.line <= lineCount) {
          line = t.line;
        } else {
          line = mapTestToSourceLine(t.name, sourceContent);
        }
        return { name: t.name, status: t.status, message: t.message, line: line };
      });

      // Sort by line so zones appear in order
      mapped.sort(function(a, b) { return a.line - b.line; });

      var zoneIds = [];
      var decorations = [];

      editor.changeViewZones(function(accessor) {
        mapped.forEach(function(t) {
          if (t.line < 1 || t.line > lineCount) return;

          var isPassing = t.status === 'pass';
          var icon = isPassing ? '\u2713' : '\u2717';
          var label = icon + '  ' + (t.name || 'Test');
          if (!isPassing && t.message) {
            label += ' \u2014 ' + t.message.split('\n')[0];
          }

          var header = document.createElement('div');
          header.className = isPassing
            ? 'ide-test-zone-header ide-test-zone-pass'
            : 'ide-test-zone-header ide-test-zone-fail';
          header.textContent = label;

          var zoneId = accessor.addZone({
            afterLineNumber: t.line > 1 ? t.line - 1 : 0,
            heightInLines: 1,
            domNode: header,
            suppressMouseDown: true
          });
          zoneIds.push(zoneId);

          decorations.push({
            range: new window.monaco.Range(t.line, 1, t.line, 1),
            options: {
              isWholeLine: true,
              className: isPassing ? 'ide-test-line-pass' : 'ide-test-line-fail',
              stickiness: 1
            }
          });
        });
      });

      testZoneIdsRef.current = zoneIds;
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, decorations);
    } catch (err) {
      clearTestZones(editor);
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, []);
    }

  // Include tab.content so zones re-render once async file content loads (same as blame).
  }, [testResult, testInlineVisible, testPanelFile, tab.id, tab.path, tab.content]);

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

  if (tab.isDiff) {
    var isDiffDark = (editorPrefs.theme || 'vs-dark') !== 'vs' && (editorPrefs.theme || 'vs-dark') !== 'hc-light';
    return React.createElement(window.DiffViewer || DiffViewer, {
      path: tab.repoPath || tab.path,
      original: tab.diffOriginal || "",
      modified: tab.diffModified || "",
      isDark: isDiffDark
    });
  }

  if (tab.isCombinedDiff) {
    return React.createElement(window.CombinedDiffViewer, {
      diffText: tab.combinedDiffText || '',
      label: tab.combinedDiffLabel || 'All Changes',
      isLoading: !tab.combinedDiffText && !tab.combinedDiffLoaded
    });
  }

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

  // Always render the same wrapper structure so the editorRef div is never
  // unmounted when gitAvailable changes (e.g. loaded async after workspace
  // call returns). The toolbar is conditionally included inside the wrapper.
  return React.createElement(
    'div',
    { className: 'ide-editor-wrapper', style: { display: 'flex', flexDirection: 'column', height: '100%' } },
    (gitAvailable || testAvailable) && React.createElement(
      'div',
      { className: 'ide-editor-toolbar', style: { display: 'flex', justifyContent: 'flex-end', padding: '4px 8px', background: '#252526', borderBottom: '1px solid #3c3c3c', gap: '4px' } },
      gitAvailable && tab.path && React.createElement(
        'button',
        {
          className: 'ide-icon-btn',
          onClick: function() { if (onShowHistory) onShowHistory(tab.path); },
          title: 'File History',
          style: { fontSize: '12px', padding: '2px 6px', opacity: 0.6, background: 'transparent', border: 'none', color: '#ccc', cursor: 'pointer', borderRadius: '3px' }
        },
        React.createElement('i', { className: 'fas fa-history', style: { marginRight: '6px' } }),
        'History'
      ),
      gitAvailable && React.createElement(
        'button',
        {
          className: 'ide-icon-btn ' + (isBlameVisible ? 'active' : ''),
          onClick: function() {
            setIsBlameVisible(function(prev) { return !prev; });
          },
          title: 'Toggle Git Blame',
          style: { fontSize: '12px', padding: '2px 6px', opacity: isBlameVisible ? 1 : 0.6, background: isBlameVisible ? 'rgba(255,255,255,0.1)' : 'transparent', border: 'none', color: '#ccc', cursor: 'pointer', borderRadius: '3px' }
        },
        React.createElement('i', { className: 'fas fa-shoe-prints', style: { marginRight: '6px' } }),
        isBlameLoading ? 'Loading...' : 'Blame'
      ),
      testAvailable && tab.path && tab.path.endsWith('.rb') && React.createElement(
        'button',
        {
          className: 'ide-icon-btn',
          onClick: function() { if (onRunTest) onRunTest(); },
          disabled: testLoading,
          title: 'Run Tests',
          style: { fontSize: '12px', padding: '2px 6px', opacity: testLoading ? 1 : 0.6, background: 'transparent', border: 'none', color: '#ccc', cursor: testLoading ? 'wait' : 'pointer', borderRadius: '3px' }
        },
        React.createElement('i', { className: testLoading ? 'fas fa-spinner fa-spin' : 'fas fa-flask', style: { marginRight: '6px' } }),
        testLoading ? 'Running...' : 'Test'
      )
    ),
    React.createElement('div', { ref: editorRef, className: 'monaco-container', style: { flex: 1, minHeight: 0 } })
  );
};

window.EditorPanel = EditorPanel;