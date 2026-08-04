// Identify all requests as coming from the mbeditor client.
// The server uses this header to silence editor logs and guard non-GET requests.
axios.defaults.headers.common['X-Mbeditor-Client'] = '1';

// Cap all API calls at 30 s so a hung Rails server never blocks the UI forever.
// The ping endpoint overrides this with a tighter 4 s timeout per-request.
axios.defaults.timeout = 30000;

// ── Server reachability ─────────────────────────────────────────────────────
//
// The editor polls hard and unconditionally: the file tree every 10s, git status
// every 5s, the git line tint every 10s. When the host stops resolving — a
// dropped VPN, a closed laptop lid, a stopped server — every one of those keeps
// firing forever, and the browser logs each failure itself. That is where the
// wall of ERR_NAME_NOT_RESOLVED in the console comes from, and JavaScript cannot
// suppress those entries: the only fix is to stop making the requests.
//
// So background polling is short-circuited while the server looks unreachable,
// and a single probe on a backoff decides when it is back. User-initiated
// requests are never blocked — they fail fast with a real error instead, which
// beats hanging until the 30s timeout.
var ServerReachability = (function () {
  // A network-level failure has no response; an HTTP error does. Only the former
  // means "cannot reach the server" — a 500 proves it is very much there.
  var CONSECUTIVE_FAILURES_BEFORE_OFFLINE = 2;
  var PROBE_BASE_MS = 1000;
  var PROBE_MAX_MS = 30000;

  var _failures = 0;
  var _online = true;
  var _probeTimer = null;
  var _probeAttempts = 0;
  var _listeners = [];

  function _emit() {
    _listeners.slice().forEach(function (fn) {
      try { fn(_online); } catch (e) { /* a bad listener must not stop the rest */ }
    });
  }

  function _scheduleProbe() {
    if (_probeTimer || _online) return;
    var delay = Math.min(PROBE_MAX_MS, PROBE_BASE_MS * Math.pow(2, _probeAttempts));
    _probeAttempts += 1;
    _probeTimer = setTimeout(function () {
      _probeTimer = null;
      // Bypasses the short-circuit below: this is the one request allowed
      // through while offline, and it is what lets us notice recovery.
      axios.get(window.mbeditorBasePath() + '/ping', { timeout: 4000, mbeditorProbe: true })
        .then(function () { noteSuccess(); })
        .catch(function () { _scheduleProbe(); });
    }, delay);
  }

  function noteSuccess() {
    _failures = 0;
    _probeAttempts = 0;
    if (_probeTimer) { clearTimeout(_probeTimer); _probeTimer = null; }
    if (!_online) { _online = true; _emit(); }
  }

  function noteNetworkFailure() {
    _failures += 1;
    if (_online && _failures >= CONSECUTIVE_FAILURES_BEFORE_OFFLINE) {
      _online = false;
      _emit();
      _scheduleProbe();
    } else if (!_online) {
      _scheduleProbe();
    }
  }

  return {
    isOnline: function () { return _online; },
    noteSuccess: noteSuccess,
    noteNetworkFailure: noteNetworkFailure,
    onChange: function (fn) {
      _listeners.push(fn);
      return function () { _listeners = _listeners.filter(function (f) { return f !== fn; }); };
    }
  };
})();

// Drop background polls while the server is unreachable, so they stop producing
// console noise and pointless traffic. Marked requests only — anything the user
// asked for still goes out.
axios.interceptors.request.use(function (config) {
  if (config.mbeditorBackground && !ServerReachability.isOnline()) {
    var err = new Error('mbeditor: skipped background request while server unreachable');
    err.mbeditorSkipped = true;
    return Promise.reject(err);
  }
  return config;
});

axios.interceptors.response.use(function (response) {
  ServerReachability.noteSuccess();
  return response;
}, function (error) {
  if (error && error.mbeditorSkipped) return Promise.reject(error);
  // No response object at all means the request never reached the server.
  if (error && !error.response) ServerReachability.noteNetworkFailure();
  else ServerReachability.noteSuccess();
  return Promise.reject(error);
});

// Surface pending-migration errors as a dismissible banner instead of silently failing.
axios.interceptors.response.use(null, function(error) {
  if (error.response && error.response.data && error.response.data.pending_migration_error) {
    var bannerId = 'mbeditor-migration-banner';
    if (!document.getElementById(bannerId)) {
      var banner = document.createElement('div');
      banner.id = bannerId;
      banner.style.cssText = [
        'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:99999',
        'background:#f1c40f', 'color:#1e1e1e', 'font-family:system-ui,sans-serif',
        'font-size:13px', 'padding:8px 16px', 'display:flex',
        'align-items:center', 'gap:12px'
      ].join(';');
      banner.innerHTML =
        '<strong>Pending migrations detected.</strong>' +
        ' Run <code style="background:rgba(0,0,0,.15);padding:1px 5px;border-radius:3px">rails db:migrate</code>' +
        ' then reload — editor is still available.' +
        '<button onclick="this.parentNode.remove()" style="margin-left:auto;background:none;border:none;' +
        'cursor:pointer;font-size:16px;line-height:1;padding:0 4px" aria-label="Dismiss">\u00d7</button>';
      document.body.prepend(banner);
    }
  }
  return Promise.reject(error);
});

// Prefetch cache: path -> { controller: AbortController, promise: Promise<{content,language}>, resolvedAt: number|null }
// Entries are consumed once (getPrefetched deletes them) or cancelled on mouseleave.
// Settled entries that are never consumed expire after 30 s (TTL).
var prefetchCache = new Map();
var PREFETCH_TTL_MS = 30000;

var FileService = (function () {
  function getWorkspace() {
    return axios.get(window.mbeditorBasePath() + '/workspace').then(function(res) { return res.data; });
  }

  // opts.background marks an automatic poll rather than something the user
  // asked for, so it can be skipped while the server is unreachable.
  function getTree(opts) {
    var cfg = (opts && opts.background) ? { mbeditorBackground: true } : {};
    return axios.get(window.mbeditorBasePath() + '/files', cfg).then(function(res) { return res.data; });
  }

  function getFile(path, options) {
    var params = { path: path };
    if (options && options.allowMissing) {
      params.allow_missing = '1';
    }
    return axios.get(window.mbeditorBasePath() + '/file', { params: params }).then(function(res) { return res.data; });
  }

  function getFileChunk(path, startLine, lineCount) {
    if (lineCount === undefined) {
      lineCount = 500;
    }
    var params = { path: path, start_line: startLine, line_count: lineCount };
    return axios.get(window.mbeditorBasePath() + '/file', { params: params }).then(function(res) { return res.data; });
  }

  function saveFile(path, code) {
    return axios.post(window.mbeditorBasePath() + '/file', { path: path, code: code }).then(function(res) { return res.data; });
  }

  function createFile(path, code) {
    return axios.post(window.mbeditorBasePath() + '/create_file', { path: path, code: code || '' }).then(function(res) { return res.data; });
  }

  // Multipart import of files dragged in from outside the browser. The
  // default 30 s axios timeout is too tight for a large drop on a slow disk,
  // so this one call gets a longer leash.
  function importFiles(formData) {
    return axios.post(window.mbeditorBasePath() + '/import', formData, {
      timeout: 120000
    }).then(function (res) { return res.data; });
  }

  function createDir(path) {
    return axios.post(window.mbeditorBasePath() + '/create_dir', { path: path }).then(function(res) { return res.data; });
  }

  function renamePath(path, newPath) {
    return axios.patch(window.mbeditorBasePath() + '/rename', { path: path, new_path: newPath }).then(function(res) { return res.data; });
  }

  function deletePath(path) {
    return axios.delete(window.mbeditorBasePath() + '/delete', { data: { path: path } }).then(function(res) { return res.data; });
  }

  function lintFile(path, code, language) {
    var payload = { path: path, code: code };
    if (language) payload.language = language;
    return axios.post(window.mbeditorBasePath() + '/lint', payload).then(function(res) { return res.data; });
  }

  function quickFixOffense(path, code, copName) {
    return axios.post(window.mbeditorBasePath() + '/quick_fix', { path: path, code: code, cop_name: copName }).then(function(res) { return res.data; });
  }

  function formatFile(path, code) {
    return axios.post(window.mbeditorBasePath() + '/format', { path: path, code: code }).then(function(res) { return res.data; });
  }

  // line (1-based, optional) narrows the run to the single test at that line;
  // the server ignores it unless `path` IS the test file.
  function runTests(path, line) {
    var payload = { path: path };
    if (line) payload.line = line;
    return axios.post(window.mbeditorBasePath() + '/test', payload, { timeout: 120000 }).then(function(res) { return res.data; });
  }

  function ping() {
    return axios.get(window.mbeditorBasePath() + '/ping', { timeout: 4000 }).then(function(res) { return res.data; });
  }

  // Which routes reach each action in a controller. Returns { controller, actions }
  // with an empty actions map for anything that is not a controller, so the
  // caller does not have to know the naming convention.
  function getRoutes(path) {
    return axios.get(window.mbeditorBasePath() + '/routes?path=' + encodeURIComponent(path))
      .then(function (res) { return res.data; });
  }

  function getState() {
    return axios.get(window.mbeditorBasePath() + '/state').then(function(res) { return res.data; });
  }

  function saveState(state) {
    if (WebSocketService.isConnected() && WebSocketService.perform('save_state', { state: state })) {
      return Promise.resolve({ ok: true });
    }
    return axios.post(window.mbeditorBasePath() + '/state', { state: state }).then(function(res) { return res.data; });
  }

  function getBranchState(branch) {
    return axios.get(window.mbeditorBasePath() + '/branch_state', { params: { branch: branch } }).then(function(res) { return res.data; });
  }

  function saveBranchState(branch, state) {
    if (WebSocketService.isConnected() && WebSocketService.perform('save_branch_state', { branch: branch, state: state })) {
      return Promise.resolve({ ok: true });
    }
    return axios.post(window.mbeditorBasePath() + '/branch_state', { branch: branch, state: state }).then(function(res) { return res.data; });
  }

  function pruneBranchStates() {
    return axios.post(window.mbeditorBasePath() + '/prune_branch_states').then(function(res) { return res.data; });
  }

  function getDefinition(symbol, language, extraOptions) {
    var config = Object.assign({ params: { symbol: symbol, language: language }, timeout: 5000 }, extraOptions || {});
    return axios.get(window.mbeditorBasePath() + '/definition', config).then(function(res) { return res.data; });
  }

  // Prefetch file content and store in prefetchCache. Uses native fetch + AbortController
  // so the in-flight request can be cancelled on mouseleave without touching axios.
  function prefetch(path) {
    if (prefetchCache.has(path)) return; // already in-flight or cached

    // Evict stale settled entries before adding a new one
    var now = Date.now();
    prefetchCache.forEach(function(entry, key) {
      if (entry.resolvedAt !== null && now - entry.resolvedAt > PREFETCH_TTL_MS) {
        prefetchCache.delete(key);
      }
    });

    var controller = new AbortController();
    var entry = { controller: controller, promise: null, resolvedAt: null };
    // allow_missing=1 so a 404 resolves to { missing:true } instead of rejecting
    var url = window.mbeditorBasePath() + '/file?path=' + encodeURIComponent(path) + '&allow_missing=1';
    entry.promise = fetch(url, {
      signal: controller.signal,
      headers: { 'X-Mbeditor-Client': '1' }
    }).then(function(res) {
      if (!res.ok) throw new Error('prefetch failed: ' + res.status);
      return res.json();
    }).then(function(data) {
      entry.resolvedAt = Date.now();
      return data;
    }).catch(function(err) {
      // Remove from cache on failure/abort so a real open falls back to a fresh fetch
      prefetchCache.delete(path);
      return null;
    });
    prefetchCache.set(path, entry);
  }

  // Returns a Promise for the cached result and removes the entry (consume-once),
  // or returns null if no prefetch is in-flight / completed for this path.
  // Settled entries older than PREFETCH_TTL_MS are treated as expired.
  function getPrefetched(path) {
    var entry = prefetchCache.get(path);
    if (!entry) return null;
    if (entry.resolvedAt !== null && Date.now() - entry.resolvedAt > PREFETCH_TTL_MS) {
      prefetchCache.delete(path);
      return null;
    }
    return entry.promise;
  }

  // Abort any in-flight prefetch for path and remove it from the cache.
  function cancelPrefetch(path) {
    var entry = prefetchCache.get(path);
    if (!entry) return;
    entry.controller.abort();
    prefetchCache.delete(path);
  }

  function getJsDefinition(symbol, extraOptions, parent) {
    var params = { symbol: symbol };
    if (parent) params.parent = parent;
    var config = Object.assign({ params: params, timeout: 5000 }, extraOptions || {});
    return axios.get(window.mbeditorBasePath() + '/js_definition', config).then(function(res) { return res.data; });
  }

  function getJsMembers(symbol, extraOptions) {
    var config = Object.assign({ params: { symbol: symbol }, timeout: 5000 }, extraOptions || {});
    return axios.get(window.mbeditorBasePath() + '/js_members', config).then(function(res) { return res.data; });
  }

  function getModuleMembers(name, extraOptions) {
    var config = Object.assign({ params: { name: name }, timeout: 8000 }, extraOptions || {});
    return axios.get(window.mbeditorBasePath() + '/module_members', config).then(function(res) { return res.data; });
  }

  function getFileIncludes(path, extraOptions) {
    var config = Object.assign({ params: { path: path }, timeout: 15000 }, extraOptions || {});
    return axios.get(window.mbeditorBasePath() + '/file_includes', config).then(function(res) { return res.data; });
  }

  function getClientConfig() {
    return axios.get(window.mbeditorBasePath() + '/client_config').then(function(res) { return res.data; });
  }

  // Bridge to the host's ruby-lsp process. lspMethod: 'definition' | 'hover'
  // | 'completion'; line/character are Monaco 1-based. The server answers in
  // provider-ready shapes, or { fallback: true } when the LSP can't answer in
  // time (caller then uses the legacy grep/Ripper path).
  // extraBody carries per-method request params (e.g. formatting's tab_size);
  // extraOptions is axios config (e.g. a longer timeout).
  function rubyLspRequest(lspMethod, path, content, line, character, extraOptions, extraBody) {
    var config = Object.assign({ timeout: 6000 }, extraOptions || {});
    var body = Object.assign({
      lsp_method: lspMethod,
      path: path,
      content: content,
      line: line,
      character: character
    }, extraBody || {});
    return axios.post(window.mbeditorBasePath() + '/ruby_lsp', body, config)
      .then(function(res) { return res.data; });
  }

  // ActiveRecord models and their associations. Generating this eager-loads the
  // host app, so the timeout is generous and it is only requested on demand.
  function getModelGraph(force) {
    return axios.get(window.mbeditorBasePath() + '/model_graph', {
      params: force ? { refresh: 1 } : {},
      timeout: 60000
    }).then(function (res) { return res.data; });
  }

  // Exceptions raised by the host app, newest first. The cable push is the
  // live path; this seeds the panel and covers hosts without ActionCable.
  function getExceptions() {
    return axios.get(window.mbeditorBasePath() + '/exceptions')
      .then(function (res) { return res.data; });
  }

  function clearExceptions() {
    return axios["delete"](window.mbeditorBasePath() + '/exceptions')
      .then(function (res) { return res.data; });
  }

  // Rename a Ruby constant across the workspace. openPaths lists every file
  // with a live editor model: the server returns their edits for Monaco to
  // apply (undoable, marks the tab dirty) and writes the rest to disk itself.
  function rubyRename(path, content, line, character, newName, openPaths) {
    return axios.post(window.mbeditorBasePath() + '/ruby_rename', {
      path: path, content: content, line: line, character: character,
      new_name: newName, open_paths: openPaths || []
    }, { timeout: 35000 }).then(function (res) { return res.data; });
  }

  // Whole-document Ruby diagnostics from ruby-lsp (RuboCop offenses + Prism
  // syntax errors), translated server-side into the same marker shape /lint
  // returns.
  function lspDiagnostics(path, content) {
    return rubyLspRequest('diagnostics', path, content, 1, 1, { timeout: 15000 });
  }

  function getJsGlobals() {
    return axios.get(window.mbeditorBasePath() + '/js_globals', { timeout: 20000 })
      .then(function(res) { return res.data; });
  }

  // The workspace's own JS source for Monaco's TypeScript program. This is the
  // largest response the editor fetches (a big app is tens of MB before gzip),
  // so it gets a generous timeout and is only ever fetched whole once — later
  // changes go through getJsProgramFile.
  function getJsProgram() {
    return axios.get(window.mbeditorBasePath() + '/js_program', { timeout: 120000 })
      .then(function(res) { return res.data; });
  }

  function getJsProgramFile(path) {
    return axios.get(window.mbeditorBasePath() + '/js_program', { params: { path: path }, timeout: 15000 })
      .then(function(res) { return res.data; });
  }

  function getRelatedFiles(path) {
    return axios.get(window.mbeditorBasePath() + '/related_files', { params: { path: path } })
      .then(function(res) { return res.data; });
  }

  function getChangelog() {
    return axios.get(window.mbeditorBasePath() + '/changelog')
      .then(function(res) { return res.data; });
  }

  function getModelSchema(model) {
    return axios.get(window.mbeditorBasePath() + '/model_schema', { params: { model: model } })
      .then(function(res) { return res.data; });
  }

  return {
    getWorkspace: getWorkspace,
    getTree: getTree,
    getFile: getFile,
    getFileChunk: getFileChunk,
    saveFile: saveFile,
    createFile: createFile,
    importFiles: importFiles,
    createDir: createDir,
    renamePath: renamePath,
    deletePath: deletePath,
    lintFile: lintFile,
    quickFixOffense: quickFixOffense,
    formatFile: formatFile,
    runTests: runTests,
    ping: ping,
    getRoutes: getRoutes,
    isServerReachable: ServerReachability.isOnline,
    onReachabilityChange: ServerReachability.onChange,
    getState: getState,
    saveState: saveState,
    getBranchState: getBranchState,
    saveBranchState: saveBranchState,
    pruneBranchStates: pruneBranchStates,
    getDefinition: getDefinition,
    getJsDefinition: getJsDefinition,
    getJsMembers: getJsMembers,
    prefetch: prefetch,
    getPrefetched: getPrefetched,
    cancelPrefetch: cancelPrefetch,
    getModuleMembers: getModuleMembers,
    getFileIncludes: getFileIncludes,
    getClientConfig: getClientConfig,
    getJsGlobals: getJsGlobals,
    getJsProgram: getJsProgram,
    getJsProgramFile: getJsProgramFile,
    rubyLspRequest: rubyLspRequest,
    lspDiagnostics: lspDiagnostics,
    rubyRename: rubyRename,
    getModelGraph: getModelGraph,
    getExceptions: getExceptions,
    clearExceptions: clearExceptions,
    getRelatedFiles: getRelatedFiles,
    getModelSchema: getModelSchema,
    getChangelog: getChangelog
  };
})();
