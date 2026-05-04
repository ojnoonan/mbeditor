'use strict';

(function () {
  var RUBY_BLOCK_START = /^\s*(def|class|module|if|unless|case|while|until|for|begin)\b.*$/;
  var RUBY_DO_BLOCK_START = /\bdo(\s*\|.*\|)?\s*$/;
  var RUBY_END_LINE = /^end\b/;
  var VOID_HTML_ELEMENTS = {
    area: true,
    base: true,
    br: true,
    col: true,
    embed: true,
    hr: true,
    img: true,
    input: true,
    link: true,
    meta: true,
    param: true,
    source: true,
    track: true,
    wbr: true
  };

  var RUBY_KEYWORDS = {
    def: true, end: true, 'if': true, 'else': true, elsif: true,
    unless: true, 'while': true, until: true, 'for': true, 'do': true,
    'return': true, 'class': true, 'module': true, begin: true,
    rescue: true, ensure: true, 'raise': true, yield: true,
    'self': true, 'super': true, 'true': true, 'false': true, 'nil': true,
    then: true, when: true, 'case': true, 'in': true, 'and': true,
    'or': true, not: true, require: true, include: true, extend: true
  };

  // Ruby core / Kernel built-in methods that should never trigger a
  // definition lookup — ctrl+click or F12 on these is a no-op.
  var RUBY_CORE_METHODS = {
    puts: true, print: true, p: true, pp: true, warn: true, printf: true,
    fail: true, require_relative: true, prepend: true,
    attr_accessor: true, attr_reader: true, attr_writer: true,
    lambda: true, proc: true, 'loop': true, sleep: true,
    exit: true, abort: true, rand: true, srand: true, gets: true,
    sprintf: true, format: true, open: true,
    Integer: true, Float: true, String: true, Array: true, Hash: true,
    Rational: true, Complex: true,
    readline: true, readlines: true,
    system: true, exec: true, fork: true, spawn: true,
    freeze: true, frozen: true, dup: true, clone: true, object_id: true,
    respond_to: true, send: true, public_send: true, method: true,
    tap: true, itself: true
  };

  var globalsRegistered = false;

  // Enumerate window for user-defined globals and return a TypeScript declaration string.
  // Sprockets exposes every top-level var/function as a window property before Monaco
  // initialises, so scanning at registration time captures all components and helpers.
  //
  // Filter: keep only plain writable data properties (configurable, writable, no getter).
  // Browser built-ins are either non-configurable or accessor properties (hasGet), so
  // this reliably separates them from user-assigned globals without a native-code test
  // (which only works for functions, not objects like `document` or `location`).
  function buildWindowGlobalsShim() {
    var alreadyDeclared = { React: 1, ReactDOM: 1, PropTypes: 1, MaterialUI: 1, $: 1, jQuery: 1 };
    var lines = [];
    try {
      var keys = Object.keys(window);
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        if (alreadyDeclared[key]) continue;
        if (!/^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(key)) continue;
        var value;
        try { value = window[key]; } catch (e) { continue; }
        if (value === null || value === undefined) continue;
        lines.push('declare var ' + key + ': any;');
      }
    } catch (e) {}
    return lines.join('\n');
  }

  function leadingWhitespace(line) {
    var match = line.match(/^\s*/);
    return match ? match[0] : '';
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function rubyIndentUnit(model) {
    var options = model.getOptions ? model.getOptions() : null;
    if (options && options.insertSpaces === false) {
      return '\t';
    }
    var tabSize = options && options.tabSize ? options.tabSize : 4;
    return new Array(tabSize + 1).join(' ');
  }

  function rubyClosingIndent(model, cursorLineNumber, openerLine) {
    var cursorIndent = leadingWhitespace(model.getLineContent(cursorLineNumber));
    var indentUnit = rubyIndentUnit(model);

    if (cursorIndent.length >= indentUnit.length) {
      return cursorIndent.slice(0, cursorIndent.length - indentUnit.length);
    }

    return leadingWhitespace(openerLine);
  }

  function isRubyBlockStart(line) {
    var trimmed = line.trim();
    if (!trimmed || trimmed[0] === '#') return false;
    return RUBY_BLOCK_START.test(line) || RUBY_DO_BLOCK_START.test(trimmed);
  }

  function hasMatchingRubyEnd(model, openerLineNumber, openerIndent) {
    var lineCount = model.getLineCount();
    var openerIndentLength = openerIndent.length;

    for (var lineNumber = openerLineNumber + 1; lineNumber <= lineCount; lineNumber += 1) {
      var line = model.getLineContent(lineNumber);
      var trimmed = line.trim();
      if (!trimmed || trimmed[0] === '#') continue;

      var lineIndent = leadingWhitespace(line);
      var lineIndentLength = lineIndent.length;

      if (RUBY_END_LINE.test(trimmed)) {
        if (lineIndentLength === openerIndentLength) return true;
        if (lineIndentLength < openerIndentLength) return false;
      }
    }

    return false;
  }

  function rubyEnterContext(editor, model) {
    var selection = editor.getSelection();
    if (!selection || !selection.isEmpty()) return null;

    var cursorPosition = editor.getPosition();
    if (!cursorPosition) return null;

    var openerLine = model.getLineContent(cursorPosition.lineNumber);
    var beforeCursor = openerLine.substring(0, cursorPosition.column - 1);
    var afterCursor = openerLine.substring(cursorPosition.column - 1);

    if (afterCursor.trim() !== '') return null;
    if (!isRubyBlockStart(beforeCursor)) return null;

    return {
      cursorPosition: cursorPosition,
      openerIndent: leadingWhitespace(openerLine),
      hasExistingEnd: hasMatchingRubyEnd(model, cursorPosition.lineNumber, leadingWhitespace(openerLine))
    };
  }

  function handleRubyEnter(editor, model) {
    var context = rubyEnterContext(editor, model);
    if (!context) return false;

    var innerIndent = context.openerIndent + rubyIndentUnit(model);
    var insertedText = '\n' + innerIndent;
    if (!context.hasExistingEnd) {
      insertedText += '\n' + context.openerIndent + 'end';
    }

    editor.executeEdits('ruby-auto-end', [{
      range: new window.monaco.Range(context.cursorPosition.lineNumber, context.cursorPosition.column, context.cursorPosition.lineNumber, context.cursorPosition.column),
      text: insertedText
    }]);

    editor.setPosition({
      lineNumber: context.cursorPosition.lineNumber + 1,
      column: innerIndent.length + 1
    });
    editor.focus();
    return true;
  }

  function handleMarkupAutoClose(editor, model, change) {
    if (change.rangeLength !== 0 || change.text !== '>') return false;

    var lineNumber = change.range.startLineNumber;
    var columnBeforeInsert = change.range.startColumn;
    var lineContent = model.getLineContent(lineNumber);
    var textBefore = lineContent.substring(0, columnBeforeInsert - 1);

    if (/\/$/.test(textBefore)) return false;

    var tagMatch = textBefore.match(/<([a-zA-Z][a-zA-Z0-9:\-_]*)(?:\s+[^>]*?)?$/);
    if (!tagMatch) return false;

    var tagName = tagMatch[1];
    if (VOID_HTML_ELEMENTS[tagName.toLowerCase()]) return false;

    var closingTag = '</' + tagName + '>';
    var afterCursor = lineContent.substring(columnBeforeInsert);
    var existingClosePattern = new RegExp('^\\s*' + escapeRegExp(closingTag));
    if (existingClosePattern.test(afterCursor)) return false;

    window.setTimeout(function () {
      var activeModel = editor.getModel();
      if (!activeModel || activeModel !== model) return;

      var latestLineContent = model.getLineContent(lineNumber);
      var latestAfterCursor = latestLineContent.substring(columnBeforeInsert);
      if (existingClosePattern.test(latestAfterCursor)) return;

      editor.executeEdits('html-auto-close', [{
        range: new window.monaco.Range(lineNumber, columnBeforeInsert + 1, lineNumber, columnBeforeInsert + 1),
        text: closingTag
      }]);

      window.setTimeout(function () {
        editor.setPosition({ lineNumber: lineNumber, column: columnBeforeInsert + 1 });
        editor.focus();
      }, 0);
    }, 0);

    return true;
  }

  function attachEditorFeatures(editor, language) {
    var model = editor && editor.getModel ? editor.getModel() : null;
    if (!model) {
      return { dispose: function dispose() {} };
    }

    var suppressInternalEdit = false;
    var keydownDisposable = null;
    var emmetTabDisposable = null;
    var gotoMouseDisposable = null;
    var gotoActionDisposable = null;

    // Emmet Tab expansion — active for markup and stylesheet languages
    var EMMET_MARKUP_LANGS = { html: true, xml: true, erb: true, 'html.erb': true, haml: true };
    var EMMET_STYLE_LANGS = { css: true, scss: true, less: true };
    var isEmmetLang = EMMET_MARKUP_LANGS[language] || EMMET_STYLE_LANGS[language];

    if (isEmmetLang && window.emmet && window.emmet.extract && window.emmet.default) {
      var emmetType = EMMET_STYLE_LANGS[language] ? 'stylesheet' : 'markup';
      // editor.addAction() returns a real IDisposable; addCommand() only returns a string.
      emmetTabDisposable = editor.addAction({
        id: 'mbeditor.emmet.expandAbbreviation',
        label: 'Emmet: Expand Abbreviation',
        keybindings: [window.monaco.KeyCode.Tab],
        precondition: '!suggestWidgetVisible && !parameterHintsVisible && !editorHasSelection',
        run: function(editor) {
          var selection = editor.getSelection();
          // Selection indentation should use Monaco defaults, not Emmet expansion.
          if (!selection.isEmpty()) {
            editor.trigger('keyboard', 'editor.action.indentLines', null);
            return;
          }
          var pos = editor.getPosition();
          var lineText = model.getLineContent(pos.lineNumber);
          var textBeforeCursor = lineText.substring(0, pos.column - 1);

          var extracted = null;
          try {
            extracted = window.emmet.extract(textBeforeCursor, { type: emmetType });
          } catch (e) { /* not a valid context */ }

          if (!extracted || !extracted.abbreviation) {
            editor.trigger('keyboard', 'type', { text: '\t' });
            return;
          }

          var abbr = extracted.abbreviation;
          var expanded = null;
          try {
            expanded = window.emmet.default(abbr, { type: emmetType });
          } catch (e) { /* not a valid abbreviation */ }

          if (!expanded) {
            editor.trigger('keyboard', 'type', { text: '\t' });
            return;
          }

          // Place the first tab stop ($1 or ${1}) at cursor; strip remaining markers
          var withTabStop = expanded.replace(/\$\{[0-9]+:[^}]*\}|\$\{[0-9]+\}|\$[0-9]+/g, function(m, offset, str) {
            // Keep first occurrence as cursor position marker (replaced below), remove rest
            return m;
          });
          var firstTabStop = null;
          var expandedClean = withTabStop.replace(/\$\{1:[^}]*\}|\$\{1\}|\$1/g, function(m) {
            if (firstTabStop === null) { firstTabStop = true; return '\x00'; }
            return '';
          }).replace(/\$\{[0-9]+:[^}]*\}|\$\{[0-9]+\}|\$[0-9]+/g, '');

          var cursorMarkerIdx = expandedClean.indexOf('\x00');
          var finalText = expandedClean.replace('\x00', '');

          // Replace the abbreviation text with the expanded result
          var abbrStart = extracted.location + 1; // 1-based column
          var abbrEnd = pos.column; // exclusive

          var range = new window.monaco.Range(pos.lineNumber, abbrStart, pos.lineNumber, abbrEnd);
          editor.executeEdits('emmet', [{ range: range, text: finalText }]);

          // Position cursor at first tab stop if we found one
          if (cursorMarkerIdx >= 0) {
            var textBefore = finalText.substring(0, cursorMarkerIdx);
            var newlines = textBefore.split('\n');
            var newLine = pos.lineNumber + newlines.length - 1;
            var newCol = newlines.length === 1
              ? abbrStart + textBefore.length
              : newlines[newlines.length - 1].length + 1;
            editor.setPosition({ lineNumber: newLine, column: newCol });
          }
        }
      });
    }

    if (language === 'ruby') {
      keydownDisposable = editor.onKeyDown(function (event) {
        if (event.keyCode !== window.monaco.KeyCode.Enter) return;
        if (!handleRubyEnter(editor, model)) return;

        event.preventDefault();
        event.stopPropagation();
      });

      // Navigate to a Ruby symbol: modules/classes go to their definition file,
      // lowercase symbols go to their def line.
      function navigateToWord(word) {
        if (/^[A-Z]/.test(word) && typeof FileService !== 'undefined' && FileService.getModuleMembers) {
          FileService.getModuleMembers(word).then(function(data) {
            if (!data || !data.file) return;
            var filename = data.file.split('/').pop();
            if (typeof TabManager !== 'undefined' && TabManager.openTab) {
              TabManager.openTab(data.file, filename, 1);
            }
          }).catch(function() {});
          return;
        }
        if (typeof FileService === 'undefined' || !FileService.getDefinition) return;
        FileService.getDefinition(word, 'ruby').then(function(data) {
          var results = data && Array.isArray(data.results) ? data.results : [];
          if (results.length === 0) return;
          var r = results[0];
          if (typeof TabManager !== 'undefined' && TabManager.openTab) {
            TabManager.openTab(r.file, r.file.split('/').pop(), r.line);
          }
        }).catch(function() {});
      }

      // Ctrl/Cmd+click — navigate to definition
      gotoMouseDisposable = editor.onMouseDown(function(event) {
        var ctrlOrCmd = event.event.ctrlKey || event.event.metaKey;
        if (!ctrlOrCmd) return;
        // Target type 6 = CONTENT_TEXT in Monaco's MouseTargetType enum
        if (!event.target || event.target.type !== 6) return;

        var position = event.target.position;
        if (!position) return;

        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo || !wordInfo.word || wordInfo.word.length < 2) return;
        if (RUBY_KEYWORDS[wordInfo.word]) return;
        if (RUBY_CORE_METHODS[wordInfo.word]) return;

        event.event.preventDefault();
        navigateToWord(wordInfo.word);
      });

      // F12 — go to definition from keyboard
      gotoActionDisposable = editor.addAction({
        id: 'mbeditor.gotoRubyDefinition',
        label: 'Go to Ruby Definition',
        keybindings: [window.monaco.KeyCode.F12],
        contextMenuGroupId: 'navigation',
        contextMenuOrder: 1.5,
        run: function(ed) {
          var pos = ed.getPosition();
          if (!pos) return;
          var wordInfo = model.getWordAtPosition(pos);
          if (!wordInfo || !wordInfo.word || wordInfo.word.length < 2) return;
          if (RUBY_KEYWORDS[wordInfo.word]) return;
          if (RUBY_CORE_METHODS[wordInfo.word]) return;
          navigateToWord(wordInfo.word);
        }
      });
    }

    // Unused method dimming — grey out `def method_name` for methods with no
    // call-sites anywhere in the workspace.
    var unusedDecIds = [];
    var unusedTimer = null;
    var unusedSaveDisposable = null;

    if (language === 'ruby' && typeof FileService !== 'undefined' && FileService.getUnusedMethods) {
      function refreshUnused() {
        var path = model._mbeditorPath;
        if (!path) return;
        FileService.getUnusedMethods(path).then(function(data) {
          var unused = data && Array.isArray(data.unused) ? data.unused : [];
          var newDecs = unused.map(function(m) {
            var lineContent = model.getLineContent(m.line);
            var defIdx = lineContent.indexOf('def ');
            if (defIdx < 0) return null;
            var nameCol = defIdx + 5; // 1-based column of method name
            return {
              range: new monaco.Range(m.line, nameCol, m.line, nameCol + m.name.length),
              options: {
                inlineClassName: 'mbeditor-unused-def',
                stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
                hoverMessage: { value: '**Unused method** — `' + m.name + '` is never called in this application.' }
              }
            };
          }).filter(Boolean);
          unusedDecIds = editor.deltaDecorations(unusedDecIds, newDecs);
        }).catch(function() {});
      }

      // Initial check after a short delay (server cache may not be warm yet).
      unusedTimer = setTimeout(refreshUnused, 3000);

      // Re-check after each save event (model content stops changing).
      unusedSaveDisposable = model.onDidChangeContent(function() {
        clearTimeout(unusedTimer);
        unusedTimer = setTimeout(refreshUnused, 5000);
      });
    }

    var contentDisposable = model.onDidChangeContent(function (event) {
      if (suppressInternalEdit) return;
      if (event.isUndoing || event.isRedoing) return;
      if (!event.changes || event.changes.length !== 1) return;

      var change = event.changes[0];
      var handled = false;

      suppressInternalEdit = true;
      try {
        if (language === 'html') {
          handled = handleMarkupAutoClose(editor, model, change) || handled;
        }

        if (language === 'javascript' || language === 'typescript') {
          handled = handleMarkupAutoClose(editor, model, change) || handled;
        }
      } finally {
        suppressInternalEdit = false;
      }

      return handled;
    });

    return {
      dispose: function dispose() {
        if (keydownDisposable) keydownDisposable.dispose();
        if (emmetTabDisposable) emmetTabDisposable.dispose();
        if (gotoMouseDisposable) gotoMouseDisposable.dispose();
        if (gotoActionDisposable) gotoActionDisposable.dispose();
        contentDisposable.dispose();
        if (unusedSaveDisposable) unusedSaveDisposable.dispose();
        clearTimeout(unusedTimer);
        if (unusedDecIds.length > 0) { editor.deltaDecorations(unusedDecIds, []); }
      }
    };
  }

  function registerGlobalExtensions(monaco) {
    if (globalsRegistered) return;
    if (!monaco || !monaco.languages) return;

    globalsRegistered = true;

    // JavaScript: enable semantic checking (off by default in Monaco) and JSX support.
    // checkJs catches undefined variables, noUnusedLocals catches dead assignments.
    if (monaco.languages.typescript && monaco.languages.typescript.javascriptDefaults) {
      monaco.languages.typescript.javascriptDefaults.setDiagnosticsOptions({
        noSemanticValidation: false,
        noSyntaxValidation: false,
        noSuggestionDiagnostics: false
      });
      monaco.languages.typescript.javascriptDefaults.setCompilerOptions({
        target: monaco.languages.typescript.ScriptTarget.ES2020,
        allowNonTsExtensions: true,
        allowJs: true,
        checkJs: true,
        jsx: monaco.languages.typescript.JsxEmit.React,
        noUnusedLocals: true
      });
    }

    // Declare globals that are injected at runtime so checkJs doesn't flag them
    // as undefined. The buildWindowGlobalsShim() function automatically detects
    // window globals from the host application. Common Sprockets globals
    // (React, ReactDOM, etc.) are declared explicitly. For additional globals
    // not auto-detected, add `/* global MyComponent */` at the top of the file.
    if (monaco.languages.typescript && monaco.languages.typescript.javascriptDefaults) {
      monaco.languages.typescript.javascriptDefaults.addExtraLib(
        [
          'declare var React: any;',
          'declare var ReactDOM: any;',
          'declare var PropTypes: any;',
          'declare var MaterialUI: any;',
          'declare var $: any;',
          'declare var jQuery: any;',
          'interface Window { [key: string]: any; }'
        ].join('\n'),
        'inmemory://mbeditor/sprockets-globals.d.ts'
      );

      var dynamicShim = buildWindowGlobalsShim();
      if (dynamicShim) {
        monaco.languages.typescript.javascriptDefaults.addExtraLib(
          dynamicShim,
          'inmemory://mbeditor/window-globals.d.ts'
        );
      }

      // Downgrade certain TypeScript diagnostic codes from Error to Warning.
      // TypeScript has no built-in way to emit these as warnings, so we intercept
      // the marker set after the worker fires and re-apply with lower severity.
      //
      // Patch markers after the TypeScript worker fires:
      // - JS files: suppress TS2304 ("Cannot find name") entirely — host-app globals
      //   injected at runtime are invisible to the language service, so these are
      //   almost always false positives. TS2304 stays as an error in .ts files.
      // - Both: downgrade TS6133 ("declared but never read") from Error to Warning.
      var JS_SUPPRESS_CODES = { '2304': true };
      var JS_WARN_CODES    = { '6133': true };
      var TS_WARN_CODES    = { '6133': true };
      var _severityPatchActive = false;
      monaco.editor.onDidChangeMarkers(function(uris) {
        if (_severityPatchActive) return;
        _severityPatchActive = true;
        try {
          uris.forEach(function(uri) {
            var model = monaco.editor.getModel(uri);
            if (!model) return;
            [
              { owner: 'javascript', suppress: JS_SUPPRESS_CODES, warn: JS_WARN_CODES },
              { owner: 'typescript', suppress: {},                 warn: TS_WARN_CODES }
            ].forEach(function(entry) {
              var markers = monaco.editor.getModelMarkers({ resource: uri, owner: entry.owner });
              var needsPatch = markers.some(function(m) {
                var code = String(m.code);
                return (m.severity === monaco.MarkerSeverity.Error && (entry.suppress[code] || entry.warn[code]));
              });
              if (!needsPatch) return;
              monaco.editor.setModelMarkers(model, entry.owner, markers.filter(function(m) {
                return !entry.suppress[String(m.code)];
              }).map(function(m) {
                return (m.severity === monaco.MarkerSeverity.Error && entry.warn[String(m.code)])
                  ? Object.assign({}, m, { severity: monaco.MarkerSeverity.Warning })
                  : m;
              }));
            });
          });
        } finally {
          _severityPatchActive = false;
        }
      });
    }

    // TypeScript: enable JSX for .tsx files.
    if (monaco.languages.typescript && monaco.languages.typescript.typescriptDefaults) {
      monaco.languages.typescript.typescriptDefaults.setCompilerOptions({
        target: monaco.languages.typescript.ScriptTarget.ES2020,
        allowNonTsExtensions: true,
        jsx: monaco.languages.typescript.JsxEmit.React,
        noUnusedLocals: true
      });
    }

    // CSS for greyed-out unused method names (applied via decoration inlineClassName).
    if (!document.getElementById('mbeditor-unused-style')) {
      var unusedStyle = document.createElement('style');
      unusedStyle.id = 'mbeditor-unused-style';
      unusedStyle.textContent = '.mbeditor-unused-def { opacity: 0.35; }';
      document.head.appendChild(unusedStyle);
    }

    monaco.languages.setLanguageConfiguration('ruby', {
      comments: { lineComment: '#', blockComment: ['=begin', '=end'] },
      brackets: [['(', ')'], ['{', '}'], ['[', ']']],
      autoClosingPairs: [
        { open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' },
        { open: '"', close: '"' }, { open: "'", close: "'" }
      ],
      surroundingPairs: [
        { open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' },
        { open: '"', close: '"' }, { open: "'", close: "'" }
      ],
      indentationRules: {
        increaseIndentPattern: /^\s*(def|class|module|if|unless|case|while|until|for|begin|elsif|else|rescue|ensure|when)\b/,
        decreaseIndentPattern: /^\s*(end|elsif|else|rescue|ensure|when)\b/
      },
      wordPattern: /[a-zA-Z_]\w*[!?]?/
    });

    // Override Monaco's built-in Ruby tokenizer with a comprehensive Monarch grammar
    // that uses TextMate-standard scope names so all bundled themes colour them correctly.
    monaco.languages.setMonarchTokensProvider('ruby', {
      defaultToken: '',
      tokenPostfix: '.ruby',

      tokenizer: {
        root: [
          // =begin / =end block comments
          [/^=begin\b/, { token: 'comment', next: '@blockComment' }],

          // Single-line comments
          [/#.*$/, 'comment'],

          // Heredoc start — capture the terminator word into state arg
          [/<<[-~]?(['"]?)(\w+)\1/, { token: 'string.heredoc.delimiter', next: '@heredoc.$2' }],

          // def + method name (handles self. prefix and operator method names)
          [/(\bdef\b)(\s+)(self)(\.)([\w]+[!?=]?|[+\-*\/%<>=!\[\]&|^~]+)/,
            ['keyword.control.def', '', 'variable.language', 'delimiter', 'entity.name.function']],
          [/(\bdef\b)(\s+)([\w]+[!?=]?|[+\-*\/%<>=!\[\]&|^~]+)/,
            ['keyword.control.def', '', 'entity.name.function']],
          [/\bdef\b/, 'keyword.control.def'],

          // class + name (including singleton class << self)
          [/(\bclass\b)(\s+)([A-Z][\w:]*)/, ['keyword.control.class', '', 'entity.name.class']],
          [/\bclass\b/, 'keyword.control.class'],

          // module + name
          [/(\bmodule\b)(\s+)([A-Z][\w:]*)/, ['keyword.control.module', '', 'entity.name.class']],
          [/\bmodule\b/, 'keyword.control.module'],

          // Language literals
          [/\b(nil|true|false)\b/, 'constant.language'],
          [/\b(self|super)\b/, 'variable.language'],

          // Class variables (@@) — must precede instance variable rule
          [/@@[a-zA-Z_]\w*/, 'variable.other'],
          // Instance variables (@)
          [/@[a-zA-Z_]\w*/, 'variable.other.readwrite.instance'],
          // Global variables ($)
          [/\$[a-zA-Z_]\w*|\$\d+|\$[!@&*()\-.,;<>\/\\~`+?=:#]/, 'variable.other.constant'],

          // Symbols  :foo  :"foo"  :'foo'
          [/:[a-zA-Z_]\w*[!?]?/, 'constant.other.symbol'],
          [/:"/, { token: 'constant.other.symbol', next: '@symDqString' }],
          [/:'/, { token: 'constant.other.symbol', next: '@symSqString' }],

          // Numbers
          [/0[xX][0-9a-fA-F][0-9a-fA-F_]*/, 'constant.numeric'],
          [/0[bB][01][01_]*/, 'constant.numeric'],
          [/0[oO][0-7][0-7_]*/, 'constant.numeric'],
          [/\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?/, 'constant.numeric'],

          // Strings
          [/"/, { token: 'string.quoted.double', next: '@dqString' }],
          [/'/, { token: 'string.quoted.single', next: '@sqString' }],

          // Percent literals — %w[] %i[] %(string)
          [/%[wW]\[/, { token: 'string', next: '@percentWordBracket' }],
          [/%[wW]\(/, { token: 'string', next: '@percentWordParen' }],
          [/%[wW]\{/, { token: 'string', next: '@percentWordCurly' }],
          [/%[iI]\[/, { token: 'constant.other.symbol', next: '@percentSymBracket' }],
          [/%[iI]\(/, { token: 'constant.other.symbol', next: '@percentSymParen' }],
          [/%[qQ]?\(/, { token: 'string.quoted.double', next: '@percentDqParen' }],
          [/%[qQ]?\[/, { token: 'string.quoted.double', next: '@percentDqBracket' }],
          [/%[qQ]?\{/, { token: 'string.quoted.double', next: '@percentDqCurly' }],

          // Regexp literals — simplified: /pat/imxo not preceded by a word boundary that looks like division
          [/\/(?!\s)(?:[^\/\\\n]|\\.)+\/[imxo]*/, 'string.regexp'],

          // Control-flow and other keywords
          [/\b(if|unless|while|until|for|do|case|when|then|else|elsif|end|return|yield|begin|rescue|ensure|raise|break|next|retry|and|or|not|in|__LINE__|__FILE__|__ENCODING__|__method__|__callee__|__dir__|alias|undef|defined\?)\b/, 'keyword.control'],

          // Built-in kernel / module methods (support.function so themes highlight them distinctly)
          [/\b(require|require_relative|load|autoload|include|extend|prepend|attr_reader|attr_writer|attr_accessor|attr|public|private|protected|module_function|puts|print|p|pp|gets|printf|sprintf|format|abort|exit|sleep|rand|srand|lambda|proc|block_given\?|respond_to\?|fail|warn|at_exit|freeze|frozen\?|nil\?|is_a\?|kind_of\?|instance_of\?|tap|itself|raise)\b/, 'support.function'],

          // CamelCase constants and class references
          [/[A-Z][a-zA-Z0-9_]*[?!]?/, 'entity.name.type.class'],

          // Regular identifiers
          [/[a-z_]\w*[!?]?/, 'identifier'],

          // Operators
          [/::/, 'keyword.operator'],
          [/\.\.\.|\.\./, 'keyword.operator'],
          [/<<=|>>=|\*\*=|&&=|\|\|=|[+\-*\/%&|^]=/, 'keyword.operator'],
          [/<=>|===|==|!=|=~|!~|>=|<=|<<|>>|\*\*/, 'keyword.operator'],
          [/[+\-*\/%&|^~<>=!?]/, 'keyword.operator'],

          // Brackets and punctuation
          [/[{}()\[\]]/, '@brackets'],
          [/[;,.]/, 'delimiter'],
          [/\s+/, '']
        ],

        dqString: [
          [/[^\\"\#]+/, 'string.quoted.double'],
          [/#\{/, { token: 'string.interpolated', next: '@interpolated' }],
          [/#[^{]?/, 'string.quoted.double'],
          [/\\./, 'string.quoted.double.escape'],
          [/"/, { token: 'string.quoted.double', next: '@pop' }]
        ],

        sqString: [
          [/[^\\']+/, 'string.quoted.single'],
          [/\\./, 'string.quoted.single.escape'],
          [/'/, { token: 'string.quoted.single', next: '@pop' }]
        ],

        symDqString: [
          [/[^\\"\#]+/, 'constant.other.symbol'],
          [/#\{/, { token: 'string.interpolated', next: '@interpolated' }],
          [/\\./, 'constant.other.symbol'],
          [/"/, { token: 'constant.other.symbol', next: '@pop' }]
        ],
        symSqString: [
          [/[^\\']+/, 'constant.other.symbol'],
          [/\\./, 'constant.other.symbol'],
          [/'/, { token: 'constant.other.symbol', next: '@pop' }]
        ],

        interpolated: [
          [/\}/, { token: 'string.interpolated', next: '@pop' }],
          [/"/, { token: 'string.quoted.double', next: '@dqString' }],
          [/'/, { token: 'string.quoted.single', next: '@sqString' }],
          [/@@[a-zA-Z_]\w*/, 'variable.other'],
          [/@[a-zA-Z_]\w*/, 'variable.other.readwrite.instance'],
          [/\$[a-zA-Z_]\w*/, 'variable.other.constant'],
          [/\b(nil|true|false)\b/, 'constant.language'],
          [/\b(self)\b/, 'variable.language'],
          [/[A-Z][a-zA-Z0-9_]*/, 'entity.name.type.class'],
          [/\d[\d_]*(?:\.\d[\d_]*)?/, 'constant.numeric'],
          [/:[a-zA-Z_]\w*[!?]?/, 'constant.other.symbol'],
          [/[a-z_]\w*[!?]?/, 'identifier'],
          [/::|\.\.\.|\.\./, 'keyword.operator'],
          [/[+\-*\/%&|^~<>=!?.,:()\[\]]+/, 'keyword.operator'],
          [/\s+/, '']
        ],

        heredoc: [
          [/^(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': 'string.heredoc'
            }
          }],
          [/.+/, 'string.heredoc']
        ],

        // %w[] %W[] word arrays
        percentWordBracket: [
          [/\]/, { token: 'string', next: '@pop' }],
          [/[^\]\s\\]+/, 'string'],
          [/\s+/, 'string'],
          [/\\./, 'string.escape']
        ],
        percentWordParen: [
          [/\)/, { token: 'string', next: '@pop' }],
          [/[^)\s\\]+/, 'string'],
          [/\s+/, 'string'],
          [/\\./, 'string.escape']
        ],
        percentWordCurly: [
          [/\}/, { token: 'string', next: '@pop' }],
          [/[^}\s\\]+/, 'string'],
          [/\s+/, 'string'],
          [/\\./, 'string.escape']
        ],

        // %i[] %I[] symbol arrays
        percentSymBracket: [
          [/\]/, { token: 'constant.other.symbol', next: '@pop' }],
          [/[^\]\s\\]+/, 'constant.other.symbol'],
          [/\s+/, 'constant.other.symbol'],
          [/\\./, 'constant.other.symbol']
        ],
        percentSymParen: [
          [/\)/, { token: 'constant.other.symbol', next: '@pop' }],
          [/[^)\s\\]+/, 'constant.other.symbol'],
          [/\s+/, 'constant.other.symbol'],
          [/\\./, 'constant.other.symbol']
        ],

        // %(str) %[str] %{str} interpolating strings
        percentDqParen: [
          [/\)/, { token: 'string.quoted.double', next: '@pop' }],
          [/#\{/, { token: 'string.interpolated', next: '@interpolated' }],
          [/[^)\\\#]+/, 'string.quoted.double'],
          [/\\./, 'string.quoted.double.escape']
        ],
        percentDqBracket: [
          [/\]/, { token: 'string.quoted.double', next: '@pop' }],
          [/#\{/, { token: 'string.interpolated', next: '@interpolated' }],
          [/[^\]\\\#]+/, 'string.quoted.double'],
          [/\\./, 'string.quoted.double.escape']
        ],
        percentDqCurly: [
          [/\}/, { token: 'string.quoted.double', next: '@pop' }],
          [/#\{/, { token: 'string.interpolated', next: '@interpolated' }],
          [/[^}\\\#]+/, 'string.quoted.double'],
          [/\\./, 'string.quoted.double.escape']
        ],

        blockComment: [
          [/^=end\b.*$/, { token: 'comment', next: '@pop' }],
          [/.+/, 'comment']
        ]
      }
    });

    var genericLinkedProvider = {
      provideLinkedEditingRanges: function provideLinkedEditingRanges(model, position) {
        var line = model.getLineContent(position.lineNumber);
        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo) return null;

        var word = wordInfo.word;
        var startCol = wordInfo.startColumn;
        var endCol = wordInfo.endColumn;

        if (line[startCol - 2] === '<') {
          var closeTagStr = '</' + word + '>';
          var closeIdx = line.indexOf(closeTagStr, endCol - 1);
          if (closeIdx !== -1) {
            return {
              ranges: [new monaco.Range(position.lineNumber, startCol, position.lineNumber, endCol), new monaco.Range(position.lineNumber, closeIdx + 3, position.lineNumber, closeIdx + 3 + word.length)],
              wordPattern: /[a-zA-Z0-9:\-_]+/
            };
          }
        }

        if (line[startCol - 3] === '<' && line[startCol - 2] === '/') {
          var openTagRegex = new RegExp('<' + word + '(?:\\s|>)');
          var match = line.match(openTagRegex);
          if (match) {
            var openStart = match.index + 2;
            if (openStart < startCol) {
              return {
                ranges: [new monaco.Range(position.lineNumber, openStart, position.lineNumber, openStart + word.length), new monaco.Range(position.lineNumber, startCol, position.lineNumber, endCol)],
                wordPattern: /[a-zA-Z0-9:\-_]+/
              };
            }
          }
        }

        return null;
      }
    };

    monaco.languages.registerLinkedEditingRangeProvider('javascript', genericLinkedProvider);
    monaco.languages.registerLinkedEditingRangeProvider('typescript', genericLinkedProvider);
    monaco.languages.registerLinkedEditingRangeProvider('ruby', genericLinkedProvider);

    // RuboCop quick-fix code-action provider for Ruby files.
    // Only registers when RuboCop is available in the workspace.
    monaco.languages.registerCodeActionProvider('ruby', {
      provideCodeActions: function provideCodeActions(model, _range, context) {
        if (!window.MBEDITOR_RUBOCOP_AVAILABLE) return { actions: [], dispose: function() {} };

        var correctableCops = model._mbeditorCorrectableCops || new Set();
        var rubocopMarkers = context.markers.filter(function(m) {
          return m.source === 'rubocop' && m.code && correctableCops.has(m.code);
        });

        if (rubocopMarkers.length === 0) return { actions: [], dispose: function() {} };

        var modelPath = model._mbeditorPath || null;
        if (!modelPath) return { actions: [], dispose: function() {} };

        var code = model.getValue();

        var actions = rubocopMarkers.map(function(marker) {
          return {
            title: 'Fix: ' + marker.code,
            kind: 'quickfix',
            isPreferred: rubocopMarkers.length === 1,
            diagnostics: [marker],
            command: {
              id: 'mbeditor.applyRubocopFix',
              title: 'Apply RuboCop fix for ' + marker.code,
              arguments: [model, marker, code, modelPath]
            }
          };
        });

        return { actions: actions, dispose: function() {} };
      }
    });

    // Command handler that fetches the fix from the backend and applies it.
    monaco.editor.registerCommand('mbeditor.applyRubocopFix', function(_accessor, model, marker, code, modelPath) {
      if (typeof FileService === 'undefined' || !FileService.quickFixOffense) return;
      FileService.quickFixOffense(modelPath, code, marker.code).then(function(data) {
        if (!data || !data.fix) return;
        var fix = data.fix;
        model.pushEditOperations([], [{
          range: new monaco.Range(fix.startLine, fix.startCol, fix.endLine, fix.endCol),
          text: fix.replacement
        }], function() { return null; });
      }).catch(function() {});
    });

    // Ruby method definition hover provider.
    // Calls the backend /definition endpoint (Ripper-based) and renders
    // the method signature and any preceding # comments as hover markdown.
    // Results are cached client-side for 60 s to make re-hovers instantaneous.
    var hoverCache = {};
    var HOVER_CACHE_TTL_MS = 60000;

    monaco.languages.registerHoverProvider('ruby', {
      provideHover: function provideHover(model, position, token) {
        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo) return null;

        var word = wordInfo.word;
        if (!word || word.length < 2) return null;
        if (RUBY_KEYWORDS[word]) return null;
        if (RUBY_CORE_METHODS[word]) return null;
        if (typeof FileService === 'undefined' || !FileService.getDefinition) return null;

        // Uppercase first letter → likely a module/class name.
        // Look up the module's exposed methods via /module_members.
        if (/^[A-Z]/.test(word) && FileService.getModuleMembers) {
          var modKey = '__mod__' + word;
          var modCached = hoverCache[modKey];
          if (modCached && (Date.now() - modCached.ts) < HOVER_CACHE_TTL_MS) {
            return modCached.result || null;
          }
          var modController = typeof AbortController !== 'undefined' ? new AbortController() : null;
          if (modController && token && token.onCancellationRequested) {
            token.onCancellationRequested(function() { modController.abort(); });
          }
          return FileService.getModuleMembers(word, modController ? { signal: modController.signal } : {}).then(function(data) {
            if (token && token.isCancellationRequested) return null;
            if (!data || !data.methods || data.methods.length === 0) {
              hoverCache[modKey] = { ts: Date.now(), result: null };
              return null;
            }
            var lines = ['**' + data.name + '**  `' + (data.file || '') + '`\n'];
            data.methods.slice(0, 20).forEach(function(m) {
              lines.push('- `' + (m.signature || m.name) + '`');
            });
            var result = { contents: [{ value: lines.join('\n') }] };
            hoverCache[modKey] = { ts: Date.now(), result: result };
            return result;
          }).catch(function() { return null; });
        }

        var currentFile = model._mbeditorPath || null;

        // Return cached result immediately if still fresh.
        var cached = hoverCache[word];
        if (cached && (Date.now() - cached.ts) < HOVER_CACHE_TTL_MS) {
          var cachedResults = cached.results;
          if (currentFile) {
            cachedResults = cachedResults.filter(function(r) { return r.file !== currentFile; });
          }
          return cachedResults.length > 0 ? buildHoverResult(cachedResults) : null;
        }

        // Cancel the underlying HTTP request when Monaco cancels the hover
        // (e.g. user moved the mouse away before the response arrived).
        var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        if (controller && token && token.onCancellationRequested) {
          token.onCancellationRequested(function() { controller.abort(); });
        }
        var extraOptions = controller ? { signal: controller.signal } : {};

        return FileService.getDefinition(word, 'ruby', extraOptions).then(function(data) {
          // If the hover was cancelled while the request was in flight (e.g. the
          // user moved the mouse away), return null so Monaco's CancelablePromise
          // wrapper resolves cleanly instead of throwing "Canceled".
          if (token && token.isCancellationRequested) return null;

          var results = data && Array.isArray(data.results) ? data.results : [];
          // Cache the raw results (before current-file filter).
          hoverCache[word] = { ts: Date.now(), results: results };

          if (currentFile) {
            results = results.filter(function(r) { return r.file !== currentFile; });
          }
          if (results.length === 0) return null;

          return buildHoverResult(results);
        }).catch(function() { return null; });
      }
    });

    function buildHoverResult(results) {
      var first = results[0];

      // Build two separate MarkdownString sections so Monaco renders a
      // visual divider between the code block and the documentation.
      var codeParts = ['```ruby'];

      // Include a trimmed comment block as a Ruby comment inside the code
      // fence so the whole thing looks like source you'd read in an editor.
      if (first.comments && first.comments.length > 0) {
        first.comments.split('\n').forEach(function(l) {
          codeParts.push(l.trim() || '#');
        });
      }

      codeParts.push(first.signature);
      codeParts.push('```');

      var fileRef = first.line > 0 ? first.file + ':' + first.line : first.file;
      var locationParts = results.length > 1
        ? fileRef + '  _(+' + (results.length - 1) + ' more)_'
        : fileRef;

      return {
        contents: [
          { value: codeParts.join('\n'), isTrusted: true },
          { value: '<span style="opacity:0.55;font-size:0.9em;">' + locationParts + '</span>', isTrusted: true, supportHtml: true }
        ]
      };
    }

    // Include-aware completion provider for Ruby.
    // Suggests methods from modules included/extended/prepended in the current file,
    // with Notepad++-style snippet tab stops for method parameters.
    var includesCache = {};
    var INCLUDES_CACHE_TTL_MS = 30000;

    function parseMethodParams(signature) {
      var m = /\(([^)]+)\)/.exec(signature || '');
      if (!m) return [];
      return m[1].split(',').map(function(p) {
        return p.trim().replace(/^[*&]+/, '').replace(/\s*=.*$/, '').trim();
      }).filter(function(p) { return p.length > 0; });
    }

    monaco.languages.registerCompletionItemProvider('ruby', {
      triggerCharacters: ['.'],
      provideCompletionItems: function(model, position) {
        var path = model._mbeditorPath;
        if (!path || typeof FileService === 'undefined' || !FileService.getFileIncludes) {
          return { suggestions: [] };
        }

        var lineUpToCursor = model.getValueInRange({
          startLineNumber: position.lineNumber, startColumn: 1,
          endLineNumber: position.lineNumber, endColumn: position.column
        });
        var isDot = lineUpToCursor.slice(-1) === '.';

        function buildSuggestions(data) {
          var suggestions = [];
          (data.includes || []).forEach(function(mod) {
            (mod.methods || []).forEach(function(m) {
              var params = parseMethodParams(m.signature);
              var snippet = params.length > 0
                ? m.name + '(' + params.map(function(p, i) {
                    return '${' + (i + 1) + ':' + p + '}';
                  }).join(', ') + ')$0'
                : m.name + '$0';
              suggestions.push({
                label: m.name,
                kind: monaco.languages.CompletionItemKind.Method,
                detail: mod.name + (mod.file ? '  ' + mod.file : ''),
                insertText: snippet,
                insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                sortText: (isDot ? '0' : '1') + m.name
              });
            });
          });
          return { suggestions: suggestions };
        }

        var cached = includesCache[path];
        if (cached && (Date.now() - cached.ts) < INCLUDES_CACHE_TTL_MS) {
          return buildSuggestions(cached.data);
        }

        return FileService.getFileIncludes(path).then(function(result) {
          includesCache[path] = { ts: Date.now(), data: result };
          return buildSuggestions(result);
        }).catch(function() { return { suggestions: [] }; });
      }
    });

    // Vim-style fold-marker folding provider.
    // Recognises {{{ (open) and }}} (close) anywhere in a line, matching the
    // convention used by vim's `foldmethod=marker`. Registered for every
    // language so it works in Ruby, JS, CSS, etc. The provider is additive —
    // Monaco merges its results with any language-specific syntax ranges.
    var VIM_FOLD_OPEN  = /\{\{\{/;
    var VIM_FOLD_CLOSE = /\}\}\}/;

    monaco.languages.registerFoldingRangeProvider({ scheme: '*' }, {
      provideFoldingRanges: function provideFoldingRanges(model) {
        var lineCount = model.getLineCount();
        var stack = [];
        var ranges = [];

        for (var i = 1; i <= lineCount; i++) {
          var line = model.getLineContent(i);
          if (VIM_FOLD_OPEN.test(line)) {
            stack.push(i);
          } else if (VIM_FOLD_CLOSE.test(line) && stack.length > 0) {
            var start = stack.pop();
            ranges.push({ start: start, end: i, kind: monaco.languages.FoldingRangeKind.Region });
          }
        }

        return ranges;
      }
    });
  }

  window.MbeditorEditorPlugins = {
    registerGlobalExtensions: registerGlobalExtensions,
    attachEditorFeatures: attachEditorFeatures,
    runRubyEnter: function runRubyEnter(editor) {
      if (!editor || !editor.getModel) return false;
      return handleRubyEnter(editor, editor.getModel());
    }
  };
})();
