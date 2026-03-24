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

  var globalsRegistered = false;

  function leadingWhitespace(line) {
    var match = line.match(/^\s*/);
    return match ? match[0] : '';
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function rubyIndentUnit(model) {
    var options = model.getOptions ? model.getOptions() : null;
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

    if (language === 'ruby') {
      keydownDisposable = editor.onKeyDown(function (event) {
        if (event.keyCode !== window.monaco.KeyCode.Enter) return;
        if (!handleRubyEnter(editor, model)) return;

        event.preventDefault();
        event.stopPropagation();
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
        contentDisposable.dispose();
      }
    };
  }

  function registerGlobalExtensions(monaco) {
    if (globalsRegistered) return;
    if (!monaco || !monaco.languages) return;

    globalsRegistered = true;

    monaco.languages.setLanguageConfiguration('ruby', {
      indentationRules: {
        increaseIndentPattern: /^\s*(def|class|module|if|unless|case|while|until|for|begin|elsif|else|rescue|ensure|when)\b/,
        decreaseIndentPattern: /^\s*(end|elsif|else|rescue|ensure|when)\b/
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
