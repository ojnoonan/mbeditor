'use strict';

var _slicedToArray = (function () { function sliceIterator(arr, i) { var _arr = []; var _n = true; var _d = false; var _e = undefined; try { for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) { _arr.push(_s.value); if (i && _arr.length === i) break; } } catch (err) { _d = true; _e = err; } finally { try { if (!_n && _i['return']) _i['return'](); } finally { if (_d) throw _e; } } return _arr; } return function (arr, i) { if (Array.isArray(arr)) { return arr; } else if (Symbol.iterator in Object(arr)) { return sliceIterator(arr, i); } else { throw new TypeError('Invalid attempt to destructure non-iterable instance'); } }; })();

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

var IMAGE_EXTENSIONS = ['png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp', 'bmp', 'avif'];

var _hamlLangRegistered = false;
var _erbLangRegistered = false;
var _jsErbLangRegistered = false;

var EditorPanel = function EditorPanel(_ref) {
  var tab = _ref.tab;
  var paneId = _ref.paneId;
  var onContentChange = _ref.onContentChange;
  var markers = _ref.markers;
  var gitAvailable = _ref.gitAvailable === true;
  var testAvailable = _ref.testAvailable === true;
  var onFormat = _ref.onFormat;
  var onSave = _ref.onSave;
  var onRunTest = _ref.onRunTest;
  var onShowHistory = _ref.onShowHistory;
  var treeData = _ref.treeData || [];
  var testResult = _ref.testResult;
  var testPanelFile = _ref.testPanelFile;
  var testLoading = _ref.testLoading;
  var testInlineVisible = _ref.testInlineVisible;
  var editorPrefs = _ref.editorPrefs || {};
  var monacoReady = _ref.monacoReady !== false; // undefined means Monaco already loaded (legacy callers)

  var editorRef = useRef(null);
  var monacoRef = useRef(null);
  var latestContentRef = useRef('');
  var lastAppliedExternalVersionRef = useRef(-1);
  var aviBaseRef = useRef(0);
  var aviMaxRef = useRef(0);

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

  var _useState11 = useState(false);
  var _useState12 = _slicedToArray(_useState11, 2);
  var methodsOpen = _useState12[0];
  var setMethodsOpen = _useState12[1];

  var _useState13 = useState([]);
  var _useState14 = _slicedToArray(_useState13, 2);
  var methodsList = _useState14[0];
  var setMethodsList = _useState14[1];

  var _useState15 = useState(null);
  var _useState16 = _slicedToArray(_useState15, 2);
  var methodsDropdownPos = _useState16[0];
  var setMethodsDropdownPos = _useState16[1];

  var methodsBtnRef = useRef(null);

  var onFormatRef = useRef(onFormat);
  onFormatRef.current = onFormat;

  var onSaveRef = useRef(onSave);
  onSaveRef.current = onSave;

  var vimStatusRef = useRef(null);
  var vimModeObjRef = useRef(null);

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
    if (!monacoReady || !editorRef.current || !window.monaco) return;

    if (window.MbeditorEditorPlugins && window.MbeditorEditorPlugins.registerGlobalExtensions) {
      window.MbeditorEditorPlugins.registerGlobalExtensions(window.monaco);
    }

    // Register HAML Monarch grammar once
    if (!_hamlLangRegistered) {
      _hamlLangRegistered = true;
      window.monaco.languages.register({ id: 'haml', extensions: ['.haml'], aliases: ['HAML', 'haml'] });
      window.monaco.languages.setMonarchTokensProvider('haml', {
        // Monarch does not support ^ line anchors — use `@sol` state transitions instead.
        // Strategy: tokenize each line character-by-character from the root state,
        // which resets at the start of each line.
        defaultToken: 'text',
        tokenizer: {
          root: [
            // Doctype: !!! or !!!5 etc
            [/!!!.*$/, 'keyword.doctype'],
            // HAML comment: -#
            [/-#.*$/, 'comment'],
            // HTML comment: /
            [/\/.*$/, 'comment'],
            // Leading whitespace — must use \s+ (not \s*) to avoid a zero-width match
            // which Monarch treats as "no progress" and throws a tokenizer error.
            [/^\s+/, 'white'],
            // Ruby output line: = expr
            [/(=)(\s*)/, [{ token: 'keyword.operator' }, { token: '', next: '@rubyLine' }]],
            // Ruby statement line: - stmt (but not -#)
            [/(-)(\s+)/, [{ token: 'keyword.operator' }, { token: '', next: '@rubyLine' }]],
            // Tag: %tag with optional .class/#id/{ attrs }/ text
            [/%[\w:-]+/, { token: 'tag', next: '@afterTag' }],
            // Class shorthand: .foo
            [/\.[\w-]+/, { token: 'type.class', next: '@afterTag' }],
            // ID shorthand: #foo (only at line start region — before any inline text)
            [/#[\w-]+/, { token: 'type.id', next: '@afterTag' }],
            // Inline Ruby interpolation: #{...}
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
            // Strings
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            // Symbol keys in attribute hashes
            [/:\w+/, 'attribute.name'],
            // Numbers
            [/\d+/, 'number'],
            // Rest of line text
            [/[^\s#"'%.\-={}]+/, 'text'],
          ],
          afterTag: [
            // Chained .class
            [/\.[\w-]+/, 'type.class'],
            // Chained #id
            [/#[\w-]+/, 'type.id'],
            // Attribute hash open
            [/\{/, { token: 'delimiter.bracket', next: '@attrHash' }],
            // Attribute paren open (HTML-style)
            [/\(/, { token: 'delimiter.paren', next: '@attrParen' }],
            // Inline = output — switchTo so rubyLine pops back to root, not afterTag
            [/=/, { token: 'keyword.operator', switchTo: '@rubyLine' }],
            // Rest of inline text
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/[^\s{(\\.#="']+/, 'text'],
            [/$/, '', '@pop'],
            [/\s+/, 'white'],
          ],
          attrHash: [
            [/\}/, { token: 'delimiter.bracket', next: '@pop' }],
            [/:\w+/, 'attribute.name'],
            [/\w+:/, 'attribute.name'],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/=>/, 'keyword.operator'],
            [/[,\s]+/, 'white'],
            [/[^}:"',\s=>]+/, 'variable'],
          ],
          attrParen: [
            [/\)/, { token: 'delimiter.paren', next: '@pop' }],
            [/[\w-]+=?/, 'attribute.name'],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\s+/, 'white'],
          ],
          rubyLine: [
            [/$/, '', '@pop'],
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\d+(\.\d+)?/, 'number'],
            [/\b(do|end|if|unless|else|elsif|case|when|then|while|until|for|in|return|yield|def|class|module|nil|true|false|self|super|and|or|not|begin|rescue|ensure|raise)\b/, 'keyword'],
            [/[A-Z][\w]*/, 'type.identifier'],
            [/[\w]+[?!]?/, 'identifier'],
            [/[+\-*\/=<>!&|^~%]+/, 'keyword.operator'],
            [/[,;.()\[\]{}]/, 'delimiter'],
          ],
          rubyInterp: [
            [/\}/, { token: 'delimiter.bracket', next: '@pop' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\d+/, 'number'],
            [/[A-Z][\w]*/, 'type.identifier'],
            [/[\w]+[?!]?/, 'identifier'],
            [/[+\-*\/=<>!&|^~%,.:()\[\]]+/, 'keyword.operator'],
          ],
          dqString: [
            [/[^\\"#]+/, 'string'],
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
            [/\\./, 'string.escape'],
            [/"/, { token: 'string.quote', next: '@pop' }],
          ],
          sqString: [
            [/[^\\']/, 'string'],
            [/\\./, 'string.escape'],
            [/'/, { token: 'string.quote', next: '@pop' }],
          ],
        }
      });
    }

    // Register ERB (html.erb) Monarch grammar once
    if (!_erbLangRegistered) {
      _erbLangRegistered = true;
      window.monaco.languages.register({ id: 'erb', aliases: ['ERB', 'erb', 'HTML+ERB'] });
      window.monaco.languages.setMonarchTokensProvider('erb', {
        defaultToken: 'text',
        tokenizer: {
          root: [
            // ERB comment: <%#
            [/<%#/, { token: 'comment.erb', next: '@erbComment' }],
            // ERB output: <%= or <%==
            [/<%==?/, { token: 'delimiter.erb', next: '@erbCode' }],
            // ERB statement: <%
            [/<%/, { token: 'delimiter.erb', next: '@erbCode' }],
            // HTML tags
            [/(<)([\w-]+)/, [{ token: 'delimiter.html' }, { token: 'tag.html', next: '@htmlTag' }]],
            [/(<\/)([\w-]+)(>)/, [{ token: 'delimiter.html' }, { token: 'tag.html' }, { token: 'delimiter.html' }]],
            [/<!--/, { token: 'comment.html', next: '@htmlComment' }],
            [/<!DOCTYPE[^>]*>/, 'keyword.html'],
            [/&\w+;/, 'string.html.entity'],
            [/[^<&%]+/, 'text'],
          ],
          erbCode: [
            [/-%>|%>/, { token: 'delimiter.erb', next: '@pop' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\d+(\.\d+)?/, 'number'],
            [/\b(do|end|if|unless|else|elsif|case|when|then|while|until|for|in|return|yield|def|class|module|nil|true|false|self|super|and|or|not|begin|rescue|ensure|raise)\b/, 'keyword'],
            [/[A-Z][\w]*/, 'type.identifier'],
            [/[\w]+[?!]?/, 'identifier'],
            [/[+\-*\/=<>!&|^~%]+/, 'keyword.operator'],
            [/[,;.()\[\]{}]/, 'delimiter'],
            [/#[^{].*$/, 'comment'],
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
          ],
          erbComment: [
            [/%>/, { token: 'comment.erb', next: '@pop' }],
            [/./, 'comment'],
          ],
          htmlTag: [
            [/>/, { token: 'delimiter.html', next: '@pop' }],
            [/\/?>/, { token: 'delimiter.html', next: '@pop' }],
            [/<%#/, { token: 'comment.erb', next: '@erbComment' }],
            [/<%==?/, { token: 'delimiter.erb', next: '@erbCode' }],
            [/<%/, { token: 'delimiter.erb', next: '@erbCode' }],
            [/[\w-]+=?/, 'attribute.name'],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\s+/, 'white'],
          ],
          htmlComment: [
            [/-->/, { token: 'comment.html', next: '@pop' }],
            [/./, 'comment'],
          ],
          rubyInterp: [
            [/\}/, { token: 'delimiter.bracket', next: '@pop' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/[\w]+[?!]?/, 'identifier'],
            [/[+\-*\/=<>!&|^~%,.:()\[\]]+/, 'keyword.operator'],
          ],
          dqString: [
            [/[^\\"#]+/, 'string'],
            [/#\{/, { token: 'delimiter.bracket', next: '@rubyInterp' }],
            [/\\./, 'string.escape'],
            [/"/, { token: 'string.quote', next: '@pop' }],
          ],
          sqString: [
            [/[^\\']/, 'string'],
            [/\\./, 'string.escape'],
            [/'/, { token: 'string.quote', next: '@pop' }],
          ],
        }
      });
    }

    // Register JS+ERB Monarch grammar once
    if (!_jsErbLangRegistered) {
      _jsErbLangRegistered = true;
      window.monaco.languages.register({ id: 'js-erb', aliases: ['JS+ERB', 'JavaScript+ERB'] });
      window.monaco.languages.setMonarchTokensProvider('js-erb', {
        defaultToken: 'text',
        tokenizer: {
          root: [
            // ERB comment
            [/<%#/, { token: 'comment.erb', next: '@erbComment' }],
            // ERB output
            [/<%==?/, { token: 'delimiter.erb', next: '@erbCode' }],
            // ERB statement
            [/<%/, { token: 'delimiter.erb', next: '@erbCode' }],
            // JS line comments
            [/\/\/.*$/, 'comment'],
            // JS block comments
            [/\/\*/, { token: 'comment', next: '@jsBlockComment' }],
            // JS strings
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/`/, { token: 'string.quote', next: '@templateString' }],
            // JS numbers
            [/\d+(\.\d+)?([eE][+-]?\d+)?/, 'number'],
            [/0x[0-9a-fA-F]+/, 'number.hex'],
            // JS keywords
            [/\b(var|let|const|function|return|if|else|for|while|do|switch|case|break|continue|new|delete|typeof|instanceof|in|of|this|class|extends|import|export|default|async|await|try|catch|finally|throw|null|undefined|true|false)\b/, 'keyword'],
            // Identifiers
            [/[A-Z][\w]*/, 'type.identifier'],
            [/[\w$]+/, 'identifier'],
            // Operators and punctuation
            [/[+\-*\/=<>!&|^~%?:]+/, 'keyword.operator'],
            [/[{}()\[\],;.]/, 'delimiter'],
            [/\s+/, 'white'],
          ],
          erbCode: [
            [/-%>|%>/, { token: 'delimiter.erb', next: '@pop' }],
            [/"/, { token: 'string.quote', next: '@dqString' }],
            [/'/, { token: 'string.quote', next: '@sqString' }],
            [/\d+(\.\d+)?/, 'number'],
            [/\b(do|end|if|unless|else|elsif|case|when|then|while|until|for|in|return|yield|def|class|module|nil|true|false|self|super|and|or|not|begin|rescue|ensure|raise)\b/, 'keyword'],
            [/[A-Z][\w]*/, 'type.identifier'],
            [/[\w]+[?!]?/, 'identifier'],
            [/[+\-*\/=<>!&|^~%]+/, 'keyword.operator'],
            [/[,;.()\[\]{}]/, 'delimiter'],
            [/#[^{].*$/, 'comment'],
          ],
          erbComment: [
            [/%>/, { token: 'comment.erb', next: '@pop' }],
            [/./, 'comment'],
          ],
          jsBlockComment: [
            [/\*\//, { token: 'comment', next: '@pop' }],
            [/./, 'comment'],
          ],
          dqString: [
            [/[^\\"]+/, 'string'],
            [/\\./, 'string.escape'],
            [/"/, { token: 'string.quote', next: '@pop' }],
          ],
          sqString: [
            [/[^\\']/, 'string'],
            [/\\./, 'string.escape'],
            [/'/, { token: 'string.quote', next: '@pop' }],
          ],
          templateString: [
            [/[^`\\$]+/, 'string'],
            [/\\./, 'string.escape'],
            [/\$\{/, { token: 'delimiter.bracket', next: '@jsExpr' }],
            [/`/, { token: 'string.quote', next: '@pop' }],
          ],
          jsExpr: [
            [/\}/, { token: 'delimiter.bracket', next: '@pop' }],
            [/[\w$]+/, 'identifier'],
            [/[+\-*\/=<>!&|^~%?:.,]+/, 'keyword.operator'],
          ],
        }
      });
    }

    var fileName = tab.path.split('/').pop() || '';
    var fileNameLower = fileName.toLowerCase();
    var language = 'plaintext';

    // Compound extensions (must check before single-extension switch)
    if (/\.js\.erb$/.test(fileNameLower)) {
      language = 'js-erb';
    } else if (/\.ts\.erb$/.test(fileNameLower)) {
      language = 'typescript';
    } else if (/\.js\.haml$/.test(fileNameLower)) {
      language = 'javascript';
    } else if (/\.css\.erb$/.test(fileNameLower)) {
      language = 'css';
    } else if (/\.html\.erb$/.test(fileNameLower)) {
      language = 'erb';
    } else if (/\.html\.haml$/.test(fileNameLower)) {
      language = 'haml';
    } else {

    var parts = fileName.split('.');
    var extension = parts.length > 1 ? parts.pop().toLowerCase() : '';
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
      case 'html':
        language = 'html';break;
      case 'erb':
        language = 'erb';break;
      case 'haml':
        language = 'haml';break;
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

    } // end compound-extension else

    if (language === 'image') return;

    lastAppliedExternalVersionRef.current = -1;

    // Look up or create a persistent Monaco model for this file path.
    // Reusing the model across tab switches preserves the undo/redo history.
    if (!window.__mbeditorModels) window.__mbeditorModels = {};
    var _modelEntry = window.__mbeditorModels[tab.path];
    var _reusingModel = false;
    var modelObj;
    if (_modelEntry && _modelEntry.model && !_modelEntry.model.isDisposed()) {
      modelObj = _modelEntry.model;
      _reusingModel = true;
      // Update access timestamp so LRU eviction knows this model was recently used.
      _modelEntry.lastAccessed = Date.now();
      // Re-apply language in case it changed (e.g. file renamed)
      if (modelObj.getLanguageId() !== language) {
        window.monaco.editor.setModelLanguage(modelObj, language);
      }
    } else {
      // Evict the LRU model if the cache is at capacity before creating a new one.
      TabManager.evictLruModel();
      modelObj = window.monaco.editor.createModel(tab.content, language);
      window.__mbeditorModels[tab.path] = { model: modelObj, aviBase: null, aviMax: null, lastAccessed: Date.now(), cleanVersionId: null };
      _modelEntry = window.__mbeditorModels[tab.path];
    }

    // Sync latestContentRef from the actual model content so the onDidChangeContent
    // handler doesn't fire a spurious onContentChange call on the first keystroke.
    latestContentRef.current = _reusingModel ? modelObj.getValue() : (tab.content || '');

    var editor = window.monaco.editor.create(editorRef.current, {
      model: modelObj,
      theme: editorPrefs.theme || 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: !!(editorPrefs.minimap) },
      renderLineHighlight: editorPrefs.renderLineHighlight || 'none',
      bracketPairColorization: { enabled: editorPrefs.bracketPairColorization !== false },
      fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
      fontSize: editorPrefs.fontSize || 13,
      lineHeight: editorPrefs.lineHeight || 0,
      letterSpacing: editorPrefs.letterSpacing || 0,
      tabSize: editorPrefs.tabSize || 4,
      insertSpaces: typeof editorPrefs.insertSpaces === 'boolean' ? editorPrefs.insertSpaces : false,
      wordWrap: editorPrefs.wordWrap || 'off',
      lineNumbers: editorPrefs.lineNumbers || 'on',
      renderWhitespace: editorPrefs.renderWhitespace || 'none',
      scrollBeyondLastLine: !!(editorPrefs.scrollBeyondLastLine),
      cursorStyle: editorPrefs.cursorStyle || 'line',
      cursorBlinking: editorPrefs.cursorBlinking || 'blink',
      folding: editorPrefs.folding !== false,
      smoothScrolling: !!(editorPrefs.smoothScrolling),
      mouseWheelZoom: !!(editorPrefs.mouseWheelZoom),
      autoClosingBrackets: editorPrefs.autoClosingBrackets || 'always',
      autoClosingQuotes: editorPrefs.autoClosingQuotes || 'always',
      autoIndent: editorPrefs.autoIndent || 'full',
      formatOnPaste: editorPrefs.formatOnPaste !== false,
      formatOnType: editorPrefs.formatOnType !== false,
      quickSuggestions: editorPrefs.quickSuggestions !== false,
      wordBasedSuggestions: editorPrefs.wordBasedSuggestions || 'matchingDocuments',
      acceptSuggestionOnEnter: editorPrefs.acceptSuggestionOnEnter || 'on',
      linkedEditing: true,
      fixedOverflowWidgets: true,
      hover: { above: false }
    });

    if (tab.viewState) {
      editor.restoreViewState(tab.viewState);
    }

    // Restore the find widget state from the previous editor (when persistFindState is on).
    if (editorPrefs.persistFindState !== false && window.__mbeditorFindState && window.__mbeditorFindState.searchString) {
      var _savedFind = window.__mbeditorFindState;
      if (_savedFind.isRevealed) {
        // Open the widget first (setTimeout so layout is ready), then re-apply the
        // saved query — actions.find may seed from the selection and overwrite it.
        setTimeout(function() {
          try {
            editor.trigger('', 'actions.find', null);
            setTimeout(function() {
              try {
                var _fc0 = editor.getContribution('editor.contrib.findController');
                if (_fc0 && _fc0.getState) {
                  _fc0.getState().change({
                    searchString: _savedFind.searchString,
                    isRegex: !!_savedFind.isRegex,
                    matchCase: !!_savedFind.matchCase,
                    wholeWord: !!_savedFind.wholeWord
                  }, false);
                }
              } catch (e) {}
            }, 0);
          } catch (e) {}
        }, 0);
      } else {
        // Widget was closed — just seed the state silently so Ctrl+F pre-fills it.
        try {
          var _fc0 = editor.getContribution('editor.contrib.findController');
          if (_fc0 && _fc0.getState) {
            _fc0.getState().change({
              searchString: _savedFind.searchString,
              isRegex: !!_savedFind.isRegex,
              matchCase: !!_savedFind.matchCase,
              wholeWord: !!_savedFind.wholeWord
            }, false);
          }
        } catch (e) {}
      }
    }

    monacoRef.current = editor;
    window.__mbeditorActiveEditor = editor;
    setEditorReady(true);

    // Stash the workspace-relative path on the model so code-action providers
    // can identify which file they are operating on without needing React state.
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

    // Column selection only when Ctrl/Cmd is held during drag.
    // We toggle Monaco's columnSelection option on Ctrl/Cmd+mousedown and reset on mouseup.
    // Alt+mousedown without Ctrl/Cmd is suppressed (preventDefault stops Monaco's built-in Alt+drag).
    var onColumnMouseDown = function(ev) {
      if (ev.ctrlKey || ev.metaKey) {
        editor.updateOptions({ columnSelection: true });
      } else if (ev.altKey) {
        ev.preventDefault();
      }
    };
    var onColumnMouseUp = function() {
      editor.updateOptions({ columnSelection: false });
    };
    var editorDomNode = editor.getDomNode();
    editorDomNode.addEventListener('mousedown', onColumnMouseDown, true);
    document.addEventListener('mouseup', onColumnMouseUp, true);

    var onFindWidgetKeyDown = function(e) {
      if (!e.target || !e.target.closest) return;
      if (!e.target.closest('.find-widget')) return;
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        e.stopPropagation();
        editor.trigger('keyboard', 'editor.action.nextMatchFindAction', null);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        e.stopPropagation();
        editor.trigger('keyboard', 'editor.action.previousMatchFindAction', null);
      }
    };
    editorDomNode.addEventListener('keydown', onFindWidgetKeyDown, true);

    var columnSelectDisposable = {
      dispose: function() {
        editorDomNode.removeEventListener('mousedown', onColumnMouseDown, true);
        document.removeEventListener('mouseup', onColumnMouseUp, true);
        editorDomNode.removeEventListener('keydown', onFindWidgetKeyDown, true);
      }
    };

    // Track undo/redo availability via Monaco's alternativeVersionId.
    // AVI goes up on every edit, down on undo, back up on redo.
    // When reusing an existing model, restore the saved AVI thresholds so the
    // canUndo/canRedo buttons reflect the real state of the undo stack.
    var avi = modelObj.getAlternativeVersionId();
    if (_reusingModel && _modelEntry.aviBase !== null) {
      aviBaseRef.current = _modelEntry.aviBase;
      aviMaxRef.current = _modelEntry.aviMax !== null ? _modelEntry.aviMax : avi;
    } else {
      aviBaseRef.current = avi;
      aviMaxRef.current = avi;
      // Record the clean baseline for dirty-state tracking on initial model creation.
      _modelEntry.cleanVersionId = avi;
    }
    EditorStore.setState({ canUndo: avi > aviBaseRef.current, canRedo: avi < aviMaxRef.current });

    var contentDisposable = modelObj.onDidChangeContent(function (e) {
      var currentAvi = modelObj.getAlternativeVersionId();
      if (!e.isUndoing && !e.isRedoing) {
        // New edit: redo stack discarded at this point, so max resets here
        aviMaxRef.current = currentAvi;
      } else if (currentAvi > aviMaxRef.current) {
        aviMaxRef.current = currentAvi;
      }
      EditorStore.setState({ canUndo: currentAvi > aviBaseRef.current, canRedo: currentAvi < aviMaxRef.current });

      var val = editor.getValue();

      // Dirty-state tracking via alternativeVersionId — O(1), no string comparison.
      // AVI decrements on undo so it returns to cleanVersionId after a full undo.
      // Skip entirely when cleanVersionId is null — file is mid-load, not yet settled.
      var _entry = window.__mbeditorModels && window.__mbeditorModels[tab.path];
      var _cleanAvi = _entry && _entry.cleanVersionId;
      if (_cleanAvi !== null && _cleanAvi !== undefined) {
        if (currentAvi !== _cleanAvi) {
          TabManager.markDirty(paneId, tab.id, val);
        } else {
          TabManager.markClean(paneId, tab.id, val);
        }
      }

      var currentContent = latestContentRef.current;

      // Normalize before comparing to prevent false positive dirty edits
      var vNorm = val.replace(/\r\n/g, '\n');
      var cNorm = currentContent.replace(/\r\n/g, '\n');
      if (vNorm !== cNorm) {
        // Update the ref immediately so rapid undo/redo events compare against the
        // latest content rather than a stale snapshot from a previous React render.
        latestContentRef.current = val;
        onContentChange(val);
      }
    });

    return function () {
      blameDecorationsRef.current = editor.deltaDecorations(blameDecorationsRef.current, []);
      testDecorationIdsRef.current = editor.deltaDecorations(testDecorationIdsRef.current, []);
      clearBlameZones(editor);
      clearTestZones(editor);
      TabManager.saveTabViewState(tab.id, editor.saveViewState());
      // Persist AVI thresholds on the model entry so undo/redo state is correct on return.
      var _me = window.__mbeditorModels && window.__mbeditorModels[tab.path];
      if (_me) {
        _me.aviBase = aviBaseRef.current;
        _me.aviMax = aviMaxRef.current;
      }
      // Save the current find widget state so it can be restored on next tab switch.
      // Only overwrite the global state when there is an actual search string — this
      // prevents a blank/fresh editor from clobbering the shared query.
      if (editorPrefs.persistFindState !== false) {
        try {
          var _fc = editor.getContribution('editor.contrib.findController');
          if (_fc && _fc.getState) {
            var _fs = _fc.getState();
            if (_fs.searchString) {
              window.__mbeditorFindState = {
                searchString: _fs.searchString,
                isRegex: _fs.isRegex,
                matchCase: _fs.matchCase,
                wholeWord: _fs.wholeWord,
                isRevealed: _fs.isRevealed
              };
            }
          }
        } catch (e) {}
      }
      if (window.__mbeditorActiveEditor === editor) {
        window.__mbeditorActiveEditor = null;
      }
      if (editorPluginDisposable) editorPluginDisposable.dispose();
      formatActionDisposable.dispose();
      columnSelectDisposable.dispose();
      contentDisposable.dispose();
      EditorStore.setState({ canUndo: false, canRedo: false });
      // Detach the model before disposing the editor so the model (and its undo
      // history) survives for when the user returns to this tab.
      editor.setModel(null);
      editor.dispose();
    };
  }, [tab.id, tab.isPreview, monacoReady]); // re-run on tab switch or when Monaco becomes ready

  // Listen for external content changes (e.g. after Format/Load)
  // Only applies when externalContentVersion advances — prevents stale typing-originated
  // React renders from rolling back content the user just typed.
  useEffect(function () {
    var editor = monacoRef.current;
    if (!editor || typeof tab.content !== 'string') return;

    var extVersion = tab.externalContentVersion || 0;
    if (extVersion <= lastAppliedExternalVersionRef.current) return;

    lastAppliedExternalVersionRef.current = extVersion;
    latestContentRef.current = tab.content; // keep ref in sync for onDidChangeContent closure

    var model = editor.getModel();
    if (!model) return;

    // Normalize before comparing to prevent false positive dirty edits
    var vNorm = editor.getValue().replace(/\r\n/g, '\n');
    var cNorm = tab.content.replace(/\r\n/g, '\n');
    if (vNorm === cNorm) return;

    if (!vNorm) {
      // If the editor is currently completely empty, treat it as an initial load.
      // setValue clears the undo stack which is correct for initial load.
      // Null cleanVersionId before setValue so the synchronous onDidChangeContent
      // fires during setValue and skips the dirty check (cleanVersionId is null).
      var _initEntry = window.__mbeditorModels && window.__mbeditorModels[tab.path];
      if (_initEntry) _initEntry.cleanVersionId = null;
      editor.setValue(tab.content);
      // Reset the AVI baseline: setValue clears the undo stack so anything before
      // this point is no longer reachable. Also clear the canUndo/canRedo display.
      var newBase = model.getAlternativeVersionId();
      aviBaseRef.current = newBase;
      aviMaxRef.current = newBase;
      if (_initEntry) _initEntry.cleanVersionId = newBase;
      EditorStore.setState({ canUndo: false, canRedo: false });
    } else {
      // Keep undo stack for formats or replaces by using executeEdits
      editor.pushUndoStop();
      editor.executeEdits("external", [{
        range: model.getFullModelRange(),
        text: tab.content
      }]);
      editor.pushUndoStop();
    }
  }, [tab.content, tab.externalContentVersion]);

  // Apply editorPrefs changes to a running editor without remounting
  useEffect(function () {
    if (!window.monaco) return;
    var theme = editorPrefs.theme || 'vs-dark';
    window.monaco.editor.setTheme(theme);
    if (monacoRef.current) {
      monacoRef.current.updateOptions({
        fontSize: editorPrefs.fontSize || 13,
        fontFamily: editorPrefs.fontFamily || "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
        lineHeight: editorPrefs.lineHeight || 0,
        letterSpacing: editorPrefs.letterSpacing || 0,
        tabSize: editorPrefs.tabSize || 4,
        insertSpaces: typeof editorPrefs.insertSpaces === 'boolean' ? editorPrefs.insertSpaces : false,
        wordWrap: editorPrefs.wordWrap || 'off',
        lineNumbers: editorPrefs.lineNumbers || 'on',
        renderWhitespace: editorPrefs.renderWhitespace || 'none',
        minimap: { enabled: !!(editorPrefs.minimap) },
        scrollBeyondLastLine: !!(editorPrefs.scrollBeyondLastLine),
        bracketPairColorization: { enabled: editorPrefs.bracketPairColorization !== false },
        renderLineHighlight: editorPrefs.renderLineHighlight || 'none',
        cursorStyle: editorPrefs.cursorStyle || 'line',
        cursorBlinking: editorPrefs.cursorBlinking || 'blink',
        folding: editorPrefs.folding !== false,
        smoothScrolling: !!(editorPrefs.smoothScrolling),
        mouseWheelZoom: !!(editorPrefs.mouseWheelZoom),
        autoClosingBrackets: editorPrefs.autoClosingBrackets || 'always',
        autoClosingQuotes: editorPrefs.autoClosingQuotes || 'always',
        autoIndent: editorPrefs.autoIndent || 'full',
        formatOnPaste: editorPrefs.formatOnPaste !== false,
        formatOnType: editorPrefs.formatOnType !== false,
        quickSuggestions: editorPrefs.quickSuggestions !== false,
        wordBasedSuggestions: editorPrefs.wordBasedSuggestions || 'matchingDocuments',
        acceptSuggestionOnEnter: editorPrefs.acceptSuggestionOnEnter || 'on'
      });
    }
  }, [editorPrefs]);

  // Toggle vim mode when editorPrefs.vimMode changes
  useEffect(function () {
    var editor = monacoRef.current;
    if (!editor) return;

    if (editorPrefs.vimMode) {
      // Lazy-load monaco-vim via the same AMD loader that Monaco uses
      require(['monaco-vim'], function(MonacoVim) {
        // Dispose any previous instance first (e.g. editorPrefs changed rapidly)
        if (vimModeObjRef.current) {
          try { vimModeObjRef.current.dispose(); } catch (e) {}
          vimModeObjRef.current = null;
        }
        var statusNode = vimStatusRef.current;
        if (!statusNode || !monacoRef.current) return;
        var vimInstance = MonacoVim.initVimMode(monacoRef.current, statusNode);
        // Wire :w and :wq to the editor's save action
        MonacoVim.VimMode.Vim.defineEx('write', 'w', function() {
          if (onSaveRef.current) onSaveRef.current();
        });
        MonacoVim.VimMode.Vim.defineEx('wq', 'wq', function() {
          if (onSaveRef.current) onSaveRef.current();
        });
        // Wire Ctrl+P to quick-open (VIM intercepts the key before the window listener sees it)
        MonacoVim.VimMode.Vim.defineEx('mbeditorquickopen', null, function() {
          EditorStore.setState({ isQuickOpenVisible: true });
        });
        MonacoVim.VimMode.Vim.map('<C-p>', ':mbeditorquickopen<CR>', 'normal');
        MonacoVim.VimMode.Vim.map('<C-p>', ':mbeditorquickopen<CR>', 'visual');
        vimModeObjRef.current = vimInstance;
      });
    } else {
      if (vimModeObjRef.current) {
        try { vimModeObjRef.current.dispose(); } catch (e) {}
        vimModeObjRef.current = null;
      }
    }

    return function() {
      if (vimModeObjRef.current) {
        try { vimModeObjRef.current.dispose(); } catch (e) {}
        vimModeObjRef.current = null;
      }
    };
  }, [editorPrefs.vimMode]);

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
        var date = lineData && lineData.date || null;
        var isUncommitted = sha.substring(0, 8) === '00000000';

        return {
          line: ln,
          sha: sha,
          author: isUncommitted ? 'Not Committed' : author,
          summary: summary,
          date: date,
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
            date: item.date,
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
          var dateStr = '';
          if (!block.isUncommitted && block.date) {
            try {
              var d = new Date(block.date);
              dateStr = ' · ' + d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) + ', ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
            } catch (e) { /* ignore */ }
          }
          header.textContent = block.author + dateStr + ' - ' + block.summary;

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

  var testFileCandidates = function(relativePath) {
    if (!relativePath || !relativePath.endsWith('.rb')) return [];

    var basename = relativePath.slice(0, -3);
    var dirParts = relativePath.split('/');
    var leafName = basename.split('/').pop();
    var candidates = [];

    if (dirParts[0] === 'app' && dirParts.length > 1) {
      var subPath = dirParts.slice(1).join('/');
      var subDir = subPath.indexOf('/') !== -1 ? subPath.slice(0, subPath.lastIndexOf('/')) : '';
      candidates.push('test/' + (subDir ? subDir + '/' : '') + leafName + '_test.rb');
      candidates.push('spec/' + (subDir ? subDir + '/' : '') + leafName + '_spec.rb');
    }

    if (dirParts[0] === 'lib') {
      var libSubPath = dirParts.slice(1).join('/');
      var libSubDir = libSubPath.indexOf('/') !== -1 ? libSubPath.slice(0, libSubPath.lastIndexOf('/')) : '';
      candidates.push('test/lib/' + (libSubDir ? libSubDir + '/' : '') + leafName + '_test.rb');
      candidates.push('test/' + (libSubDir ? libSubDir + '/' : '') + leafName + '_test.rb');
      candidates.push('spec/lib/' + (libSubDir ? libSubDir + '/' : '') + leafName + '_spec.rb');
    }

    candidates.push('test/' + leafName + '_test.rb');
    candidates.push('spec/' + leafName + '_spec.rb');

    return candidates.filter(function(candidate, index, list) {
      return list.indexOf(candidate) === index;
    });
  };

  var treeHasPath = function(nodes, targetPath) {
    if (!targetPath) return false;
    var stack = (nodes || []).slice();

    while (stack.length) {
      var node = stack.pop();
      if (!node) continue;
      if (node.path === targetPath) return true;
      if (node.children && node.children.length) {
        stack.push.apply(stack, node.children);
      }
    }

    return false;
  };

  var matchingTestFilePath = function(sourcePath) {
    var normalized = (sourcePath || '').replace(/^\/+/, '');
    if (!normalized || !normalized.endsWith('.rb')) return null;
    if (/^(test|spec)\//.test(normalized) && /_(test|spec)\.rb$/.test(normalized)) return normalized;

    var candidates = testFileCandidates(normalized);
    for (var i = 0; i < candidates.length; i += 1) {
      if (treeHasPath(treeData, candidates[i])) return candidates[i];
    }

    return null;
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
  var fileBaseName = (tab.path || '').split('/').pop().toLowerCase();
  var isRubyFile = ext === 'rb' || ext === 'ruby' || ext === 'gemspec' ||
    fileBaseName === 'gemfile' || fileBaseName === 'gemfile.lock' || fileBaseName === 'rakefile';

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
        // Sanitize link/image hrefs to block javascript: and data: schemes.
        var _origLink = renderer.link.bind(renderer);
        var _origImage = renderer.image.bind(renderer);
        var SAFE_HREF_SCHEME = /^(https?:|mailto:|#|\/)/i;
        var safeHref = function(href) {
          if (!href) return href;
          return SAFE_HREF_SCHEME.test(href.trim()) ? href : '#';
        };
        renderer.link = function(token) {
          if (token && typeof token === 'object') { token = Object.assign({}, token, { href: safeHref(token.href) }); }
          return _origLink(token);
        };
        renderer.image = function(token) {
          if (token && typeof token === 'object') { token = Object.assign({}, token, { href: safeHref(token.href) }); }
          return _origImage(token);
        };
        setMarkup(window.marked.parse(markdownContent, { renderer: renderer }));
      })();
    }
  }, [markdownContent, isMarkdown]);

  // Click-outside handler to close the methods dropdown
  useEffect(function() {
    if (!methodsOpen) return;
    function handleClickOutside(e) {
      var btn = methodsBtnRef.current;
      // Close if click is not on the button (the dropdown uses onMouseDown with preventDefault)
      if (btn && !btn.contains(e.target)) {
        setMethodsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return function() { document.removeEventListener('mousedown', handleClickOutside); };
  }, [methodsOpen]);

  // Parse all method definitions from the current Monaco model
  function parseRubyMethods(model) {
    var methods = [];
    var lineCount = model.getLineCount();
    var DEF_RE = /^\s*def\s+(self\.)?([a-zA-Z_][a-zA-Z0-9_?!=]*)/;
    for (var i = 1; i <= lineCount; i++) {
      var line = model.getLineContent(i);
      var m = DEF_RE.exec(line);
      if (m) {
        var selfPrefix = m[1] ? 'self.' : '';
        methods.push({ line: i, name: selfPrefix + m[2] });
      }
    }
    return methods;
  }

  if (tab.fileNotFound) {
    return React.createElement(
      'div',
      { className: 'monaco-container file-not-found-overlay' },
      React.createElement('i', { className: 'fas fa-exclamation-circle file-not-found-icon' }),
      React.createElement('p', { className: 'file-not-found-title' }, 'File not available on this branch'),
      React.createElement('p', { className: 'file-not-found-path' }, tab.path)
    );
  }

  if (tab.isDiff) {
    var isDiffDark = (editorPrefs.theme || 'vs-dark') !== 'vs' && (editorPrefs.theme || 'vs-dark') !== 'hc-light';
    return React.createElement(window.DiffViewer || DiffViewer, {
      path: tab.repoPath || tab.path,
      original: tab.diffOriginal || "",
      modified: tab.diffModified || "",
      isDark: isDiffDark,
      editorPrefs: editorPrefs
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
    return React.createElement(
      'div',
      { className: 'monaco-container', style: { display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#1e1e1e' } },
      React.createElement('img', { src: window.mbeditorBasePath() + '/raw?path=' + encodeURIComponent(tab.path), style: { maxWidth: '90%', maxHeight: '90%', objectFit: 'contain' }, alt: tab.name })
    );
  }

  if (tab.isPreview && isMarkdown) {
    return React.createElement('div', { className: 'markdown-preview markdown-preview-full', dangerouslySetInnerHTML: { __html: markup } });
  }

  // Helper: shorten long paths by showing the last 2 segments with a leading ellipsis
  function shortPath(path) {
    if (!path) return '';
    var parts = path.split('/');
    if (parts.length <= 3) return path;
    return '\u2026/' + parts.slice(-2).join('/');
  }

  // While Monaco is still loading, show a lightweight skeleton so the UI is
  // visible immediately without calling monaco.editor.create() too early.
  if (!monacoReady) {
    return React.createElement(
      'div',
      { className: 'monaco-container monaco-loading-skeleton', style: { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', color: '#888', fontSize: '13px' } },
      'Loading editor…'
    );
  }

  // Always render the same wrapper structure so the editorRef div is never
  // unmounted when gitAvailable changes (e.g. loaded async after workspace
  // call returns). The toolbar is conditionally included inside the wrapper.
  return React.createElement(
    'div',
    { className: 'ide-editor-wrapper', style: { position: 'relative', display: 'flex', flexDirection: 'column', height: '100%' } },
    tab.loading && React.createElement(
      'div',
      { className: 'editor-loading-overlay' },
      React.createElement('div', { className: 'editor-loading-spinner' })
    ),
    tab.path && React.createElement(
      'div',
      { className: 'ide-editor-toolbar' },
      React.createElement(
        'span',
        { className: 'ide-editor-file-location', title: tab.path },
        shortPath(tab.path)
      ),
      gitAvailable && tab.path && React.createElement(
        'button',
        {
          className: 'ide-icon-btn',
          onClick: function() { if (onShowHistory) onShowHistory(tab.path); },
          title: 'File History'
        },
        React.createElement('i', { className: 'fas fa-history', style: { marginRight: editorPrefs.toolbarIconOnly ? 0 : '5px', flexShrink: 0 } }),
        !editorPrefs.toolbarIconOnly && React.createElement('span', { className: 'ide-toolbar-label' }, 'History')
      ),
      isRubyFile && React.createElement(
        'button',
        {
          ref: methodsBtnRef,
          className: 'ide-icon-btn' + (methodsOpen ? ' active' : ''),
          onClick: function() {
            var nextOpen = !methodsOpen;
            if (nextOpen) {
              var model = monacoRef.current && monacoRef.current.getModel();
              setMethodsList(model ? parseRubyMethods(model) : []);
              if (methodsBtnRef.current) {
                var rect = methodsBtnRef.current.getBoundingClientRect();
                setMethodsDropdownPos({ top: rect.bottom + 4, right: window.innerWidth - rect.right });
              }
            }
            setMethodsOpen(nextOpen);
          },
          title: 'Jump to Method'
        },
        React.createElement('i', { className: 'fas fa-list-ul', style: { marginRight: editorPrefs.toolbarIconOnly ? 0 : '5px', flexShrink: 0 } }),
        !editorPrefs.toolbarIconOnly && React.createElement('span', { className: 'ide-toolbar-label' }, 'Methods')
      ),
      gitAvailable && React.createElement(
        'button',
        {
          className: 'ide-icon-btn ' + (isBlameVisible ? 'active' : ''),
          onClick: function() { setIsBlameVisible(function(prev) { return !prev; }); },
          title: 'Toggle Git Blame'
        },
        React.createElement('i', { className: 'fas fa-shoe-prints', style: { marginRight: editorPrefs.toolbarIconOnly ? 0 : '5px', flexShrink: 0 } }),
        !editorPrefs.toolbarIconOnly && React.createElement('span', { className: 'ide-toolbar-label' }, isBlameLoading ? 'Loading...' : 'Blame')
      ),
      testAvailable && matchingTestFilePath(tab.path) && React.createElement(
        'button',
        {
          className: 'ide-icon-btn',
          onClick: function() { if (onRunTest) onRunTest(); },
          disabled: testLoading,
          'aria-busy': !!testLoading,
          title: 'Run Tests'
        },
        !testLoading && React.createElement('i', { className: 'fas fa-flask', style: { marginRight: editorPrefs.toolbarIconOnly ? 0 : '5px', flexShrink: 0 } }),
        !editorPrefs.toolbarIconOnly && !testLoading && React.createElement('span', { className: 'ide-toolbar-label' }, 'Test')
      )
    ),
    React.createElement('div', { ref: editorRef, className: 'monaco-container', style: { flex: 1, minHeight: 0 } }),
    methodsOpen && methodsDropdownPos && React.createElement(
      'div',
      {
        className: 'ide-methods-dropdown',
        style: { position: 'fixed', top: methodsDropdownPos.top + 'px', right: methodsDropdownPos.right + 'px', left: 'auto', zIndex: 9900 }
      },
      methodsList.length === 0
        ? React.createElement('div', { className: 'ide-methods-dropdown-empty' }, 'No methods found')
        : methodsList.map(function(m) {
            return React.createElement(
              'div',
              {
                key: m.line,
                className: 'ide-methods-dropdown-item',
                onMouseDown: function(e) {
                  e.preventDefault();
                  setMethodsOpen(false);
                  if (monacoRef.current) {
                    monacoRef.current.revealLineInCenter(m.line);
                    monacoRef.current.setPosition({ lineNumber: m.line, column: 1 });
                    monacoRef.current.focus();
                  }
                }
              },
              React.createElement('span', { className: 'ide-methods-dropdown-line' }, m.line),
              m.name
            );
          })
    ),
    React.createElement('div', { ref: vimStatusRef, className: 'vim-statusbar', style: { display: editorPrefs.vimMode ? 'flex' : 'none', height: '22px', alignItems: 'center', padding: '0 10px', fontFamily: "'JetBrains Mono', 'Fira Code', Consolas, monospace", fontSize: '12px', background: 'var(--ide-statusbar-bg, #1e1e2e)', color: 'var(--ide-statusbar-fg, #9cdcfe)', borderTop: '1px solid var(--ide-border, #3e3e3e)', flexShrink: 0, userSelect: 'none', letterSpacing: '0.02em' } })
  );
};

window.EditorPanel = EditorPanel;