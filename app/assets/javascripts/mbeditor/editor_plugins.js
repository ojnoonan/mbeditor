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

  // JS global discovery: populated as definitions are found via hover/goto/auto-resolve.
  // Persists for the page lifetime so each symbol is only declared once.
  var discoveredJsGlobals = {};
  var attemptedJsGlobals  = {}; // symbols already looked up (found OR not found)
  var jsHoverCache = {};
  var jsMembersCache = {};

  // Enumerate window for user-defined globals and return a TypeScript declaration string.
  // Sprockets exposes every top-level var/function as a window property before Monaco
  // initialises, so scanning at registration time captures all components and helpers.
  //
  // Filter: keep only plain writable data properties (configurable, writable, no getter).
  // Browser built-ins are either non-configurable or accessor properties (hasGet), so
  // this reliably separates them from user-assigned globals without a native-code test
  // (which only works for functions, not objects like `document` or `location`).
  function buildWindowGlobalsShim() {
    var alreadyDeclared = { React: 1, ReactDOM: 1, PropTypes: 1, MaterialUI: 1, $: 1, jQuery: 1, JSX: 1 };
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

  // Return true if sym is a user-assigned window property (not a browser built-in).
  // Uses the same property-descriptor filter as buildWindowGlobalsShim: browser built-ins
  // are either non-configurable or accessor properties (have a getter), so plain writable
  // configurable data properties reliably identify user-assigned globals.
  function isRuntimeWindowGlobal(sym) {
    if (!sym || typeof window === 'undefined') return false;
    try {
      if (!Object.prototype.hasOwnProperty.call(window, sym)) return false;
      var val;
      try { val = window[sym]; } catch (e) { return false; }
      if (val === null || val === undefined) return false;
      var desc = Object.getOwnPropertyDescriptor(window, sym);
      if (!desc) return false;
      return desc.configurable === true && desc.writable === true && !desc.get;
    } catch (e) { return false; }
  }

  // Globals already declared in the React mini-UMD — never add these to
  // discovered-globals.d.ts or TypeScript will see a duplicate identifier.
  var REACT_MINI_UMD_GLOBALS = { React: 1, ReactDOM: 1, PropTypes: 1, MaterialUI: 1, $: 1, jQuery: 1, JSX: 1 };

  // Declare a discovered global in Monaco's extra libs so the TS2304 warning disappears.
  // Calling addExtraLib with the same URI replaces the previous content in-place.
  //
  // Coalesced: addExtraLib invalidates the TypeScript worker and re-validates
  // EVERY open model. A JSX file that references 500 host-app globals resolves
  // 500 symbols, and calling addExtraLib once per symbol meant 500 full
  // re-validations — the editor spends minutes pegged at 100% CPU redoing work
  // it is about to redo again. Batch them into one flush instead.
  var _discoveredFlushTimer = null;
  function flushDiscoveredGlobals() {
    _discoveredFlushTimer = null;
    var mts = window.monaco && window.monaco.languages && window.monaco.languages.typescript;
    if (!mts || !mts.javascriptDefaults) return;
    var decls = Object.keys(discoveredJsGlobals)
      .map(function(k) { return 'declare var ' + k + ': any;'; }).join('\n');
    mts.javascriptDefaults.addExtraLib(decls, 'inmemory://mbeditor/discovered-globals.d.ts');
  }

  function addDiscoveredGlobal(name) {
    if (discoveredJsGlobals[name]) return;
    if (REACT_MINI_UMD_GLOBALS[name]) return; // already in the mini-UMD
    discoveredJsGlobals[name] = true;
    if (_discoveredFlushTimer) return;
    _discoveredFlushTimer = setTimeout(flushDiscoveredGlobals, 300);
  }

  // Reactive TS2304 resolution runs ONE /js_definition request at a time.
  // Each request spawns an rg process on the server, so firing one per
  // unresolved symbol in parallel (a big JSX file can have hundreds) saturated
  // the dev server: the file tree poll, git status, and file saves all queued
  // behind hundreds of greps. That is what made the whole editor feel slow and
  // what let the "file was edited externally" check race its own save.
  var JS_LOOKUP_QUEUE_MAX = 400;
  var jsLookupQueue = [];
  var jsLookupBusy = false;

  function pumpJsLookupQueue() {
    if (jsLookupBusy) return;
    var job = jsLookupQueue.shift();
    if (!job) return;
    jsLookupBusy = true;
    var done = function () { jsLookupBusy = false; pumpJsLookupQueue(); };
    FileService.getJsDefinition(job.sym)
      .then(function (data) {
        var results = data && data.results;
        if (results && results.length && results[0].file !== job.modelPath) {
          addDiscoveredGlobal(job.sym);
        } else if (!results || !results.length) {
          if (isRuntimeWindowGlobal(job.sym)) addDiscoveredGlobal(job.sym);
        }
      })
      .then(done, done);
  }

  function queueJsGlobalLookup(sym, modelPath) {
    if (jsLookupQueue.length >= JS_LOOKUP_QUEUE_MAX) return;
    jsLookupQueue.push({ sym: sym, modelPath: modelPath });
    pumpJsLookupQueue();
  }

  // ── The workspace TypeScript program ──────────────────────────────────────
  //
  // Two layers, because one does not cover everything:
  //
  //   1. /js_program — the workspace's own JS source, added as extraLibs at
  //      file:/// URIs. A JS file with no import/export is a *script*, so
  //      TypeScript puts its top-level declarations in the global scope: the
  //      Sprockets model exactly. This gives REAL types — member completion,
  //      inferred signatures, argument-count checks — for the host app's own
  //      components, and still reports TS2304 for genuinely unknown names.
  //
  //   2. /js_globals — ambient `declare var X: any` for names the program
  //      can't supply. UMD-wrapped libraries (React, lodash, axios) assign
  //      their global inside a closure, `factory(global.React = {})`, which
  //      TypeScript cannot follow statically, so their source contributes no
  //      global at all. Those names only exist as ambient declarations.
  //
  // A global is skipped from layer 2 only when layer 1 genuinely supplies it,
  // so a real inferred type is never shadowed by `any` — and, just as
  // importantly, a name the program can't see never loses its declaration.
  // "In a program file" is NOT sufficient: `window.Foo = ...` is a runtime
  // global that TypeScript does not treat as a declaration at all, so those
  // must keep their ambient `declare var` even though their file is in the
  // program. Only lexical declarations land in TypeScript's global scope.
  //
  // Same-URI addExtraLib replaces content in place; that is how both layers
  // refresh.
  var PROGRAM_VISIBLE_KINDS = { 'var': 1, 'let': 1, 'const': 1, 'function': 1, 'class': 1 };
  var programPaths = {}; // workspace-relative path -> true, for the filter above

  function programUri(path) {
    return 'file:///' + String(path).replace(/^\/+/, '');
  }

  function loadWorkspaceProgram(monaco) {
    if (typeof FileService === 'undefined') return;
    var mts = monaco && monaco.languages && monaco.languages.typescript;
    if (!mts || !mts.javascriptDefaults) return;

    var programLoaded = FileService.getJsProgram
      ? FileService.getJsProgram().then(function (data) {
          if (!data || !data.ok || !data.files) return;
          data.files.forEach(function (f) {
            if (!f || typeof f.content !== 'string' || !f.path) return;
            programPaths[f.path] = true;
            mts.javascriptDefaults.addExtraLib(f.content, programUri(f.path));
          });
          if (data.skipped && data.skipped.length && window.console) {
            console.info('[mbeditor] ' + data.fileCount + ' source files (' +
              Math.round(data.totalBytes / 1024) + ' KB) in the TypeScript program; ' +
              data.skipped.length + ' skipped:', data.skipped);
          }
        }).catch(function () { /* fall through to ambient globals alone */ })
      : Promise.resolve();

    programLoaded.then(function () { loadWorkspaceGlobals(monaco); });
  }

  function loadWorkspaceGlobals(monaco) {
    if (typeof FileService === 'undefined' || !FileService.getJsGlobals) return;
    var mts = monaco && monaco.languages && monaco.languages.typescript;
    if (!mts || !mts.javascriptDefaults) return;
    FileService.getJsGlobals().then(function (data) {
      if (!data || !data.ok || !data.symbols) return;
      var names = [];
      data.symbols.forEach(function (s) {
        var name = s && s.name;
        if (!name || !/^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(name)) return;
        if (REACT_MINI_UMD_GLOBALS[name]) return;
        if (discoveredJsGlobals[name]) return; // already in discovered-globals.d.ts
        // The program already declares this one, with a real type.
        if (s.file && programPaths[s.file] && PROGRAM_VISIBLE_KINDS[s.kind]) {
          attemptedJsGlobals[name] = true;
          return;
        }
        names.push(name);
        // Pre-seed the reactive resolver so the marker patcher never fires a
        // per-symbol /js_definition request for these.
        attemptedJsGlobals[name] = true;
      });
      var decls = names.map(function (n) { return 'declare var ' + n + ': any;'; }).join('\n');
      mts.javascriptDefaults.addExtraLib(decls, 'inmemory://mbeditor/workspace-globals.d.ts');
    }).catch(function () { /* endpoint unavailable — reactive path still works */ });
  }

  // Incremental refresh: re-send only the files that changed, never the whole
  // tree. A workspace can be tens of MB, so re-fetching it on every save would
  // cost more than the feature is worth.
  function refreshProgramPaths(monaco, paths) {
    var mts = monaco && monaco.languages && monaco.languages.typescript;
    if (!mts || !mts.javascriptDefaults) return;
    if (typeof FileService === 'undefined' || !FileService.getJsProgramFile) return;
    (paths || []).forEach(function (path) {
      if (!path || !/\.(js|jsx|ts|tsx)$/i.test(path)) return;
      FileService.getJsProgramFile(path).then(function (data) {
        if (!data || !data.ok || !data.file) return;
        programPaths[data.file.path] = true;
        mts.javascriptDefaults.addExtraLib(data.file.content, programUri(data.file.path));
      }).catch(function () {});
    });
  }

  // Navigate to the first workspace definition of a JS symbol.
  // Returns a Promise<boolean> — true if a definition was found and opened.
  // Try the host's ruby-lsp (via the /ruby_lsp bridge) for a Ruby language
  // request. Resolves to the translated payload, or null whenever the legacy
  // grep/Ripper path should run instead: flag off, oversized buffer, HTTP
  // error, server-side fallback signal, or an empty result. A 422 means the
  // server has decided ruby-lsp is unavailable — flip the flag off so we stop
  // asking.
  // A Monaco marker's `code` is either a plain string or, when the backend
  // supplied a docs URL, a { value, target } object. Everything that compares
  // or displays a cop name has to go through this.
  function codeValue(code) {
    if (code && typeof code === 'object') return code.value || '';
    return code || '';
  }

  // How long a failure keeps us off ruby-lsp. Long enough that a dead server
  // isn't hammered on every keystroke, short enough that a server which comes
  // back on its own is picked up without a page reload — which is what the old
  // permanent flag flip cost you.
  var LSP_BACKOFF_MS = 60000;

  // Single owner of the "ruby-lsp is unwell" state. Everything that talks to
  // the bridge routes its failures here so the status indicator and the
  // request guard can never disagree.
  function noteLspFailure(err) {
    var status = err && err.response && err.response.status;
    var data = (err && err.response && err.response.data) || (err && err.lspData) || {};
    // A 422 means the server has decided ruby-lsp isn't there at all; a
    // 'failed' state means it crashed past its restart budget. Both are worth
    // backing off from. An ordinary timeout is not.
    if (status !== 422 && data.lspState !== 'failed') return;

    window.MBEDITOR_RUBY_LSP_DISABLED_UNTIL = Date.now() + LSP_BACKOFF_MS;
    window.MBEDITOR_RUBY_LSP_REASON = data.reason || data.error ||
      (data.lspState === 'failed' ? 'ruby-lsp crashed repeatedly' : 'ruby-lsp is unavailable');
    try {
      window.dispatchEvent(new CustomEvent('mbeditor:lsp-health'));
    } catch (e) { /* CustomEvent unavailable — the guard still works */ }
  }

  function lspBackedOff() {
    return Date.now() < (window.MBEDITOR_RUBY_LSP_DISABLED_UNTIL || 0);
  }

  function tryRubyLsp(lspMethod, model, position) {
    try {
      if (!window.MBEDITOR_RUBY_LSP_AVAILABLE || lspBackedOff()) return Promise.resolve(null);
      if (typeof FileService === 'undefined' || !FileService.rubyLspRequest) return Promise.resolve(null);
      if (!model || !model._mbeditorPath || !position) return Promise.resolve(null);
      if (model.getValueLength() > 5 * 1024 * 1024) return Promise.resolve(null);
      return FileService.rubyLspRequest(lspMethod, model._mbeditorPath, model.getValue(), position.lineNumber, position.column)
        .then(function (data) {
          if (!data || data.fallback || data.error) {
            // A 200 can still carry lspState: 'failed' — the server answered,
            // the language server did not.
            if (data) noteLspFailure({ lspData: data });
            return null;
          }
          if (lspMethod === 'definition') return (data.results && data.results.length) ? data : null;
          if (lspMethod === 'hover') return data.markdown ? data : null;
          if (lspMethod === 'completion') return (data.suggestions && data.suggestions.length) ? data : null;
          return null;
        })
        .catch(function (err) {
          noteLspFailure(err);
          return null;
        });
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  // Extract the parent object name for a word at a position, when the usage
  // is `Parent.word` or `const { ..., word, ... } = Parent`. Returns null for
  // plain references. The parent lets the backend resolve nested member
  // definitions instead of falling back to the (ranked) global search.
  // True when the position sits inside an ERB tag (<% ... %>, <%= ... %>).
  // Finds the nearest preceding delimiter: an opener means we're inside Ruby
  // code, a closer (or nothing) means we're in the HTML body. Correct across
  // multi-line blocks because it searches backwards through the whole buffer
  // rather than the current line.
  function isInsideErbTag(model, position) {
    if (!model || !position) return false;
    try {
      var match = model.findPreviousMatch('<%|%>', position, true, false, null, false);
      if (!match || !match.range) return false;
      // A match starting at/after the cursor wrapped around to the end of the
      // buffer — treat that as "no preceding delimiter".
      if (match.range.startLineNumber > position.lineNumber) return false;
      if (match.range.startLineNumber === position.lineNumber &&
          match.range.startColumn > position.column) return false;
      return model.getValueInRange(match.range).indexOf('<%') === 0;
    } catch (e) {
      return false;
    }
  }

  // Rails view helpers are defined inside the framework, not the workspace, so
  // looking them up from ERB only ever produces empty round-trips.
  var RAILS_VIEW_HELPERS = {
    link_to: 1, button_to: 1, form_with: 1, form_for: 1, form_tag: 1, fields_for: 1,
    render: 1, yield: 1, content_for: 1, content_tag: 1, tag: 1, url_for: 1,
    image_tag: 1, javascript_include_tag: 1, stylesheet_link_tag: 1, favicon_link_tag: 1,
    csrf_meta_tags: 1, csp_meta_tag: 1, asset_path: 1, image_path: 1,
    number_to_currency: 1, number_with_delimiter: 1, truncate: 1, pluralize: 1,
    time_ago_in_words: 1, distance_of_time_in_words: 1, simple_format: 1,
    sanitize: 1, raw: 1, escape_javascript: 1, j: 1, t: 1, l: 1,
    label_tag: 1, text_field_tag: 1, submit_tag: 1, hidden_field_tag: 1,
    check_box_tag: 1, select_tag: 1, options_for_select: 1
  };

  function extractJsParentContext(model, lineNumber, wordInfo) {
    if (!model || !wordInfo) return null;
    var line = model.getLineContent(lineNumber);

    // Dot form: SomeParent.word — back-walk the identifier before the dot.
    if (line[wordInfo.startColumn - 2] === '.') {
      var end = wordInfo.startColumn - 2; // index of the '.'
      var start = end;
      while (start > 0 && /[a-zA-Z0-9_$]/.test(line[start - 1])) start--;
      var parent = line.substring(start, end);
      // Reject call/index results like foo().word or foo[0].word — those
      // aren't a named parent object.
      if (parent && /^[a-zA-Z_$]/.test(parent) && (start === 0 || !/[)\]]/.test(line[start - 1]))) {
        return parent;
      }
      return null;
    }

    // Destructuring form: const { a, word, b } = SomeParent
    var m = line.match(/(?:const|let|var)\s*\{([^}]*)\}\s*=\s*([a-zA-Z_$][a-zA-Z0-9_$]*)/);
    if (m) {
      var braceStart = line.indexOf('{', m.index) + 2; // 1-based column after '{'
      var braceEnd = braceStart + m[1].length;
      if (wordInfo.startColumn >= braceStart && wordInfo.endColumn <= braceEnd + 1) {
        var names = m[1].split(',').map(function (seg) {
          // `source: alias` renames — the SOURCE property lives on the parent.
          return seg.split(':')[0].trim();
        });
        if (names.indexOf(wordInfo.word) !== -1) return m[2];
      }
    }
    return null;
  }

  function navigateToJsWord(editor, word, parent) {
    if (typeof FileService === 'undefined' || !FileService.getJsDefinition) return Promise.resolve(false);
    var currentPath = editor.getModel && editor.getModel() && editor.getModel()._mbeditorPath;
    return FileService.getJsDefinition(word, null, parent)
      .then(function(data) {
        var results = data && data.results;
        if (!results || !results.length) {
          if (isRuntimeWindowGlobal(word)) addDiscoveredGlobal(word);
          return false;
        }
        var r = results[0];
        // Only declare as a global when the definition is itself a top-level
        // (Sprockets-global) declaration in a different file. Nested/member
        // definitions must not get an ambient declare var.
        if (r.topLevel && r.file !== currentPath) addDiscoveredGlobal(word);
        if (typeof TabManager !== 'undefined' && TabManager.openTab) {
          TabManager.openTab(r.file, r.file.split('/').pop(), r.line);
        }
        return true;
      })
      .catch(function() { return false; });
  }

  function leadingWhitespace(line) {
    var match = line.match(/^\s*/);
    return match ? match[0] : '';
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function rubyIndentUnit(model, openerIndent) {
    // Trust the file over the model options: indentation auto-detection can
    // misreport tabs for files with little existing indentation, which would
    // insert a stray tab into a spaces file (or vice versa).
    if (openerIndent && openerIndent.indexOf('\t') !== -1) return '\t';
    var options = model.getOptions ? model.getOptions() : null;
    if (!openerIndent && options && options.insertSpaces === false) {
      return '\t';
    }
    var tabSize = options && options.tabSize ? options.tabSize : 4;
    return new Array(tabSize + 1).join(' ');
  }

  function rubyClosingIndent(model, cursorLineNumber, openerLine) {
    var cursorIndent = leadingWhitespace(model.getLineContent(cursorLineNumber));
    var indentUnit = rubyIndentUnit(model, cursorIndent);

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

  // Keywords that legitimately sit at the SAME indent as the opener while
  // still belonging to its block (if/else, case/when, begin/rescue...).
  var RUBY_MID_BLOCK_LINE = /^(else|elsif|when|in|rescue|ensure)\b/;

  function hasMatchingRubyEnd(model, openerLineNumber, openerIndent) {
    var lineCount = model.getLineCount();
    var openerIndentLength = openerIndent.length;

    for (var lineNumber = openerLineNumber + 1; lineNumber <= lineCount; lineNumber += 1) {
      var line = model.getLineContent(lineNumber);
      var trimmed = line.trim();
      if (!trimmed || trimmed[0] === '#') continue;

      var lineIndent = leadingWhitespace(line);
      var lineIndentLength = lineIndent.length;

      // Dedented code: the opener's block ended without an `end` of its own.
      if (lineIndentLength < openerIndentLength) return false;

      if (lineIndentLength === openerIndentLength) {
        if (RUBY_END_LINE.test(trimmed)) return true;
        if (RUBY_MID_BLOCK_LINE.test(trimmed)) continue;
        // Any other code at the opener's indent (e.g. a SIBLING `def` below
        // the insertion point) means the `end` found later belongs to that
        // sibling, not to the opener — the opener has no end yet.
        return false;
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

    var innerIndent = context.openerIndent + rubyIndentUnit(model, context.openerIndent);
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
    var jsGotoMouseDisposable = null;
    var jsGotoActionDisposable = null;

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

    // ERB gets the same Ruby navigation and auto-end, but only inside <% %>,
    // and always through the workspace services (ruby-lsp cannot parse ERB).
    if (language === 'ruby' || language === 'erb') {
      var isErbDoc = language === 'erb';
      var rubyContextAt = function (position) {
        return !isErbDoc || isInsideErbTag(model, position);
      };

      keydownDisposable = editor.onKeyDown(function (event) {
        if (event.keyCode !== window.monaco.KeyCode.Enter) return;
        if (!rubyContextAt(editor.getPosition())) return;
        if (!handleRubyEnter(editor, model)) return;

        event.preventDefault();
        event.stopPropagation();
      });

      // Navigate to a Ruby symbol: ruby-lsp first when available (accurate,
      // position-aware), else modules/classes go to their definition file and
      // lowercase symbols go to their def line via the grep/Ripper services.
      function legacyNavigateToWord(word) {
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

      function navigateToWord(word, position) {
        if (isErbDoc) return legacyNavigateToWord(word);

        tryRubyLsp('definition', model, position).then(function (lsp) {
          if (lsp && lsp.results && lsp.results.length) {
            var r = lsp.results[0];
            if (typeof TabManager !== 'undefined' && TabManager.openTab) {
              TabManager.openTab(r.file, r.file.split('/').pop(), r.line);
            }
            return;
          }
          legacyNavigateToWord(word);
        });
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
        if (isErbDoc && (!rubyContextAt(position) || RAILS_VIEW_HELPERS[wordInfo.word])) return;

        event.event.preventDefault();
        navigateToWord(wordInfo.word, position);
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
          if (isErbDoc && (!rubyContextAt(pos) || RAILS_VIEW_HELPERS[wordInfo.word])) return;
          navigateToWord(wordInfo.word, pos);
        }
      });
    }

    if (language === 'javascript') {
      // Ctrl/Cmd+click — look up workspace definition; fall back to Monaco's built-in.
      jsGotoMouseDisposable = editor.onMouseDown(function(event) {
        var ctrlOrCmd = event.event.ctrlKey || event.event.metaKey;
        if (!ctrlOrCmd) return;
        if (!event.target || event.target.type !== 6) return;
        var position = event.target.position;
        if (!position) return;
        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo || !wordInfo.word || wordInfo.word.length < 2) return;
        event.event.preventDefault();
        var parentCtx = extractJsParentContext(model, position.lineNumber, wordInfo);
        navigateToJsWord(editor, wordInfo.word, parentCtx).then(function(found) {
          if (!found) editor.trigger('', 'editor.action.revealDefinition', null);
        });
      });

      // F12 — go to JS definition from keyboard
      jsGotoActionDisposable = editor.addAction({
        id: 'mbeditor.gotoJsDefinition',
        label: 'Go to JS Definition',
        keybindings: [window.monaco.KeyCode.F12],
        precondition: 'editorLangId == javascript',
        contextMenuGroupId: 'navigation',
        contextMenuOrder: 1.5,
        run: function(ed) {
          var pos = ed.getPosition();
          if (!pos) return;
          var wordInfo = model.getWordAtPosition(pos);
          if (!wordInfo || !wordInfo.word || wordInfo.word.length < 2) return;
          var parentCtx = extractJsParentContext(model, pos.lineNumber, wordInfo);
          navigateToJsWord(ed, wordInfo.word, parentCtx).then(function(found) {
            if (!found) ed.trigger('', 'editor.action.revealDefinition', null);
          });
        }
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
        if (jsGotoMouseDisposable) jsGotoMouseDisposable.dispose();
        if (jsGotoActionDisposable) jsGotoActionDisposable.dispose();
        contentDisposable.dispose();
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
        // No diagnosticCodesToIgnore here on purpose: JS/JSX markers are
        // filtered by category in the marker patcher below (see JS_KEEP_CODES),
        // which is a closed rule rather than a list that grows by one code
        // every time a new false positive turns up.
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

    // ── React mini-UMD type declarations ────────────────────────────────────
    // A self-contained React + JSX type stub vendored locally so Monaco's
    // TypeScript language service has enough information to:
    //   • complete React hooks and lifecycle methods
    //   • resolve JSX element types (no "Cannot find name" for <div /> etc.)
    //   • navigate to component definitions on hover / Ctrl+Click
    // This replaces the bare `declare var React: any` that previously gave
    // Monaco no useful type information.
    var REACT_MINI_UMD_DTS = [
      '// React mini-UMD — mbeditor local type stub',
      'declare namespace React {',
      '  type Key = string | number;',
      '  type ReactText = string | number;',
      '  type ReactNode = ReactElement | ReactText | boolean | null | undefined | ReactNodeArray;',
      '  interface ReactNodeArray extends Array<ReactNode> {}',
      '  interface ReactElement<P = any> { type: any; props: P; key: Key | null; }',
      '  interface RefObject<T> { readonly current: T | null; }',
      '  type Ref<T> = RefObject<T> | ((instance: T | null) => void) | null;',
      '  interface MutableRefObject<T> { current: T; }',
      '  type FC<P = {}> = (props: P & { children?: ReactNode; key?: Key }) => ReactElement | null;',
      '  type FunctionComponent<P = {}> = FC<P>;',
      '  type ComponentType<P = {}> = FC<P>;',
      '  type DependencyList = ReadonlyArray<any>;',
      '  type EffectCallback = () => (void | (() => void | undefined));',
      '  type SetStateAction<S> = S | ((prevState: S) => S);',
      '  type Dispatch<A> = (value: A) => void;',
      '  type Reducer<S, A> = (prevState: S, action: A) => S;',
      '  interface Context<T> { Provider: FC<{ value: T; children?: ReactNode }>; Consumer: any; displayName?: string; }',
      '  class Component<P = {}, S = {}> {',
      '    constructor(props: Readonly<P>);',
      '    props: Readonly<P>;',
      '    state: Readonly<S>;',
      '    setState(state: SetStateAction<S>, cb?: () => void): void;',
      '    forceUpdate(cb?: () => void): void;',
      '    render(): ReactNode;',
      '    componentDidMount?(): void;',
      '    componentDidUpdate?(prevProps: Readonly<P>, prevState: Readonly<S>): void;',
      '    componentWillUnmount?(): void;',
      '  }',
      '  class PureComponent<P = {}, S = {}> extends Component<P, S> {}',
      '  function createElement(type: any, props?: any, ...children: any[]): ReactElement;',
      '  function cloneElement(element: ReactElement, props?: any, ...children: any[]): ReactElement;',
      '  function isValidElement(object: any): object is ReactElement;',
      '  function createContext<T>(defaultValue: T): Context<T>;',
      '  function forwardRef<T, P = {}>(render: (props: P, ref: Ref<T>) => ReactElement | null): FC<P & { ref?: Ref<T> }>;',
      '  function memo<P>(comp: FC<P>, compare?: (a: P, b: P) => boolean): FC<P>;',
      '  function lazy<T extends ComponentType<any>>(factory: () => Promise<{ default: T }>): T;',
      '  function useState<S>(initialState: S | (() => S)): [S, Dispatch<SetStateAction<S>>];',
      '  function useEffect(effect: EffectCallback, deps?: DependencyList): void;',
      '  function useLayoutEffect(effect: EffectCallback, deps?: DependencyList): void;',
      '  function useRef<T>(initialValue: T): MutableRefObject<T>;',
      '  function useRef<T>(initialValue: T | null): RefObject<T>;',
      '  function useRef<T = undefined>(): MutableRefObject<T | undefined>;',
      '  function useMemo<T>(factory: () => T, deps: DependencyList | undefined): T;',
      '  function useCallback<T extends (...args: any[]) => any>(callback: T, deps: DependencyList): T;',
      '  function useContext<T>(context: Context<T>): T;',
      '  function useReducer<S, A>(reducer: Reducer<S, A>, initialState: S): [S, Dispatch<A>];',
      '  function useImperativeHandle<T>(ref: Ref<T>, init: () => T, deps?: DependencyList): void;',
      '  function useDebugValue<T>(value: T, format?: (value: T) => any): void;',
      '  function useId(): string;',
      '  const Fragment: any;',
      '  const StrictMode: any;',
      '  const Suspense: FC<{ fallback?: ReactNode; children?: ReactNode }>;',
      '  const Children: { map<T,C>(children: any, fn: (child: C, index: number) => T): T[]; forEach(children: any, fn: (child: any, index: number) => void): void; count(children: any): number; toArray(children: any): any[]; only(children: any): ReactElement; };',
      '  const version: string;',
      '}',
      '',
      '// Allow `var React = window.React;` in host-app files without TS2300.',
      '// Using a namespace+var combo lets Monaco see the namespace members while',
      '// still accepting the runtime assignment pattern common in Sprockets apps.',
      'declare var React: typeof React;',
      '',
      '// ReactDOM global',
      'declare var ReactDOM: {',
      '  render(element: React.ReactElement, container: Element | null, cb?: () => void): any;',
      '  unmountComponentAtNode(container: Element): boolean;',
      '  createPortal(children: React.ReactNode, container: Element): React.ReactElement;',
      '  findDOMNode(instance: any): Element | null;',
      '};',
      '',
      '// JSX intrinsic elements — wildcard so any HTML tag is accepted.',
      '// Without this, TypeScript reports TS2339 / TS7026 for every <div> etc.',
      'declare namespace JSX {',
      '  interface Element extends React.ReactElement<any> {}',
      '  interface ElementClass { render(): React.ReactNode; }',
      '  interface ElementAttributesProperty { props: {}; }',
      '  interface ElementChildrenAttribute { children: {}; }',
      '  type LibraryManagedAttributes<C, P> = P;',
      '  interface IntrinsicElements { [elem: string]: any; }',
      '}',
      '',
      '// Other common Sprockets globals',
      'declare var PropTypes: any;',
      'declare var MaterialUI: any;',
      'declare var $: any;',
      'declare var jQuery: any;',
      'interface Window { [key: string]: any; }'
    ].join('\n');

    // Declare globals that are injected at runtime so checkJs doesn't flag them
    // as undefined. The buildWindowGlobalsShim() function automatically detects
    // window globals from the host application. Common Sprockets globals
    // (React, ReactDOM, etc.) are declared explicitly. For additional globals
    // not auto-detected, add `/* global MyComponent */` at the top of the file.
    if (monaco.languages.typescript && monaco.languages.typescript.javascriptDefaults) {
      monaco.languages.typescript.javascriptDefaults.addExtraLib(
        REACT_MINI_UMD_DTS,
        'inmemory://mbeditor/react-mini-umd.d.ts'
      );

      var dynamicShim = buildWindowGlobalsShim();
      if (dynamicShim) {
        monaco.languages.typescript.javascriptDefaults.addExtraLib(
          dynamicShim,
          'inmemory://mbeditor/window-globals.d.ts'
        );
      }

      // The workspace program (source files) plus the ambient globals it can't
      // supply, loaded once now.
      loadWorkspaceProgram(monaco);

      // On a change: refresh just the touched files' program entries, and
      // re-run the (cheap, cached) globals scan. The whole tree is never
      // re-sent — see refreshProgramPaths.
      var refreshWorkspaceGlobals = function () { loadWorkspaceGlobals(monaco); };
      if (window._ && window._.debounce) {
        refreshWorkspaceGlobals = window._.debounce(refreshWorkspaceGlobals, 2000);
      }
      if (typeof WebSocketService !== 'undefined' && WebSocketService.onFilesChanged) {
        WebSocketService.onFilesChanged(function (payload) {
          if (payload && payload.paths) refreshProgramPaths(monaco, payload.paths);
          refreshWorkspaceGlobals();
        });
      }
      var _lastGlobalsFocusRefresh = Date.now();
      window.addEventListener('focus', function () {
        if (Date.now() - _lastGlobalsFocusRefresh < 60000) return;
        _lastGlobalsFocusRefresh = Date.now();
        loadWorkspaceGlobals(monaco);
      });

      // Patch the TypeScript worker's markers after it fires.
      //
      // ── JS/JSX: keep only the diagnostics that are sound without types ──────
      // Plain JS/JSX is untyped, so every *type* diagnostic TypeScript emits is
      // an inference guess, and which way it guesses is arbitrary: state seeded
      // with `useState({})` infers `{}` and errors on every key, while the same
      // object from `JSON.parse` infers `any` and stays silent. Identical code,
      // opposite verdicts. Denylisting each false-positive code as it turned up
      // never converged — it reached eight codes and still leaked (2322 on a
      // spread with an extra prop), because the tail is every code TypeScript
      // has. So invert it: keep the categories below and drop the rest.
      //
      //   • syntax errors — always real. Their codes are 1xxx (and 17xxx for
      //     the JSX-specific ones, e.g. 17008 "no corresponding closing tag"),
      //     which is why the ranges rather than a code list are matched.
      //   • 2304 "Cannot find name" — scope resolution, not type checking.
      //     Downgraded to Warning below and auto-resolved against the workspace,
      //     since host-app globals are invisible to the language service.
      //   • 6133 "declared but never read" — a lint. Downgraded to Warning.
      //   • anything below Error severity — hints and suggestions render faint
      //     and cost nothing, so they pass through untouched.
      //
      // Deliberately dropped along with the type errors: 2300 "Duplicate
      // identifier" and 2403 "Subsequent variable declarations…", which are
      // structural false positives in the Sprockets model — every open file
      // shares one global script context, so a component in file_a.jsx looks
      // like a redeclaration once file_b.jsx is open, and the ambient
      // `declare var Foo: any` from workspace-globals.d.ts collides with the
      // real `function Foo()` when its defining file is open.
      //
      // .ts/.tsx keeps full checking: there the types are hand-written, so a
      // type error is a statement about code the author actually wrote.
      var JS_KEEP_CODES  = { '2304': true, '6133': true };
      var JS_SYNTAX_CODE = /^(?:1\d{3}|17\d{3})$/;
      var JS_WARN_CODES  = { '2304': true, '6133': true };
      var TS_WARN_CODES  = { '6133': true };

      function keepJsMarker(marker) {
        if (marker.severity !== monaco.MarkerSeverity.Error) return true;
        var code = String(marker.code == null ? '' : marker.code);
        return JS_KEEP_CODES[code] === true || JS_SYNTAX_CODE.test(code);
      }

      var _severityPatchActive = false;
      monaco.editor.onDidChangeMarkers(function(uris) {
        if (_severityPatchActive) return;
        _severityPatchActive = true;
        try {
          uris.forEach(function(uri) {
            var model = monaco.editor.getModel(uri);
            if (!model) return;
            [
              { owner: 'javascript', keep: keepJsMarker, warn: JS_WARN_CODES },
              { owner: 'typescript', keep: null,         warn: TS_WARN_CODES }
            ].forEach(function(entry) {
              var markers = monaco.editor.getModelMarkers({ resource: uri, owner: entry.owner });
              var patched = markers.filter(function(m) {
                return entry.keep ? entry.keep(m) : true;
              }).map(function(m) {
                return (m.severity === monaco.MarkerSeverity.Error && entry.warn[String(m.code)])
                  ? Object.assign({}, m, { severity: monaco.MarkerSeverity.Warning })
                  : m;
              });
              // Re-applying an unchanged set would re-enter this handler
              // forever, so only write when the patch actually changed something.
              var changed = patched.length !== markers.length || patched.some(function(m, i) {
                return m.severity !== markers[i].severity;
              });
              if (changed) monaco.editor.setModelMarkers(model, entry.owner, patched);
            });
          });
        } finally {
          _severityPatchActive = false;
        }

        // Auto-resolve TS2304 ("Cannot find name 'X'") for JS files by
        // looking up the symbol in the workspace. If found, addDiscoveredGlobal
        // declares it via addExtraLib and Monaco re-validates, removing the warning.
        if (typeof FileService !== 'undefined' && FileService.getJsDefinition) {
          uris.forEach(function(uri) {
            var model = monaco.editor.getModel(uri);
            if (!model) return;
            var markers = monaco.editor.getModelMarkers({ resource: uri, owner: 'javascript' });
            markers.forEach(function(m) {
              if (String(m.code) !== '2304') return;
              // Extract symbol name from message: "Cannot find name 'ReactWindow'."
              var match = m.message && m.message.match(/Cannot find name '([^']+)'/);
              if (!match) return;
              var sym = match[1];
              if (attemptedJsGlobals[sym]) return;
              attemptedJsGlobals[sym] = true;
              queueJsGlobalLookup(sym, model._mbeditorPath);
            });
          });
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

          // Heredoc start — capture the terminator word; route to specialized state by delimiter name
          [/<<[-~]?(['"]?)(\w+)\1/, {
            cases: {
              '$2~(?i:SQL)':        { token: 'string.heredoc.delimiter', next: '@heredocSQL.$2' },
              '$2~(?i:HTML?)':      { token: 'string.heredoc.delimiter', next: '@heredocHTML.$2' },
              '$2~(?i:JS|JAVASCRIPT)': { token: 'string.heredoc.delimiter', next: '@heredocJS.$2' },
              '@default':           { token: 'string.heredoc.delimiter', next: '@heredoc.$2' }
            }
          }],

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

          // Test DSL suites, runnable examples, hooks, and helpers
          [/\b(describe|context|feature)(?![a-zA-Z0-9_!?=])/, 'keyword.control.test'],
          [/\b(test|it|specify|example|scenario)(?![a-zA-Z0-9_!?=])/, 'entity.name.function.test'],
          [/\b(setup|teardown|before|after|around|subject)(?![a-zA-Z0-9_!?=])/, 'support.function.test'],
          [/\blet!?(?=\s|\()/, 'support.function.test'],

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

          // Regexp literals: /pat/imxo
          // Negative lookbehind (?<![.\w]) prevents matching division operators like a/b or obj.method/n
          [/(?<![.\w])\/(?!\s)(?:[^\/\\\n]|\\.)+\/[imxo]*/, 'string.regexp'],

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

        // Generic heredoc — all content is string.heredoc
        heredoc: [
          [/^(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': 'string.heredoc'
            }
          }],
          [/.+/, 'string.heredoc']
        ],

        // SQL heredoc — keyword/string/number/comment tokenization
        heredocSQL: [
          [/^(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': { token: '@rematch', next: '@heredocSQLLine' }
            }
          }],
          [/.+/, { token: '@rematch', next: '@heredocSQLLine' }]
        ],

        heredocSQLLine: [
          [/--.*$/, { token: 'comment.sql', next: '@pop' }],
          [/'[^']*'/, 'string.sql'],
          [/\b\d+(?:\.\d+)?\b/, 'number.sql'],
          [/\b(?:SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|GROUP|ORDER|BY|HAVING|LIMIT|OFFSET|CREATE|DROP|ALTER|TABLE|INDEX|INTO|VALUES|SET|AS|AND|OR|NOT|NULL|IS|IN|LIKE|BETWEEN|DISTINCT|COUNT|SUM|AVG|MIN|MAX)\b/i, 'keyword.sql'],
          [/[^\s\w'"-]+/, 'string.heredoc'],
          [/\w+/, 'string.heredoc'],
          [/$/, { token: '', next: '@pop' }]
        ],

        // HTML heredoc — tag/attribute tokenization
        heredocHTML: [
          [/^(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': { token: '@rematch', next: '@heredocHTMLLine' }
            }
          }],
          [/.+/, { token: '@rematch', next: '@heredocHTMLLine' }]
        ],

        heredocHTMLLine: [
          [/<\/?[a-zA-Z][a-zA-Z0-9]*/, 'tag.html'],
          [/[a-zA-Z_:][a-zA-Z0-9_:\-\.]*(?=\s*=)/, 'attribute.name.html'],
          [/\/?>/, 'tag.html'],
          [/[^<>]+/, 'string.heredoc'],
          [/$/, { token: '', next: '@pop' }]
        ],

        // JS heredoc — keyword/string/number/comment tokenization
        heredocJS: [
          [/^(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': { token: '@rematch', next: '@heredocJSLine' }
            }
          }],
          [/.+/, { token: '@rematch', next: '@heredocJSLine' }]
        ],

        heredocJSLine: [
          [/\/\/.*$/, { token: 'comment', next: '@pop' }],
          [/"(?:[^"\\]|\\.)*"/, 'string'],
          [/'(?:[^'\\]|\\.)*'/, 'string'],
          [/`(?:[^`\\]|\\.)*`/, 'string'],
          [/\b\d+(?:\.\d+)?\b/, 'number'],
          [/\b(?:var|let|const|function|return|if|else|for|while|do|switch|case|break|continue|new|delete|typeof|instanceof|in|of|class|extends|import|export|default|null|undefined|true|false|this|super|async|await|try|catch|finally|throw|void|yield)\b/, 'keyword'],
          [/[^\s\w'"`;\/]+/, 'string.heredoc'],
          [/\w+/, 'string.heredoc'],
          [/$/, { token: '', next: '@pop' }]
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
          var cop = codeValue(m.code);
          return m.source === 'rubocop' && cop && correctableCops.has(cop);
        });

        if (rubocopMarkers.length === 0) return { actions: [], dispose: function() {} };

        var modelPath = model._mbeditorPath || null;
        if (!modelPath) return { actions: [], dispose: function() {} };

        var code = model.getValue();

        var actions = rubocopMarkers.map(function(marker) {
          var cop = codeValue(marker.code);
          return {
            title: 'Fix: ' + cop,
            kind: 'quickfix',
            isPreferred: rubocopMarkers.length === 1,
            diagnostics: [marker],
            command: {
              id: 'mbeditor.applyRubocopFix',
              title: 'Apply RuboCop fix for ' + cop,
              arguments: [model, cop, code, modelPath]
            }
          };
        });

        return { actions: actions, dispose: function() {} };
      }
    });

    // Command handler that fetches the fix from the backend and applies it.
    monaco.editor.registerCommand('mbeditor.applyRubocopFix', function(_accessor, model, copName, code, modelPath) {
      if (typeof FileService === 'undefined' || !FileService.quickFixOffense) return;
      FileService.quickFixOffense(modelPath, code, copName).then(function(data) {
        if (!data || !data.fix) return;
        var fix = data.fix;
        model.pushEditOperations([], [{
          range: new monaco.Range(fix.startLine, fix.startCol, fix.endLine, fix.endCol),
          text: fix.replacement
        }], function() { return null; });
      }).catch(function() {});
    });

    // Target of the command links the backend rewrites ruby-lsp's file://
    // "Definitions" links into (see EditorsController#rewrite_lsp_hover_links).
    monaco.editor.registerCommand('mbeditor.openDefinition', function(_accessor, path, line) {
      if (!path) return;
      if (typeof TabManager === 'undefined' || !TabManager.openTab) return;
      TabManager.openTab(path, String(path).split('/').pop(), line || 1);
    });

    // Ruby method definition hover provider.
    // Calls the backend /definition endpoint (Ripper-based) and renders
    // the method signature and any preceding # comments as hover markdown.
    // Results are cached client-side for 60 s to make re-hovers instantaneous.
    var hoverCache = {};
    var HOVER_CACHE_TTL_MS = 60000;
    var HOVER_MEMBER_LIMIT = 20;

    // ruby-lsp's hover for a constant is a title, a Definitions link and any
    // doc comments — it never lists what the class/module defines. Keep the
    // /module_members breakdown that the legacy hover showed, appended below.
    // Resolves to '' (never rejects) for anything that isn't a constant.
    function moduleMembersMarkdown(word) {
      if (!/^[A-Z]/.test(word)) return Promise.resolve('');
      if (typeof FileService === 'undefined' || !FileService.getModuleMembers) return Promise.resolve('');

      var key = '__members__' + word;
      var cached = hoverCache[key];
      if (cached && (Date.now() - cached.ts) < HOVER_CACHE_TTL_MS) return Promise.resolve(cached.markdown);

      return FileService.getModuleMembers(word, {}).then(function(data) {
        var methods = (data && data.methods) || [];
        var markdown = '';
        if (methods.length > 0) {
          var lines = ['', '---', '**Methods**', ''];
          methods.slice(0, HOVER_MEMBER_LIMIT).forEach(function(m) {
            lines.push('- `' + (m.signature || m.name) + '`');
          });
          if (methods.length > HOVER_MEMBER_LIMIT) {
            lines.push('- _' + (methods.length - HOVER_MEMBER_LIMIT) + ' more_');
          }
          markdown = '\n\n' + lines.join('\n');
        }
        hoverCache[key] = { ts: Date.now(), markdown: markdown };
        return markdown;
      }).catch(function() { return ''; });
    }

    // Registered for 'erb' as well as 'ruby'. In ERB the provider only fires
    // inside <% %> and always uses the workspace (grep/Ripper) services:
    // ruby-lsp is told every document is Ruby, and Prism cannot parse ERB.
    ['ruby', 'erb'].forEach(function (lang) {
    monaco.languages.registerHoverProvider(lang, {
      provideHover: function provideHover(model, position, token) {
        var isErb = lang === 'erb';
        if (isErb && !isInsideErbTag(model, position)) return null;

        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo) return null;

        var word = wordInfo.word;
        if (!word || word.length < 2) return null;
        if (RUBY_KEYWORDS[word]) return null;
        if (RUBY_CORE_METHODS[word]) return null;
        if (isErb && RAILS_VIEW_HELPERS[word]) return null;
        if (typeof FileService === 'undefined' || !FileService.getDefinition) return null;

        // ruby-lsp first: accurate, position-aware documentation. The LSP
        // hover cache is keyed by location, not just word — the same method
        // name can mean different things at different positions.
        if (!isErb && window.MBEDITOR_RUBY_LSP_AVAILABLE) {
          var lspKey = '__lsp__' + (model._mbeditorPath || '') + ':' + position.lineNumber + ':' + word;
          var lspCached = hoverCache[lspKey];
          if (lspCached && (Date.now() - lspCached.ts) < HOVER_CACHE_TTL_MS) {
            if (lspCached.result) return lspCached.result;
            // Cached LSP miss — fall through to the legacy paths below.
          } else {
            return tryRubyLsp('hover', model, position).then(function (lsp) {
              if (token && token.isCancellationRequested) return null;
              if (lsp && lsp.markdown) {
                return moduleMembersMarkdown(word).then(function (members) {
                  if (token && token.isCancellationRequested) return null;
                  var lspResult = {
                    range: new monaco.Range(position.lineNumber, wordInfo.startColumn, position.lineNumber, wordInfo.endColumn),
                    contents: [{ value: lsp.markdown + members, isTrusted: true }]
                  };
                  hoverCache[lspKey] = { ts: Date.now(), result: lspResult };
                  return lspResult;
                });
              }
              hoverCache[lspKey] = { ts: Date.now(), result: null };
              return legacyRubyHover(model, position, token, wordInfo);
            });
          }
        }

        return legacyRubyHover(model, position, token, wordInfo);
      }
    });
    });

    function legacyRubyHover(model, position, token, wordInfo) {
      var word = wordInfo.word;
      {
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
    }

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

    // Map server-translated LSP completion items to Monaco suggestion objects.
    function mapLspCompletionSuggestions(suggestions) {
      return {
        suggestions: suggestions.map(function (s) {
          var kind = monaco.languages.CompletionItemKind[s.kind];
          var item = {
            label: s.label,
            kind: kind != null ? kind : monaco.languages.CompletionItemKind.Text,
            detail: s.detail || '',
            insertText: s.insertText || s.label
          };
          if (s.isSnippet) {
            item.insertTextRules = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet;
          }
          return item;
        })
      };
    }

    ['ruby', 'erb'].forEach(function (lang) {
    monaco.languages.registerCompletionItemProvider(lang, {
      triggerCharacters: ['.'],
      provideCompletionItems: function(model, position) {
        var isErb = lang === 'erb';
        // In ERB only complete inside <% %>, and only from the workspace
        // services — ruby-lsp can't parse an ERB document.
        if (isErb) {
          if (!isInsideErbTag(model, position)) return { suggestions: [] };
          return legacyRubyCompletions(model, position);
        }

        // ruby-lsp first — real scope-aware completions; the include-based
        // provider below stays as the fallback.
        if (window.MBEDITOR_RUBY_LSP_AVAILABLE) {
          return tryRubyLsp('completion', model, position).then(function (lsp) {
            if (lsp && lsp.suggestions && lsp.suggestions.length) {
              return mapLspCompletionSuggestions(lsp.suggestions);
            }
            return legacyRubyCompletions(model, position);
          });
        }
        return legacyRubyCompletions(model, position);
      }
    });
    });

    function legacyRubyCompletions(model, position) {
      {
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
    }

    // JS/JSX hover provider: looks up workspace definitions for window globals.
    // Fires for mixed-case identifiers and for any symbol already in discoveredJsGlobals.
    var JS_HOVER_CACHE_TTL_MS = 60000;
    monaco.languages.registerHoverProvider('javascript', {
      provideHover: function(model, position, token) {
        var wordInfo = model.getWordAtPosition(position);
        if (!wordInfo || !wordInfo.word || wordInfo.word.length < 2) return null;
        var word = wordInfo.word;
        if (!discoveredJsGlobals[word] && !/[A-Z]/.test(word)) return null;
        if (typeof FileService === 'undefined' || !FileService.getJsDefinition) return null;

        // Build a position-specific range for this hover instance.
        // The range must NOT be cached because the same symbol can appear on
        // different lines; a stale cached lineNumber would highlight the wrong place.
        function makeHoverRange() {
          return new monaco.Range(position.lineNumber, wordInfo.startColumn, position.lineNumber, wordInfo.endColumn);
        }

        var parentCtx = extractJsParentContext(model, position.lineNumber, wordInfo);
        // Parent-qualified hovers cache separately: Parent.myFunction and a
        // bare myFunction can resolve to different definitions.
        var cacheKey = (parentCtx ? parentCtx + '.' : '') + word;
        var cached = jsHoverCache[cacheKey];
        if (cached && (Date.now() - cached.ts) < JS_HOVER_CACHE_TTL_MS) {
          if (!cached.contents) return null;
          return { range: makeHoverRange(), contents: cached.contents };
        }

        var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        if (controller && token && token.onCancellationRequested) {
          token.onCancellationRequested(function() { controller.abort(); });
        }
        return FileService.getJsDefinition(word, controller ? { signal: controller.signal } : {}, parentCtx)
          .then(function(data) {
            if (token && token.isCancellationRequested) return null;
            var results = data && data.results;
            if (!results || !results.length) {
              if (isRuntimeWindowGlobal(word)) {
                addDiscoveredGlobal(word);
                var kind = typeof window[word];
                var rtContents = [{ value: '**' + word + '** — runtime global (`' + kind + '`)' }];
                jsHoverCache[cacheKey] = { ts: Date.now(), contents: rtContents };
                return { range: makeHoverRange(), contents: rtContents };
              }
              jsHoverCache[cacheKey] = { ts: Date.now(), contents: null };
              return null;
            }
            var r = results[0];
            // Only declare as global when the definition is a top-level
            // (Sprockets-global) declaration in a different file — nested and
            // member definitions must not get a duplicate declare var.
            if (r.topLevel && r.file !== model._mbeditorPath) addDiscoveredGlobal(word);
            var fileRef = r.file + ':' + r.line;
            var contents = [
              { value: '```javascript\n' + r.snippet + '\n```', isTrusted: true },
              { value: '<span style="opacity:0.55;font-size:0.9em;">' + fileRef + '</span>', isTrusted: true, supportHtml: true }
            ];
            jsHoverCache[cacheKey] = { ts: Date.now(), contents: contents };
            return { range: makeHoverRange(), contents: contents };
          }).catch(function() { return null; });
      }
    });

    // JS/JSX member completion provider: suggests properties/methods of workspace globals after '.'.
    // Only looks up PascalCase/mixed-case identifiers or previously discovered globals.
    var JS_MEMBERS_CACHE_TTL_MS = 60000;
    monaco.languages.registerCompletionItemProvider('javascript', {
      triggerCharacters: ['.'],
      provideCompletionItems: function(model, position) {
        var line = model.getLineContent(position.lineNumber);
        var col  = position.column - 2; // index of character just before the '.'
        var end  = col;
        while (col >= 0 && /[a-zA-Z0-9_$]/.test(line[col])) col--;
        var symbol = line.slice(col + 1, end + 1);
        if (!symbol || symbol.length < 2) return { suggestions: [] };
        if (!discoveredJsGlobals[symbol] && !/^[A-Z]/.test(symbol)) return { suggestions: [] };
        if (typeof FileService === 'undefined' || !FileService.getJsMembers) return { suggestions: [] };

        var cached = jsMembersCache[symbol];
        if (cached && (Date.now() - cached.ts) < JS_MEMBERS_CACHE_TTL_MS) {
          return { suggestions: cached.suggestions };
        }

        return FileService.getJsMembers(symbol)
          .then(function(data) {
            var members = (data && data.members) || [];
            var suggestions = members.map(function(m) {
              return {
                label: m.name,
                kind: monaco.languages.CompletionItemKind.Method,
                detail: symbol,
                documentation: m.snippet,
                insertText: m.name,
                range: {
                  startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
                  startColumn: position.column, endColumn: position.column
                }
              };
            });
            jsMembersCache[symbol] = { ts: Date.now(), suggestions: suggestions };
            return { suggestions: suggestions };
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
    // The one place that decides ruby-lsp is unwell. Anything outside this file
    // that talks to the bridge reports its failures here rather than writing
    // the window flags itself.
    noteLspFailure: noteLspFailure,
    lspBackedOff: lspBackedOff,
    // Exposed so the ERB gating can be asserted directly in system tests.
    isInsideErbTag: isInsideErbTag,
    runRubyEnter: function runRubyEnter(editor) {
      if (!editor || !editor.getModel) return false;
      return handleRubyEnter(editor, editor.getModel());
    }
  };
})();
