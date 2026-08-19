'use strict';

// LogService — streams the Rails log into a bounded in-memory buffer.
// Primary transport: WebSocket (EditorChannel `start_log_tail`). Fallback:
// HTTP polling of GET /logs/tail. ANSI escape codes are stripped for v1.
var LogService = (function () {
  var MAX_LINES     = 2000;          // bounded buffer to keep the DOM light
  var POLL_INTERVAL = 1500;          // ms, HTTP fallback cadence
  var ANSI_RE       = /\x1b\[[0-9;]*m/g;

  var _lines      = [];
  var _offset     = null;            // null => initial load
  var _active     = false;
  var _pollTimer  = null;
  var _usingWs    = false;
  var _subscribers = [];

  function _strip(line) { return line.replace(ANSI_RE, ''); }

  function _basePath() { return window.mbeditorBasePath(); }

  function _apply(data) {
    if (!data) return;
    if (data.reset) _lines = [];
    if (typeof data.offset === 'number') _offset = data.offset;
    if (data.lines && data.lines.length) {
      for (var i = 0; i < data.lines.length; i++) _lines.push(_strip(data.lines[i]));
      if (_lines.length > MAX_LINES) _lines = _lines.slice(_lines.length - MAX_LINES);
    }
    _notify();
  }

  function _notify() {
    _subscribers.forEach(function (fn) {
      try { fn(_lines); } catch (e) { /* ignore */ }
    });
  }

  function _fetchOnce() {
    var url = _basePath() + '/logs/tail';
    if (_offset !== null) url += '?offset=' + _offset;
    return axios.get(url)
      .then(function (res) { _apply(res.data); })
      .catch(function () { /* transient; next tick retries */ });
  }

  function _startPolling() {
    _usingWs = false;
    _fetchOnce();
    _pollTimer = setInterval(function () { if (_active) _fetchOnce(); }, POLL_INTERVAL);
  }

  function _onWsLog(data) { if (_active) _apply(data); }

  // Begin streaming. Loads initial tail over HTTP, then prefers WS push.
  function start() {
    if (_active) return;
    _active = true;
    _offset = null;
    _lines = [];
    _fetchOnce().then(function () {
      // A stop() while that first fetch was in flight already ran the teardown;
      // starting the transport now would leave the poll interval running (and
      // the server tailing) with nothing to stop it.
      if (!_active) return;
      if (window.WebSocketService && WebSocketService.isConnected()) {
        _usingWs = true;
        WebSocketService.onLogLines(_onWsLog);
        WebSocketService.perform('start_log_tail', { offset: _offset });
      } else {
        _startPolling();
      }
    });
  }

  function stop() {
    if (!_active) return;
    _active = false;
    if (_usingWs && window.WebSocketService) {
      WebSocketService.perform('stop_log_tail', {});
      WebSocketService.offLogLines(_onWsLog);
    }
    if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  }

  function clear() { _lines = []; _notify(); }

  function getLines() { return _lines; }

  // Subscribe to buffer updates; returns an unsubscribe function.
  function subscribe(fn) {
    _subscribers.push(fn);
    return function () {
      _subscribers = _subscribers.filter(function (f) { return f !== fn; });
    };
  }

  return {
    start: start,
    stop: stop,
    clear: clear,
    getLines: getLines,
    subscribe: subscribe
  };
})();

window.LogService = LogService;
