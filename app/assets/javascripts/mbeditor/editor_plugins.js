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

  // Symbols the workspace lookup came back empty on — a component or variable
  // that genuinely does not exist. Their TS2304 is graded Error rather than
  // Warning: "Cannot find name" is only ever a guess until the lookup answers,
  // because host-app globals are invisible to the language service, but once
  // it has answered there is nothing tentative left about it.
  //
  // Held per page rather than per model: the answer is about the workspace,
  // and every open file referencing the name is equally wrong.
  var unknownJsSymbols = {};
  // Assigned by registerGlobalExtensions, which owns the marker rules. A
  // negative lookup changes no model and no extra lib, so nothing would
  // re-fire onDidChangeMarkers on its own and the grade would not be applied
  // until the next keystroke.
  var repatchJsMarkerSeverities = null;
  var _unknownRepatchTimer = null;

  function noteUnknownJsSymbol(sym) {
    if (unknownJsSymbols[sym]) return;
    unknownJsSymbols[sym] = true;
    // Coalesced for the same reason addExtraLib is: a file full of unknown
    // names resolves them one after another, and re-grading every open model
    // per answer is the same wasted pass repeated.
    if (_unknownRepatchTimer) return;
    _unknownRepatchTimer = setTimeout(function () {
      _unknownRepatchTimer = null;
      if (repatchJsMarkerSeverities) repatchJsMarkerSeverities();
    }, 300);
  }

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
        var hit = results && results[0];
        // `topLevel` matters, and its absence was a hole: any match anywhere
        // counted, so a `var x` nested inside a function in an unrelated file
        // earned `x` an ambient `declare var` and the reference here stopped
        // being reported at all. A local in another file is not in scope in
        // this one. The hover and goto-definition paths always required
        // top-level; this one is now consistent with them.
        if (hit && hit.topLevel && hit.file !== job.modelPath) {
          addDiscoveredGlobal(job.sym);
        } else if (isRuntimeWindowGlobal(job.sym)) {
          addDiscoveredGlobal(job.sym);
        } else {
          // Nothing declares this name: not the TypeScript program, not the
          // workspace globals, not a top-level definition anywhere on disk,
          // not a live window property. The answer is in — it does not exist.
          noteUnknownJsSymbol(job.sym);
        }
      })
      .then(done, done);
  }

  function queueJsGlobalLookup(sym, modelPath) {
    if (jsLookupQueue.length >= JS_LOOKUP_QUEUE_MAX) return;
    // Marked here rather than at the call site: marking before the cap check
    // spent the symbol's one attempt on a job that was then dropped, so a name
    // unlucky enough to arrive while the queue was full was never looked up at
    // all — not on the next keystroke, not for the rest of the page's life.
    attemptedJsGlobals[sym] = true;
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
        // This name exists now, whatever an earlier lookup concluded. Writing
        // the component you were being told was missing is the normal way that
        // happens, and the verdict has to expire with the evidence — this list
        // is refreshed on every files_changed.
        delete unknownJsSymbols[name];
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
    var wanted = (paths || []).filter(function (path) {
      return path && /\.(js|jsx|ts|tsx)$/i.test(path);
    });
    if (!wanted.length) return;

    // Collected first, applied in one synchronous pass. addExtraLib invalidates
    // the TypeScript worker and re-validates every open model, so applying a
    // burst of saves one response at a time paid that cost per file — the same
    // reason flushDiscoveredGlobals coalesces.
    Promise.all(wanted.map(function (path) {
      return FileService.getJsProgramFile(path).catch(function () { return null; });
    })).then(function (responses) {
      responses.forEach(function (data) {
        if (!data || !data.ok || !data.file) return;
        programPaths[data.file.path] = true;
        mts.javascriptDefaults.addExtraLib(data.file.content, programUri(data.file.path));
      });
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

  // Identifies a marker across both the backend shape (copName/startLine) and
  // the Monaco shape (code/startLineNumber), so the code-action provider can
  // find the fixes belonging to the marker it was handed. Cop name alone won't
  // do — the same cop fires many times in a file.
  function markerFixKey(m) {
    var cop = m.copName !== undefined ? m.copName : codeValue(m.code);
    var line = m.startLine !== undefined ? m.startLine : m.startLineNumber;
    var col = m.startCol !== undefined ? m.startCol : m.startColumn;
    return cop + ':' + line + ':' + col;
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

  // Raw-passthrough LSP methods keep their 0-based ranges on the wire; these
  // two put them back into Monaco's 1-based world at the provider.
  function lspRange(r) {
    if (!r) return new window.monaco.Range(1, 1, 1, 1);
    return new window.monaco.Range(
      (r.start && r.start.line || 0) + 1,
      (r.start && r.start.character || 0) + 1,
      (r.end && r.end.line || r.start && r.start.line || 0) + 1,
      (r.end && r.end.character || r.start && r.start.character || 0) + 1
    );
  }

  // The backend rewrites every in-workspace file:// URI to a relative path and
  // drops the rest, so what arrives here is always workspace-relative. Monaco
  // needs an absolute-looking URI, and registerEditorOpener maps it back.
  function lspUri(relativePath) {
    return window.monaco.Uri.parse('file:///' + String(relativePath).replace(/^\/+/, ''));
  }

  // Send a raw-passthrough request and hand back result.result, or null when
  // the legacy path should run instead.
  function rawRubyLsp(lspMethod, model, position, token) {
    return tryRubyLsp(lspMethod, model, position || { lineNumber: 1, column: 1 }, null, token);
  }

  // Requests that go through RuboCop rather than just Prism need more than the
  // 6s default: the server's own budget for them is 10s.
  var LSP_SLOW_METHODS = { diagnostics: 15000, formatting: 15000 };

  // `token` is Monaco's CancellationToken, when the calling provider has one.
  // Every provider fires on a gesture the user can abandon — moving the cursor
  // off a word, typing another character — and Monaco cancels the outstanding
  // request when that happens. Without this the request ran to completion
  // anyway: a subprocess on the server, and the answer thrown away here.
  function tryRubyLsp(lspMethod, model, position, extraBody, token) {
    try {
      if (!window.MBEDITOR_RUBY_LSP_AVAILABLE || lspBackedOff()) return Promise.resolve(null);
      if (typeof FileService === 'undefined' || !FileService.rubyLspRequest) return Promise.resolve(null);
      if (!model || !model._mbeditorPath || !position) return Promise.resolve(null);
      if (model.getValueLength() > 5 * 1024 * 1024) return Promise.resolve(null);
      // Nothing in the buffer means nothing to fold, outline, highlight or
      // resolve, so every one of these is a round trip that can only come back
      // empty. A newly created file is opened while empty, so this is the
      // common case rather than an edge one. null is already this function's
      // "no result" answer, so callers need no change.
      if (model.getValueLength() === 0) return Promise.resolve(null);
      if (token && token.isCancellationRequested) return Promise.resolve(null);

      var config = LSP_SLOW_METHODS[lspMethod] ? { timeout: LSP_SLOW_METHODS[lspMethod] } : null;
      var controller = (token && typeof AbortController !== 'undefined') ? new AbortController() : null;
      var cancelSub = null;
      if (controller && token.onCancellationRequested) {
        cancelSub = token.onCancellationRequested(function () { controller.abort(); });
        config = Object.assign({}, config, { signal: controller.signal });
      }

      return FileService.rubyLspRequest(lspMethod, model._mbeditorPath, model.getValue(),
                                        position.lineNumber, position.column, config, extraBody)
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
          // Raw-passthrough methods answer with { result: <LSP JSON> }. An
          // empty array is a real answer ("no references here"), not a reason
          // to fall back, so only a missing key counts as nothing.
          if (data.result !== undefined) return data.result;
          return null;
        })
        .catch(function (err) {
          noteLspFailure(err);
          return null;
        })
        // Settled either way: drop the cancellation listener (Monaco's token
        // outlives the request) and answer nothing to a cancelled caller.
        .then(function (result) {
          if (cancelSub && cancelSub.dispose) cancelSub.dispose();
          return (token && token.isCancellationRequested) ? null : result;
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

  // The definition in the file you are already in wins. Sprockets puts every
  // top-level name in one global scope, so the same helper defined in two
  // files is ordinary rather than exceptional — and the server returns them in
  // scan order, which is alphabetical by path and has nothing to do with which
  // one you meant. Taking the first sent you to whichever file happened to
  // sort earliest: Monaco's own provider would reveal the local definition,
  // then this lookup landed and navigated away from it.
  function preferCurrentFile(results, currentPath) {
    if (!currentPath) return null;
    for (var i = 0; i < results.length; i++) {
      if (results[i].file === currentPath) return results[i];
    }
    return null;
  }

  // Candidates for the peek list, one entry per file. Several hits in the same
  // file are the same answer as far as "which file did you mean" goes, and a
  // picker that lists the same path three times is a worse question.
  function distinctByFile(results) {
    var seen = Object.create(null);
    var out = [];
    results.forEach(function (r) {
      if (seen[r.file]) return;
      seen[r.file] = true;
      out.push(r);
    });
    return out;
  }

  // Monaco's peek list is fed by a DefinitionProvider, and it does NOT dedupe
  // across providers — measured: a provider returning the same location the
  // TypeScript worker resolves turns an ordinary local jump into a two-entry
  // picker for one definition. So this provider stays silent except for the
  // one case that actually needs it, which navigateToJsWord hands over here
  // immediately before asking Monaco to reveal.
  var pendingJsDefinitionPeek = null;

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
        var here = preferCurrentFile(results, currentPath);
        var elsewhere = distinctByFile(results.filter(function (x) { return x.file !== currentPath; }));

        // Defined right here: that is the answer, and asking which one you
        // meant would be noise.
        var r = here || elsewhere[0];
        // Only declare as a global when the definition is itself a top-level
        // (Sprockets-global) declaration in a different file. Nested/member
        // definitions must not get an ambient declare var.
        if (r.topLevel && r.file !== currentPath) addDiscoveredGlobal(word);

        // Genuinely ambiguous — the same name declared at top level in more
        // than one other file — so choose rather than guess.
        if (!here && elsewhere.length > 1) {
          // Stamped with the model and cursor position the reveal below will
          // ask about, so a candidate list whose reveal never fired cannot
          // surface on an unrelated gesture later.
          var gestureModel = editor.getModel && editor.getModel();
          var gesturePos = editor.getPosition && editor.getPosition();
          pendingJsDefinitionPeek = {
            uri: gestureModel ? gestureModel.uri.toString() : '',
            lineNumber: gesturePos ? gesturePos.lineNumber : 0,
            column: gesturePos ? gesturePos.column : 0,
            locations: elsewhere.map(function (x) {
              return {
                uri: lspUri(x.file),
                range: new window.monaco.Range(x.line || 1, 1, x.line || 1, 1)
              };
            })
          };
          editor.trigger('mbeditor', 'editor.action.revealDefinition', null);
          return true;
        }

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

      // Go-to-definition is a global DefinitionProvider (registered in
      // registerGlobalExtensions), not wired per editor. Monaco owns Ctrl+click,
      // F12, Alt+F12 peek and the Ctrl+hover preview from that one registration.
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

    // ── Paste is left alone, deliberately ────────────────────────────────────
    //
    // There was an indent-on-paste handler here that ran
    // `editor.action.reindentselectedlines` over the pasted range. It did not
    // adjust the paste — it recomputed every line's indent from the language's
    // indentation rules, which model bracket depth and nothing else. Any
    // structure those rules cannot derive was therefore destroyed on arrival:
    //
    //     <Row>            pasted        <Row>
    //       <Cell a={1} />    ────►      <Cell a={1} />
    //       <Cell b={2} />                <Cell b={2} />
    //     </Row>                         </Row>
    //
    // JSX nesting flattened; the same happened to method chains, ternaries and
    // wrapped arguments. It was right only for brace-structured code, which in
    // a React codebase is the minority of what gets pasted.
    //
    // Preserving what was copied is what every other editor does by default,
    // and it is never destructive: the worst case is a block at the wrong
    // depth, which Tab / Shift+Tab on the still-selected paste fixes, and
    // Format fixes properly. Monaco's own `formatOnPaste` stays off too
    // (EditorPanel passes false) — its contribution declines to run here.
    return {
      dispose: function dispose() {
        if (keydownDisposable) keydownDisposable.dispose();
        if (emmetTabDisposable) emmetTabDisposable.dispose();
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
        // Suggestion diagnostics are TypeScript's advice to a TypeScript
        // author: nearly all of them on plain JS/JSX are 7044, "Parameter 'x'
        // implicitly has an 'any' type, but a better type may be inferred from
        // usage" — one per untyped parameter in the file, in a language that
        // has no types to annotate. They arrive as Hint/Info, which the marker
        // patcher below never inspected (it only ever filtered Errors), so
        // every one of them reached the Problems panel. Semantic and syntax
        // checking, which is what actually catches mistakes here, stay on.
        noSuggestionDiagnostics: true
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
      // Hand JS formatting to Prettier alone.
      //
      // The TypeScript worker registers its own range formatter for
      // 'javascript', and Monaco consults whichever provider it finds first.
      // That gave one file two formatters that disagreed: the toolbar button
      // went through Prettier and honoured the editor's tab settings, while
      // Shift+Alt+F and format-on-paste got the TS worker's, which reprints at
      // two spaces and never adds semicolons, ignoring every preference. Only
      // formatting is switched off — completions, hovers, diagnostics, rename
      // and the rest of the JS intelligence still come from the worker.
      monaco.languages.typescript.javascriptDefaults.setModeConfiguration(
        Object.assign({}, monaco.languages.typescript.javascriptDefaults.modeConfiguration, {
          documentRangeFormattingEdits: false,
          onTypeFormattingEdits: false
        })
      );
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
          if (payload && payload.paths) {
            refreshProgramPaths(monaco, payload.paths);
            // An edited file's include list is wrong the moment it is saved,
            // and the TTL alone would keep serving it for another 30 s.
            payload.paths.forEach(function (p) { delete includesCache[p]; });
          }
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
      //
      // ── Call-shape diagnostics ───────────────────────────────────────────
      //
      // These are kept even though the blanket rule above drops type
      // diagnostics, because they are not inference guesses: they compare a
      // call against a signature the author wrote. 2554 counts declared
      // parameters. The JSX codes only have anything to say when the
      // component carries a JSDoc `@param {{...}} props` annotation — with a
      // bare `function Card(props)` the props type is `any` and nothing is
      // reported at all, so this can only ever fire against a contract
      // someone stated on purpose.
      //
      // Measured before enabling, over 49 real files (the gem's own 39 JS/JSX
      // sources plus the sample workspace): zero occurrences of any of them,
      // including in spread_props_test.jsx — the spread case that defeated
      // the old denylist. 2345 (argument type) is deliberately NOT here: it
      // fired 3 times on that corpus, every one of them on `isNaN(dateObj)`,
      // which is a working idiom. That is the arbitrary-inference category
      // this filter exists to keep out.
      var JS_CALL_CODES = { '2554': true, '2769': true, '2741': true, '2322': true };
      var JS_KEEP_CODES  = { '2304': true, '6133': true, '2554': true, '2769': true, '2741': true, '2322': true };
      var JS_SYNTAX_CODE = /^(?:1\d{3}|17\d{3})$/;
      var JS_WARN_CODES  = { '2304': true, '6133': true, '2554': true, '2769': true, '2741': true, '2322': true };
      var TS_WARN_CODES  = { '6133': true };

      // Graded by what the mistake does when the code runs, which is the only
      // distinction worth drawing here. An argument past the end of the
      // parameter list is dropped; a prop the component never reads is inert.
      // A required prop that was never passed arrives as undefined, and a
      // value of the wrong type flows straight into the component — both of
      // those break something, so they read as errors.
      //
      // TypeScript folds all three JSX cases into 2769 ("No overload matches
      // this call") once React's types are in play, so the distinction has to
      // come from the message chain, which Monaco flattens into the marker.
      var JS_UNKNOWN_PROPERTY  = /does not exist on type/;
      var JS_MISSING_REQUIRED  = /is missing in type .* but required in type/;
      function callDiagnosticSeverity(code, message) {
        if (code === '2554') return monaco.MarkerSeverity.Warning;
        var text = message || '';
        if (JS_MISSING_REQUIRED.test(text)) return monaco.MarkerSeverity.Error;
        if (JS_UNKNOWN_PROPERTY.test(text)) return monaco.MarkerSeverity.Warning;
        return monaco.MarkerSeverity.Error;
      }

      function keepJsMarker(marker) {
        if (marker.severity !== monaco.MarkerSeverity.Error) return true;
        var code = String(marker.code == null ? '' : marker.code);
        return JS_KEEP_CODES[code] === true || JS_SYNTAX_CODE.test(code);
      }

      // A 2304 whose span is an assignment TARGET (`foo = 1` with no
      // declaration anywhere) is an implicit global — code the host's babel
      // pipeline rejects — so it stays an Error, while read-side 2304s
      // downgrade to Warning (those are usually host globals the language
      // service can't see). Matches `=` (not `==`/`=>`) and compound
      // assignment operators after the flagged identifier.
      var JS_ASSIGN_AFTER = /^\s*(=(?![=>])|(\*\*|<<|>>>?|[+\-*/%&|^]|&&|\|\||\?\?)=)/;
      var JS_IMPLICIT_GLOBAL_HINT = ' This assignment creates an implicit global — declare the variable with var, let, or const.';
      function isUndeclaredAssignment(model, marker) {
        var rest = model.getValueInRange({
          startLineNumber: marker.endLineNumber,
          startColumn: marker.endColumn,
          endLineNumber: marker.endLineNumber,
          endColumn: model.getLineMaxColumn(marker.endLineNumber)
        });
        return JS_ASSIGN_AFTER.test(rest);
      }

      // "Cannot find name 'Foo'." → "Foo"
      function missingNameOf(message) {
        var match = message && message.match(/Cannot find name '([^']+)'/);
        return match ? match[1] : null;
      }

      var _severityPatchActive = false;
      // jsMarkers, when given, is a uri-string -> javascript markers map the
      // caller has already fetched; getModelMarkers filters the whole marker
      // store per call and the TS2304 sweep below wants the same list.
      function patchSeverities(uris, jsMarkers) {
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
              var markers = (entry.owner === 'javascript' && jsMarkers && jsMarkers[uri.toString()]) ||
                monaco.editor.getModelMarkers({ resource: uri, owner: entry.owner });
              var patched = markers.filter(function(m) {
                return entry.keep ? entry.keep(m) : true;
              }).map(function(m) {
                var code = String(m.code);
                if (!entry.warn[code]) return m;

                // 2304 is graded from the evidence rather than from what the
                // marker currently says, because the verdict can move in both
                // directions: it starts as a Warning and becomes an Error once
                // the workspace lookup reports the name does not exist. A rule
                // that only ever fired on an incoming Error could never make
                // that second move — it had already downgraded the marker on
                // the first pass.
                if (code === '2304') {
                  if (isUndeclaredAssignment(model, m)) {
                    return m.message.indexOf(JS_IMPLICIT_GLOBAL_HINT) !== -1 ? m
                      : Object.assign({}, m, {
                          severity: monaco.MarkerSeverity.Error,
                          message: m.message + JS_IMPLICIT_GLOBAL_HINT
                        });
                  }
                  var sym = missingNameOf(m.message);
                  // Lenient only while the answer is outstanding: host-app
                  // globals are invisible to the language service, so an
                  // unresolved name is a question until the lookup answers it.
                  var want = (sym && unknownJsSymbols[sym])
                    ? monaco.MarkerSeverity.Error
                    : monaco.MarkerSeverity.Warning;
                  return m.severity === want ? m : Object.assign({}, m, { severity: want });
                }

                // Graded from the evidence for the same reason 2304 is: the
                // verdict is a property of the message, not of whatever the
                // marker happens to say on this pass.
                if (JS_CALL_CODES[code] && entry.owner === 'javascript') {
                  var callWant = callDiagnosticSeverity(code, m.message);
                  return m.severity === callWant ? m : Object.assign({}, m, { severity: callWant });
                }

                if (m.severity !== monaco.MarkerSeverity.Error) return m;
                return Object.assign({}, m, { severity: monaco.MarkerSeverity.Warning });
              });
              // Re-applying an unchanged set would re-enter this handler
              // forever, so only write when the patch actually changed something.
              var changed = patched.length !== markers.length || patched.some(function(m, i) {
                return m.severity !== markers[i].severity || m.message !== markers[i].message;
              });
              if (changed) monaco.editor.setModelMarkers(model, entry.owner, patched);
            });
          });
        } finally {
          _severityPatchActive = false;
        }
      }

      // A lookup answering "no such symbol" changes no model, so it produces no
      // marker event of its own — the new grade has to be pushed over the open
      // models explicitly.
      repatchJsMarkerSeverities = function () {
        patchSeverities(monaco.editor.getModels().map(function (m) { return m.uri; }));
      };

      monaco.editor.onDidChangeMarkers(function(uris) {
        // One fetch per uri, shared by the severity patch and the TS2304 sweep.
        var jsMarkers = {};
        uris.forEach(function (uri) {
          jsMarkers[uri.toString()] = monaco.editor.getModelMarkers({ resource: uri, owner: 'javascript' });
        });

        patchSeverities(uris, jsMarkers);

        // Auto-resolve TS2304 ("Cannot find name 'X'") for JS files by
        // looking up the symbol in the workspace. If found, addDiscoveredGlobal
        // declares it via addExtraLib and Monaco re-validates, removing the
        // warning; if not found, the name is recorded as unknown and its
        // marker is re-graded to an Error.
        if (typeof FileService !== 'undefined' && FileService.getJsDefinition) {
          uris.forEach(function(uri) {
            var model = monaco.editor.getModel(uri);
            if (!model) return;
            (jsMarkers[uri.toString()] || []).forEach(function(m) {
              if (String(m.code) !== '2304') return;
              var sym = missingNameOf(m.message);
              if (!sym) return;
              if (attemptedJsGlobals[sym]) return;
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

    // These drive `editor.action.reindentLines`, which the Format command
    // falls back to for .ts/.tsx — the only open languages with no Prettier
    // parser. They do NOT affect typing: Monaco's built-in bracket handling
    // already produces the same indent on Enter with or without them, verified
    // case by case. Nothing else should be routed through them, because
    // bracket depth is all they model — JSX nesting and continuation lines
    // (method chains, ternaries, wrapped arguments) are invisible to them, and
    // re-indenting from these rules alone flattens both.
    ['javascript', 'typescript'].forEach(function (langId) {
      monaco.languages.setLanguageConfiguration(langId, {
        indentationRules: {
          increaseIndentPattern: /^((?!\/\/).)*(\{[^}"'`]*|\([^)"'`]*|\[[^\]"'`]*)$/,
          decreaseIndentPattern: /^((?!.*?\/\*).*\*\/)?\s*[})\]].*$/
        }
      });
    });

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

          // Heredoc start — capture the terminator word. A tag naming a
          // language hands the body to Monaco's own tokenizer for that
          // language via nextEmbedded, so <<~JS is highlighted as real
          // JavaScript, not an imitation.
          [/<<[-~]?(['"]?)(\w+)\1/, {
            cases: {
              '$2~(?i:SQL)':            { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'sql' },
              '$2~(?i:HTML?|ERB)':      { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'html' },
              '$2~(?i:JS|JAVASCRIPT)':  { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'javascript' },
              '$2~(?i:CSS)':            { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'css' },
              '$2~(?i:SCSS)':           { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'scss' },
              '$2~(?i:JSON)':           { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'json' },
              '$2~(?i:XML|SVG)':        { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'xml' },
              '$2~(?i:YAML|YML)':       { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'yaml' },
              '$2~(?i:SH|BASH|SHELL)':  { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'shell' },
              '$2~(?i:GRAPHQL|GQL)':    { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'graphql' },
              '$2~(?i:RUBY)':           { token: 'string.heredoc.delimiter', next: '@heredocEmbedded.$2', nextEmbedded: 'ruby' },
              '@default':               { token: 'string.heredoc.delimiter', next: '@heredoc.$2' }
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

        // Generic heredoc — all content is string.heredoc. The terminator may
        // be indented: that is the whole point of <<~ (and <<-), and the old
        // /^(\w+)$/ rule missed it, leaving the rest of the file painted as a
        // string.
        heredoc: [
          [/^\s*(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: 'string.heredoc.delimiter', next: '@pop' },
              '@default': 'string.heredoc'
            }
          }],
          [/.+/, 'string.heredoc']
        ],

        // Language-tagged heredoc body. While embedded, Monarch only consults
        // this state to find the leaving rule; everything before it is
        // tokenized by the embedded language. @rematch + switchTo hands the
        // terminator line to @heredocEnd so it gets the delimiter colour
        // rather than being re-lexed as Ruby.
        heredocEmbedded: [
          [/^\s*(\w+)\s*$/, {
            cases: {
              '$1==$S2': { token: '@rematch', switchTo: '@heredocEnd.$S2', nextEmbedded: '@pop' },
              '@default': { token: '' }
            }
          }],
          [/.*/, { token: '' }]
        ],

        heredocEnd: [
          [/^\s*\w+\s*$/, { token: 'string.heredoc.delimiter', next: '@pop' }]
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
    //
    // Two sources of fixes, preferred in this order:
    //
    //  1. Edits ruby-lsp embedded in the diagnostic itself. Applied directly as
    //     a Monaco workspace edit — no request, no subprocess. This is also the
    //     only source of the "Disable <cop> for this line" action, which
    //     ruby-lsp offers even for cops that can never be autocorrected.
    //  2. The /quick_fix endpoint, which runs `rubocop -A` over the buffer.
    //     Still needed whenever diagnostics came from the plain rubocop path
    //     rather than ruby-lsp.
    monaco.languages.registerCodeActionProvider('ruby', {
      provideCodeActions: function provideCodeActions(model, _range, context) {
        if (!window.MBEDITOR_RUBOCOP_AVAILABLE) return { actions: [], dispose: function() {} };

        var correctableCops = model._mbeditorCorrectableCops || new Set();
        var embedded = model._mbeditorFixes || {};
        var modelPath = model._mbeditorPath || null;
        var actions = [];

        context.markers.forEach(function (marker) {
          if (marker.source !== 'rubocop') return;

          var cop = codeValue(marker.code);
          var fixes = embedded[markerFixKey(marker)];

          if (fixes && fixes.length) {
            fixes.forEach(function (fix) {
              actions.push({
                title: fix.title,
                kind: 'quickfix',
                autocorrect: /^Autocorrect/.test(fix.title),
                diagnostics: [marker],
                edit: {
                  edits: fix.edits.map(function (e) {
                    return {
                      resource: model.uri,
                      versionId: model.getVersionId(),
                      textEdit: {
                        range: new monaco.Range(e.startLine, e.startCol, e.endLine, e.endCol),
                        text: e.text
                      }
                    };
                  })
                }
              });
            });
            return;
          }

          if (!cop || !correctableCops.has(cop) || !modelPath) return;
          actions.push({
            title: 'Fix: ' + cop,
            kind: 'quickfix',
            diagnostics: [marker],
            command: {
              id: 'mbeditor.applyRubocopFix',
              title: 'Apply RuboCop fix for ' + cop,
              arguments: [model, cop, modelPath]
            }
          });
        });

        // Mark the autocorrect as preferred when it is the only one on offer,
        // matching what this provider did before embedded fixes existed. With
        // several offenses under the cursor there is no single obvious fix, so
        // nothing is preferred and the user picks from the list.
        // (Note: monaco's `editor.action.autoFix` ignores isPreferred in this
        // standalone build — verified against a bare probe provider — so this
        // only affects ordering in the lightbulb menu.)
        var autocorrects = actions.filter(function (a) { return a.autocorrect; });
        if (autocorrects.length === 1) autocorrects[0].isPreferred = true;
        actions.forEach(function (a) { delete a.autocorrect; });

        return { actions: actions, dispose: function() {} };
      }
    });

    // Command handler that fetches the fix from the backend and applies it.
    // The buffer is read here, at click time, rather than captured in the
    // action's arguments: a whole copy of the document per marker per lightbulb
    // pass is wasteful, and the copy went stale — the server autocorrected text
    // the buffer had already moved past, and the returned edit landed on the
    // new one.
    monaco.editor.registerCommand('mbeditor.applyRubocopFix', function(_accessor, model, copName, modelPath) {
      if (typeof FileService === 'undefined' || !FileService.quickFixOffense) return;
      FileService.quickFixOffense(modelPath, model.getValue(), copName).then(function(data) {
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

    // ── ruby-lsp navigation ──────────────────────────────────────────────────

    // Serves exactly one thing: the candidate list navigateToJsWord hands over
    // when a name is declared at top level in several other files. It is empty
    // the rest of the time, so the TypeScript worker remains the only voice on
    // an ordinary jump and a local definition still goes straight there —
    // Monaco merges providers without deduping, so a second opinion here would
    // show a picker listing one definition twice.
    monaco.languages.registerDefinitionProvider('javascript', {
      provideDefinition: function (model, position) {
        var pending = pendingJsDefinitionPeek;
        pendingJsDefinitionPeek = null;
        if (!pending) return null;
        if (pending.uri !== model.uri.toString() ||
            pending.lineNumber !== position.lineNumber ||
            pending.column !== position.column) return null;
        return pending.locations;
      }
    });

    // Teaches Monaco how to open a file:// resource in this editor. Without it
    // every provider below can find a location but nothing can go there:
    // peek-definition, the references widget and Ctrl+hover previews all route
    // their "open this" through here.
    monaco.editor.registerEditorOpener({
      openCodeEditor: function (_source, resource, selectionOrPosition) {
        // Only file:// resources name a workspace file. Models are created
        // without an explicit URI, so Monaco gives each one an
        // `inmemory://model/N` identity — and the TS worker returns exactly
        // that when a JS definition resolves inside the file you are already
        // in. Stripping it to a path opened a phantom tab called "57".
        // Handing those back to Monaco lets it reveal the position in the
        // current editor, which is what the gesture meant.
        if (String(resource.scheme || '') !== 'file') return false;

        var path = String(resource.path || '').replace(/^\/+/, '');
        if (!path || typeof TabManager === 'undefined' || !TabManager.openTab) return false;

        var pos = selectionOrPosition || {};
        var line = pos.startLineNumber || pos.lineNumber || 1;
        var col = pos.startColumn || pos.column || 1;
        TabManager.openTab(path, path.split('/').pop(), line, null, false, col);
        return true;
      }
    });

    // Words never worth a definition lookup: language keywords, core methods,
    // and (in ERB) Rails view helpers that live in the framework rather than
    // the workspace. Guarding here rather than in the request means Ctrl+hover
    // over `end` doesn't light up as a link.
    function rubyNavigableWord(model, position, isErb) {
      var info = model.getWordAtPosition(position);
      if (!info || !info.word || info.word.length < 2) return null;
      if (RUBY_KEYWORDS[info.word] || RUBY_CORE_METHODS[info.word]) return null;
      if (isErb) {
        if (!isInsideErbTag(model, position)) return null;
        if (RAILS_VIEW_HELPERS[info.word]) return null;
      }
      return info.word;
    }

    // Definition: ruby-lsp when it can answer, else the grep/Ripper services.
    // ERB always takes the legacy path — Prism cannot parse ERB.
    ['ruby', 'erb'].forEach(function (languageId) {
      var isErb = languageId === 'erb';

      monaco.languages.registerDefinitionProvider(languageId, {
        provideDefinition: function provideDefinition(model, position) {
          var word = rubyNavigableWord(model, position, isErb);
          if (!word) return null;

          var lsp = isErb ? Promise.resolve(null) : tryRubyLsp('definition', model, position);
          return lsp.then(function (data) {
            if (data && data.results && data.results.length) {
              return data.results.map(function (r) {
                var line = r.line || 1;
                return {
                  uri: lspUri(r.file),
                  range: new monaco.Range(line, r.col || 1, r.endLine || line, r.endCol || 1)
                };
              });
            }
            return legacyRubyDefinition(word);
          });
        }
      });
    });

    // The pre-ruby-lsp lookup, now expressed as locations rather than as a
    // side-effecting "open a tab": constants resolve through /module_members,
    // everything else through the Ripper-backed /definition index.
    function legacyRubyDefinition(word) {
      if (typeof FileService === 'undefined') return null;

      if (/^[A-Z]/.test(word) && FileService.getModuleMembers) {
        return FileService.getModuleMembers(word).then(function (data) {
          if (!data || !data.file) return null;
          return [{ uri: lspUri(data.file), range: new monaco.Range(1, 1, 1, 1) }];
        }).catch(function () { return null; });
      }

      if (!FileService.getDefinition) return null;
      return FileService.getDefinition(word, 'ruby').then(function (data) {
        var results = (data && Array.isArray(data.results)) ? data.results : [];
        return results.map(function (r) {
          return { uri: lspUri(r.file), range: new monaco.Range(r.line || 1, 1, r.line || 1, 1) };
        });
      }).catch(function () { return null; });
    }

    // References. No legacy equivalent exists — the workspace search panel is a
    // text grep, not a reference index — so an empty list is the honest answer
    // when ruby-lsp can't help.
    monaco.languages.registerReferenceProvider('ruby', {
      provideReferences: function provideReferences(model, position, _context, token) {
        if (!rubyNavigableWord(model, position, false)) return null;

        return rawRubyLsp('references', model, position, token).then(function (locations) {
          if (!Array.isArray(locations)) return null;
          return locations.filter(function (loc) { return loc && loc.uri; }).map(function (loc) {
            return { uri: lspUri(loc.uri), range: lspRange(loc.range) };
          });
        });
      }
    });

    // Occurrences of the symbol under the cursor. Monaco has a built-in
    // word-match highlighter, but it cannot tell a local named `id` from a
    // method named `id`; ruby-lsp resolves the actual symbol.
    //
    // This one fires on every cursor move, so a caret walking through a word
    // would otherwise cost a request per keypress. One memo entry is enough:
    // the repeat is always the immediately preceding position. Keyed on the
    // exact occurrence rather than the word text — the same name in two scopes
    // is two different symbols with two different highlight sets — and on the
    // model version, so an edit invalidates it.
    var _highlightMemo = null;
    monaco.languages.registerDocumentHighlightProvider('ruby', {
      provideDocumentHighlights: function provideDocumentHighlights(model, position, token) {
        var wordInfo = model.getWordAtPosition(position);
        var key = wordInfo && (model.uri.toString() + '@' + model.getVersionId() + ':' +
          position.lineNumber + ':' + wordInfo.startColumn + ':' + wordInfo.word);
        if (key && _highlightMemo && _highlightMemo.key === key) return _highlightMemo.result;

        return rawRubyLsp('document_highlight', model, position, token).then(function (highlights) {
          if (!Array.isArray(highlights)) return null;
          var result = highlights.filter(Boolean).map(function (h) {
            return { range: lspRange(h.range), kind: h.kind };
          });
          if (key) _highlightMemo = { key: key, result: result };
          return result;
        });
      }
    });

    // Document symbols feed Monaco's breadcrumbs, sticky scroll and
    // Ctrl+Shift+O — all of which are dark for Ruby today.
    //
    // This deliberately does NOT replace ruby_outline.js. That lexer supplies
    // method visibility and test-block (describe/it/test) entries which
    // ruby-lsp's documentSymbol does not emit, and the outline panel groups on
    // both. It also still has to cover ERB, HAML, and the case where ruby-lsp
    // isn't running.
    var LSP_SYMBOL_KINDS = {
      1: 'File', 2: 'Module', 3: 'Namespace', 4: 'Package', 5: 'Class',
      6: 'Method', 7: 'Property', 8: 'Field', 9: 'Constructor', 10: 'Enum',
      11: 'Interface', 12: 'Function', 13: 'Variable', 14: 'Constant',
      15: 'String', 16: 'Number', 17: 'Boolean', 18: 'Array', 19: 'Object',
      20: 'Key', 21: 'Null', 22: 'EnumMember', 23: 'Struct', 24: 'Event',
      25: 'Operator', 26: 'TypeParameter'
    };

    function toMonacoSymbols(symbols, depth) {
      if (!Array.isArray(symbols) || depth > 16) return [];
      return symbols.filter(Boolean).map(function (s) {
        var full = lspRange(s.range);
        return {
          name: String(s.name || ''),
          detail: s.detail || '',
          kind: monaco.languages.SymbolKind[LSP_SYMBOL_KINDS[s.kind] || 'Variable'],
          tags: [],
          range: full,
          selectionRange: s.selectionRange ? lspRange(s.selectionRange) : full,
          children: toMonacoSymbols(s.children, depth + 1)
        };
      });
    }

    monaco.languages.registerDocumentSymbolProvider('ruby', {
      displayName: 'Ruby',
      provideDocumentSymbols: function provideDocumentSymbols(model, token) {
        return rawRubyLsp('document_symbol', model, null, token).then(function (symbols) {
          if (!Array.isArray(symbols)) return null;
          return toMonacoSymbols(symbols, 0);
        });
      }
    });

    // Formatting. Until now Ruby had no formatting provider at all, so
    // Shift+Alt+F and format-on-save silently did nothing — formatting was
    // reachable only through the toolbar button. /format stays as the fallback
    // for when ruby-lsp is unavailable.
    monaco.languages.registerDocumentFormattingEditProvider('ruby', {
      displayName: 'RuboCop',
      provideDocumentFormattingEdits: function provideDocumentFormattingEdits(model, options, token) {
        var opts = { tab_size: (options && options.tabSize) || 2,
                     insert_spaces: !options || options.insertSpaces !== false };

        return tryRubyLsp('formatting', model, { lineNumber: 1, column: 1 }, opts, token)
          .then(function (edits) {
            if (Array.isArray(edits)) {
              return edits.map(function (e) {
                return { range: lspRange(e.range), text: e.newText || '' };
              });
            }
            return legacyRubyFormat(model);
          });
      }
    });

    // Pre-provider path: /format returns the whole corrected file, so it
    // becomes one replacement spanning the buffer.
    function legacyRubyFormat(model) {
      if (typeof FileService === 'undefined' || !FileService.formatFile) return [];
      if (!model._mbeditorPath) return [];

      return FileService.formatFile(model._mbeditorPath, model.getValue()).then(function (data) {
        var formatted = data && data.content;
        if (typeof formatted !== 'string' || formatted === model.getValue()) return [];
        return [{ range: model.getFullModelRange(), text: formatted }];
      }).catch(function () { return []; });
    }

    // ── Prettier formatting providers ────────────────────────────────────────
    //
    // `formatOnPaste` has been on by default for a long time and did nothing
    // outside Ruby: Monaco acts on a paste only through a *range* formatting
    // provider, and none was registered. Registering one here is what makes
    // pasted blocks land correctly indented, and what formats the whole thing
    // when the paste fills an empty file (the pasted range is then the file).
    //
    // Prettier's own rangeStart/rangeEnd does the narrowing — it reprints the
    // smallest enclosing statement and leaves the rest byte-identical, so a
    // paste in the middle of a file does not reformat the file.
    var PRETTIER_LANGUAGE_PARSERS = {
      javascript: 'babel', json: 'json', css: 'css',
      scss: 'scss', less: 'less', html: 'html', markdown: 'markdown'
    };

    // One edit spanning only what actually changed. A whole-document
    // replacement would work but throws away the cursor position and collapses
    // undo, which on every paste is very noticeable.
    function minimalEdit(model, oldText, newText) {
      if (oldText === newText) return [];
      var start = 0;
      var maxStart = Math.min(oldText.length, newText.length);
      while (start < maxStart && oldText.charCodeAt(start) === newText.charCodeAt(start)) start++;
      var oldEnd = oldText.length;
      var newEnd = newText.length;
      while (oldEnd > start && newEnd > start && oldText.charCodeAt(oldEnd - 1) === newText.charCodeAt(newEnd - 1)) {
        oldEnd--;
        newEnd--;
      }
      return [{
        range: monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(oldEnd)),
        text: newText.slice(start, newEnd)
      }];
    }

    function prettierEdits(model, range) {
      var parser = PRETTIER_LANGUAGE_PARSERS[model.getLanguageId()];
      if (!parser || typeof runPrettier !== 'function') return Promise.resolve([]);

      var text = model.getValue();
      var prefs = (typeof EditorStore !== 'undefined' && EditorStore.getState().editorPrefs) || {};
      var extra = null;
      if (range) {
        extra = {
          rangeStart: model.getOffsetAt({ lineNumber: range.startLineNumber, column: range.startColumn }),
          rangeEnd: model.getOffsetAt({ lineNumber: range.endLineNumber, column: range.endColumn })
        };
      }

      return runPrettier(text, prefs, parser, extra)
        .then(function (formatted) {
          // The model can have moved on while Prettier was working.
          if (model.isDisposed() || model.getValue() !== text) return [];
          return minimalEdit(model, text, formatted);
        })
        // A paste of half an expression will not parse. Leaving it alone is the
        // right answer — the diagnostics path reports the syntax error.
        ["catch"](function () { return []; });
    }

    Object.keys(PRETTIER_LANGUAGE_PARSERS).forEach(function (languageId) {
      monaco.languages.registerDocumentRangeFormattingEditProvider(languageId, {
        displayName: 'Prettier',
        provideDocumentRangeFormattingEdits: function (model, range) {
          return prettierEdits(model, range);
        }
      });
      monaco.languages.registerDocumentFormattingEditProvider(languageId, {
        displayName: 'Prettier',
        provideDocumentFormattingEdits: function (model) {
          return prettierEdits(model, null);
        }
      });
    });

    // Parameter hints while typing a call's arguments.
    monaco.languages.registerSignatureHelpProvider('ruby', {
      signatureHelpTriggerCharacters: ['(', ','],
      provideSignatureHelp: function provideSignatureHelp(model, position, token) {
        return rawRubyLsp('signature_help', model, position, token).then(function (help) {
          if (!help || !Array.isArray(help.signatures) || !help.signatures.length) return null;
          // LSP's SignatureHelp is structurally identical to Monaco's, and
          // MarkupContent {kind, value} is accepted where an IMarkdownString is.
          return { value: help, dispose: function () {} };
        });
      }
    });

    // Smart expand/shrink selection (Shift+Alt+Right / Left).
    monaco.languages.registerSelectionRangeProvider('ruby', {
      provideSelectionRanges: function provideSelectionRanges(model, positions, token) {
        // LSP takes a list of positions and answers one linked list per
        // position; the bridge sends a single position, so ask per position and
        // flatten each chain into the array Monaco wants.
        return Promise.all(positions.map(function (position) {
          return rawRubyLsp('selection_range', model, position, token).then(function (result) {
            var node = Array.isArray(result) ? result[0] : null;
            var ranges = [];
            // Bounded: the chain comes from a subprocess and a cycle would spin.
            while (node && node.range && ranges.length < 64) {
              ranges.push({ range: lspRange(node.range) });
              node = node.parent;
            }
            return ranges;
          });
        })).then(function (perPosition) {
          return perPosition.some(function (r) { return r.length; }) ? perPosition : null;
        });
      }
    });

    // F2 rename. ruby-lsp renames *constants only*, so resolveRenameLocation
    // declines anything else up front — otherwise F2 on a method name would
    // open the input box and then fail after you'd typed a new name.
    monaco.languages.registerRenameProvider('ruby', {
      resolveRenameLocation: function resolveRenameLocation(model, position, token) {
        return rawRubyLsp('prepare_rename', model, position, token).then(function (result) {
          if (!result) {
            return { rejectReason: 'Only Ruby constants can be renamed here.' };
          }
          // prepareRename answers either a bare Range or { range, placeholder }.
          var range = result.range || result;
          var wordInfo = model.getWordAtPosition(position);
          return {
            range: lspRange(range),
            text: result.placeholder || (wordInfo && wordInfo.word) || ''
          };
        });
      },

      provideRenameEdits: function provideRenameEdits(model, position, newName) {
        if (typeof FileService === 'undefined' || !FileService.rubyRename) return null;

        // Every path with a live model. The server returns their edits for us
        // to apply rather than writing them, so unsaved buffers survive.
        var openPaths = monaco.editor.getModels()
          .filter(function (m) { return m._mbeditorPath && !m.isDisposed(); })
          .map(function (m) { return m._mbeditorPath; });

        return FileService.rubyRename(model._mbeditorPath, model.getValue(),
                                      position.lineNumber, position.column, newName, openPaths)
          .then(function (data) {
            var edits = [];
            Object.keys((data && data.edits) || {}).forEach(function (relPath) {
              var target = modelForPath(relPath) || null;
              data.edits[relPath].forEach(function (e) {
                edits.push({
                  resource: target ? target.uri : lspUri(relPath),
                  versionId: target ? target.getVersionId() : undefined,
                  textEdit: {
                    range: new monaco.Range(e.startLine, e.startCol, e.endLine, e.endCol),
                    text: e.text
                  }
                });
              });
            });

            reportRenameOutcome(data);
            return { edits: edits };
          })
          .catch(function (err) {
            var message = (err && err.response && err.response.data && err.response.data.error) ||
              'Rename failed.';
            return { edits: [], rejectReason: message };
          });
      }
    });

    function modelForPath(relPath) {
      return monaco.editor.getModels().filter(function (m) {
        return m._mbeditorPath === relPath && !m.isDisposed();
      })[0];
    }

    // Files written straight to disk leave no dirty tab and no undo entry, so
    // say how many were touched — otherwise a workspace-wide rename looks like
    // it only changed the file you were looking at.
    function reportRenameOutcome(data) {
      if (typeof EditorStore === 'undefined' || !EditorStore.setStatus) return;

      var written = (data && data.written) || [];
      var rejected = (data && data.rejected) || [];
      var parts = [];
      if (written.length) parts.push(written.length + ' file' + (written.length === 1 ? '' : 's') + ' saved');
      if (rejected.length) parts.push(rejected.length + ' skipped (outside the workspace)');
      if (!parts.length) return;

      EditorStore.setStatus('Renamed — ' + parts.join(', '), rejected.length ? 'warning' : 'success');
    }

    // Real class/def/block/heredoc folding. Monaco merges the results of every
    // folding provider, so the vim-marker provider registered further down
    // keeps working alongside this one.
    monaco.languages.registerFoldingRangeProvider('ruby', {
      provideFoldingRanges: function provideFoldingRanges(model, _context, token) {
        return rawRubyLsp('folding_range', model, null, token).then(function (ranges) {
          if (!Array.isArray(ranges)) return null;
          return ranges.filter(Boolean).map(function (r) {
            return {
              start: (r.startLine || 0) + 1,
              end: (r.endLine || 0) + 1,
              kind: r.kind === 'comment' ? monaco.languages.FoldingRangeKind.Comment
                : r.kind === 'imports' ? monaco.languages.FoldingRangeKind.Imports
                : r.kind === 'region' ? monaco.languages.FoldingRangeKind.Region
                : undefined
            };
          });
        });
      }
    });

    // Ruby method definition hover provider.
    // Calls the backend /definition endpoint (Ripper-based) and renders
    // the method signature and any preceding # comments as hover markdown.
    // Results are cached client-side for 60 s to make re-hovers instantaneous.
    var hoverCache = {};
    var HOVER_CACHE_TTL_MS = 60000;
    var HOVER_MEMBER_LIMIT = 20;

    // Store an entry, stamping it and sweeping expired keys as it goes. The TTL
    // was only ever consulted on read, and nothing else ever removed a key, so
    // every symbol hovered in a session stayed resident for the life of the
    // page. The sweep is O(entries) on a miss, which at these sizes is free.
    function cacheWrite(cache, ttlMs, key, entry) {
      var now = Date.now();
      Object.keys(cache).forEach(function (k) {
        if (now - cache[k].ts >= ttlMs) delete cache[k];
      });
      entry.ts = now;
      cache[key] = entry;
      return entry;
    }

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
        cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, key, { markdown: markdown });
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
                  cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, lspKey, { result: lspResult });
                  return lspResult;
                });
              }
              cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, lspKey, { result: null });
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
              cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, modKey, { result: null });
              return null;
            }
            var lines = ['**' + data.name + '**  `' + (data.file || '') + '`\n'];
            data.methods.slice(0, 20).forEach(function(m) {
              lines.push('- `' + (m.signature || m.name) + '`');
            });
            var result = { contents: [{ value: lines.join('\n') }] };
            cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, modKey, { result: result });
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
          cacheWrite(hoverCache, HOVER_CACHE_TTL_MS, word, { results: results });

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
          cacheWrite(includesCache, INCLUDES_CACHE_TTL_MS, path, { data: result });
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
            // Same preference as Ctrl+click, so the file the hover names is
            // the file the jump would take you to.
            var r = preferCurrentFile(results, model._mbeditorPath) || results[0];
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

        // Only the raw member list is cached. Suggestions carry the insert
        // `range`, which is where the completion is about to be written — the
        // same trap the hover provider's makeHoverRange avoids. Cached
        // suggestions inserted at the position of the invocation that filled
        // the cache, so a hit anywhere else in the file was misapplied or
        // silently dropped by Monaco.
        function buildSuggestions(members) {
          return members.map(function(m) {
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
        }

        var cached = jsMembersCache[symbol];
        if (cached && (Date.now() - cached.ts) < JS_MEMBERS_CACHE_TTL_MS) {
          return { suggestions: buildSuggestions(cached.members) };
        }

        return FileService.getJsMembers(symbol)
          .then(function(data) {
            var members = (data && data.members) || [];
            jsMembersCache[symbol] = { ts: Date.now(), members: members };
            return { suggestions: buildSuggestions(members) };
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
    // EditorPanel keys the embedded-fix side map with this; the code-action
    // provider reads it back. One definition so the two cannot drift.
    markerFixKey: markerFixKey,
    // Exposed so the ERB gating can be asserted directly in system tests.
    isInsideErbTag: isInsideErbTag,
    runRubyEnter: function runRubyEnter(editor) {
      if (!editor || !editor.getModel) return false;
      return handleRubyEnter(editor, editor.getModel());
    }
  };
})();
