// Audit/telemetry ring the developer can download and hand to an AI to analyse.
//
// The privacy guarantee is structural, not a scrubber: rec() is the only way
// in, and it drops any argument whose typeof is not 'number'. A path, a file
// name, a URL or a line of source cannot be represented at all. Enumerated
// dimensions (file extension, search backend tier, LSP method, collab phase)
// travel as small integers whose meaning lives in LEGEND. LEGEND stays here and
// is merged into the file at download time: sending it to the server would be
// the one path in this module that carries an arbitrary string, which is
// exactly the property the rest of it exists to deny.
window.MbeditorAudit = (function () {
  var CAPACITY = 512;
  var FLUSH_AT = CAPACITY / 2;

  var EV = Object.freeze({
    BOOT: 1,
    OPEN: 2,
    SAVE: 3,
    SEARCH: 4,
    TREE_POLL: 5,
    GIT_POLL: 6,
    LINT: 7,
    FORMAT: 8,
    LSP: 9,
    COLLAB: 10,
    LONGTASK: 11,
    ERR: 12
  });

  var LEGEND = {
    ev: {},
    // What a, b and c mean per event. A field named after one of the
    // enumerated dimensions below carries an index into that table.
    fields: {
      BOOT:      ['msToReady', '', ''],
      OPEN:      ['ext', 'bytes', 'ms'],
      SAVE:      ['ext', 'bytes', 'ms'],
      SEARCH:    ['searchBackend', 'ms', 'hits'],
      TREE_POLL: ['ms', 'changed', ''],
      GIT_POLL:  ['ms', 'changedFiles', ''],
      LINT:      ['ext', 'ms', 'markers'],
      FORMAT:    ['ext', 'ms', 'bytes'],
      LSP:       ['lspMethod', 'ms', 'ok'],
      COLLAB:    ['collabPhase', 'peers', 'ms'],
      LONGTASK:  ['ms', '', ''],
      ERR:       ['ev', '', '']
    },
    // Index 0 is always "other", so an unrecognised name still records.
    ext: ['other', 'rb', 'js', 'jsx', 'erb', 'haml', 'css', 'scss', 'html', 'md', 'json', 'yml', 'ts', 'tsx'],
    searchBackend: ['other', 'rg', 'git', 'grep'],
    lspMethod: ['other', 'definition', 'hover', 'completion', 'diagnostics', 'references', 'rename',
                'format', 'signatureHelp', 'documentSymbol', 'foldingRange', 'documentHighlight',
                'selectionRange', 'codeAction'],
    collabPhase: ['other', 'join', 'seed', 'attach', 'defer', 'update', 'reconnect', 'leave']
  };
  Object.keys(EV).forEach(function (name) { LEGEND.ev[EV[name]] = name; });

  // Preallocated: rec() reuses the slot, so recording allocates nothing.
  var ring = new Array(CAPACITY);
  for (var i = 0; i < CAPACITY; i++) ring[i] = [0, 0, 0, 0, 0];

  var write = 0;
  var count = 0;
  var enabled = false;
  var scheduled = false;
  var observing = false;

  // The whole privacy guarantee in one line.
  function num(v) { return typeof v === 'number' && isFinite(v) ? v : 0; }

  function rec(ev, a, b, c) {
    if (!enabled) return;
    var e = ring[write];
    e[0] = performance.now() | 0;
    e[1] = num(ev);
    e[2] = num(a);
    e[3] = num(b);
    e[4] = num(c);
    write = write + 1 === CAPACITY ? 0 : write + 1;
    if (count < CAPACITY) count++;
    if (count >= FLUSH_AT) schedule();
  }

  function code(dimension, name) {
    var table = LEGEND[dimension];
    var index = table ? table.indexOf(name) : -1;
    return index < 0 ? 0 : index;
  }

  function drain() {
    var out = new Array(count);
    var start = (write - count + CAPACITY) % CAPACITY;
    for (var i = 0; i < count; i++) {
      var e = ring[(start + i) % CAPACITY];
      out[i] = [e[0], e[1], e[2], e[3], e[4]];
    }
    count = 0;
    write = 0;
    return out;
  }

  // keepalive rather than navigator.sendBeacon: the CSRF guard needs the
  // X-Mbeditor-Client header and sendBeacon cannot set one.
  function flush() {
    scheduled = false;
    if (!enabled || count === 0) return Promise.resolve();
    var body = JSON.stringify({ events: drain() });
    return fetch(window.mbeditorBasePath() + '/audit_log', {
      method: 'POST',
      keepalive: true,
      headers: { 'X-Mbeditor-Client': '1', 'Content-Type': 'application/json' },
      body: body
    })['catch'](function () {});
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    if (window.requestIdleCallback) {
      window.requestIdleCallback(function () { flush(); }, { timeout: 2000 });
    } else {
      setTimeout(function () { flush(); }, 0);
    }
  }

  function observe() {
    if (observing) return;
    observing = true;
    try {
      new PerformanceObserver(function (list) {
        var items = list.getEntries();
        for (var i = 0; i < items.length; i++) rec(EV.LONGTASK, items[i].duration | 0);
      }).observe({ type: 'longtask', buffered: true });
    } catch (e) {
      // Safari has no longtask entry type. Everything else keeps recording.
    }
  }

  function clear() { count = 0; write = 0; }

  function setEnabled(on) {
    on = !!on;
    if (on === enabled) return;
    enabled = on;
    // Disabled means nothing recorded, including what was buffered before the
    // preference arrived from the server.
    if (on) observe(); else clear();
  }

  window.addEventListener('pagehide', function () { flush(); });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flush();
  });

  return {
    EV: EV,
    LEGEND: LEGEND,
    rec: rec,
    code: code,
    flush: flush,
    clear: clear,
    setEnabled: setEnabled,
    buffered: function () { return count; }
  };
})();
