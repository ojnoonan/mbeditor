// WebSocketService — wraps ActionCable when available.
// Falls back gracefully when ActionCable is absent or the WebSocket connection
// cannot be established (e.g. the host app does not mount /cable).
//
// The ping heartbeat is intentionally NOT routed through this service.
// Polling keeps working as the authoritative "is the server reachable?" check
// because WebSocket connections can survive DNS/network changes that would
// otherwise prevent reconnection.
var WebSocketService = (function () {
  var _consumer = null;
  var _subscription = null;
  var _connected = false;
  // Why collaboration is or is not working, so the editor can say so instead of
  // failing silently. A rejected subscription used to just schedule a reconnect
  // and tell nobody, which made a blocked cable indistinguishable from an empty
  // room.
  var _status = 'idle';   // idle | unsupported | connecting | connected | rejected | dropped
  var _filesChangedCallbacks = [];
  var _fileSavedCallbacks = [];
  var _presenceCallbacks = [];
  var _logLinesCallbacks = [];
  var _serverSupportsWs = false;
  var _reconnectTimer = null;
  var _lastCableAttemptAt = 0;
  // Exponential backoff, not a flat interval. This used to wait a fixed 30s
  // before even attempting a reconnect — and because `disconnected` tears the
  // consumer down, Action Cable's own much faster reconnection monitor is
  // discarded too. The result was that any transient blip cost half a minute
  // with no cable: no presence, no collaboration, no file-change push. Start
  // near-instant for the common case (a blip, a server restart) and back off
  // only if the server really is gone.
  // Growth is gentle and the ceiling low on purpose. The dominant case here is a
  // development server restarting, which takes several seconds to boot — a
  // doubling curve spends those seconds growing, so the attempt that finally
  // lands is a long way out. Measured against a real restart: doubling to a 30s
  // cap reconnected in 20s, this reconnects within a few. It is a local dev
  // tool, so retrying every few seconds costs nothing worth saving.
  var RECONNECT_BASE_MS = 1000;
  var RECONNECT_MAX_MS = 8000;
  var RECONNECT_FACTOR = 1.6;
  var _reconnectAttempts = 0;

  function _reconnectDelay() {
    var exp = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * Math.pow(RECONNECT_FACTOR, _reconnectAttempts));
    // Jitter so a server restart doesn't have every open tab retry in lockstep.
    return Math.round(exp * (0.7 + Math.random() * 0.6));
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  function _isActionCableAvailable() {
    return typeof window.ActionCable !== 'undefined';
  }

  function _cableUrl() {
    return window.MBEDITOR_CABLE_URL || '/cable';
  }

  function _getConsumer() {
    // Reuse an existing consumer the host app may have already created (App.cable
    // is the Rails default).  Fall back to creating our own.
    if (typeof window.App !== 'undefined' && window.App.cable) {
      return window.App.cable;
    }
    return window.ActionCable.createConsumer(_cableUrl());
  }

  function _cleanupConsumer() {
    if (_subscription) {
      try { _subscription.unsubscribe(); } catch (e) { /* ignore */ }
      _subscription = null;
    }
    if (_consumer && typeof _consumer.disconnect === 'function') {
      try { _consumer.disconnect(); } catch (e) { /* ignore */ }
    }
    _consumer = null;
    _connected = false;
  }

  function _isCableRelatedRejection(reason) {
    var url = _cableUrl();
    if (!reason) return false;

    // Common browser shape: ErrorEvent with target/currentTarget = WebSocket.
    var target = reason.target || reason.currentTarget;
    if (target && typeof target.url === 'string' && target.url.indexOf(url) !== -1) {
      return true;
    }

    // Some environments stringify this as "[object Event]"; only suppress if
    // it happened right after a cable connection attempt.
    var ageMs = Date.now() - _lastCableAttemptAt;
    var reasonText = String(reason);
    if (reasonText.indexOf('[object Event]') !== -1 && ageMs >= 0 && ageMs < 3000) {
      return true;
    }

    return false;
  }

  function _installUnhandledRejectionGuard() {
    if (window.__mbeditorCableRejectionGuardInstalled) return;
    window.__mbeditorCableRejectionGuardInstalled = true;
    window.addEventListener('unhandledrejection', function (event) {
      if (_isCableRelatedRejection(event.reason)) {
        // Keep cable handshake failures internal; polling fallback remains active.
        event.preventDefault();
      }
    });
  }

  function _scheduleReconnect() {
    if (_reconnectTimer || !_serverSupportsWs || _connected) return;
    var delay = _reconnectDelay();
    _reconnectAttempts += 1;
    _reconnectTimer = setTimeout(function () {
      _reconnectTimer = null;
      _attemptConnect();
      // Keep trying: _attemptConnect only fires once, so without this a failed
      // attempt that never reaches `rejected` or `disconnected` would end the
      // retry chain and leave the editor permanently offline.
      _scheduleReconnect();
    }, delay);
  }

  function _attemptConnect() {
    if (!_serverSupportsWs || !_isActionCableAvailable() || _connected || _subscription) {
      return;
    }

    _lastCableAttemptAt = Date.now();
    if (_status !== 'rejected') _status = 'connecting';

    try {
      _consumer = _getConsumer();
      _subscription = _consumer.subscriptions.create(
        { channel: 'Mbeditor::EditorChannel' },
        {
          connected: function () {
            _connected = true;
            _status = 'connected';
            // Back to fast retries for the next blip.
            _reconnectAttempts = 0;
            if (_reconnectTimer) { clearTimeout(_reconnectTimer); _reconnectTimer = null; }
          },
          disconnected: function () {
            _status = _status === 'rejected' ? 'rejected' : 'dropped';
            _cleanupConsumer();
            _scheduleReconnect();
          },
          rejected: function () {
            _status = 'rejected';
            _cleanupConsumer();
            _scheduleReconnect();
          },
          received: function (data) {
            if (!data) return;
            if (data.type === 'files_changed') {
              _emitFilesChanged(data);
            } else if (data.type === 'file_saved') {
              _emitFileSaved(data);
            } else if (data.type === 'presence') {
              _emitPresence(data);
            } else if (data.type === 'log') {
              _emitLogLines(data);
            } else if (data.type === 'exception') {
              _emitException(data);
            }
          }
        }
      );
    } catch (e) {
      // Any setup error means we silently stay in polling-only mode for now.
      _cleanupConsumer();
      _scheduleReconnect();
    }
  }

  function _emitFilesChanged(data) {
    _filesChangedCallbacks.forEach(function (fn) {
      try { fn(data); } catch (e) { /* ignore */ }
    });
  }

  function _emitFileSaved(data) {
    _fileSavedCallbacks.forEach(function (fn) {
      try { fn(data); } catch (e) { /* ignore */ }
    });
  }

  function _emitPresence(data) {
    _presenceCallbacks.forEach(function (fn) {
      try { fn(data); } catch (e) { /* ignore */ }
    });
  }

  function _emitLogLines(data) {
    _logLinesCallbacks.forEach(function (fn) {
      try { fn(data); } catch (e) { /* ignore */ }
    });
  }

  // Host-app exceptions go out as a DOM event rather than a callback list:
  // the Problems panel mounts and unmounts, so it subscribes and unsubscribes
  // with its own lifecycle rather than registering here at boot.
  function _emitException(data) {
    try {
      window.dispatchEvent(new CustomEvent('mbeditor:exception', { detail: data }));
    } catch (e) { /* CustomEvent unavailable; the panel still polls on open */ }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  // Call once after the workspace response is received.
  // serverSupportsWs: boolean from workspace.actionCableEnabled
  function connect(serverSupportsWs) {
    _serverSupportsWs = !!serverSupportsWs;
    if (!_serverSupportsWs || !_isActionCableAvailable()) {
      _status = 'unsupported';
      return; // polling remains the only refresh mechanism
    }
    _installUnhandledRejectionGuard();
    _attemptConnect();
    _scheduleReconnect();
  }

  function disconnect() {
    _serverSupportsWs = false;
    if (_reconnectTimer) {
      clearTimeout(_reconnectTimer);
      _reconnectTimer = null;
    }
    _cleanupConsumer();
  }

  // Returns true only when the WebSocket is currently live.
  function isConnected() {
    return _connected;
  }

  // Coarse state of the editor's own cable subscription, for the collaboration
  // diagnostics panel.
  function cableStatus() {
    return _status;
  }

  // Returns true when ActionCable is loaded and the server advertised cable
  // support. Collaboration uses this as its up-front "is the feature available?"
  // gate, independent of whether the EditorChannel handshake has completed yet.
  function isCableAvailable() {
    return _serverSupportsWs && _isActionCableAvailable();
  }

  // Open a CollaborationChannel subscription for one file on the SHARED consumer
  // (the same connection the EditorChannel uses).  Returns the subscription, or
  // null when cable is unavailable so callers can stay in single-user mode.
  // handlers: { connected, received, rejected, disconnected } — all optional.
  function subscribeCollaboration(path, handlers) {
    if (!isCableAvailable()) return null;
    handlers = handlers || {};
    try {
      if (!_consumer) {
        _consumer = _getConsumer();
      }
      return _consumer.subscriptions.create(
        { channel: 'Mbeditor::CollaborationChannel', path: path },
        {
          connected: function () { if (handlers.connected) handlers.connected(); },
          disconnected: function () { if (handlers.disconnected) handlers.disconnected(); },
          rejected: function () { if (handlers.rejected) handlers.rejected(); },
          received: function (data) { if (handlers.received) handlers.received(data); }
        }
      );
    } catch (e) {
      return null;
    }
  }

  // Register a callback to be invoked when the server broadcasts files_changed.
  function onFilesChanged(fn) {
    _filesChangedCallbacks.push(fn);
  }

  // Remove a previously registered callback.
  function offFilesChanged(fn) {
    _filesChangedCallbacks = _filesChangedCallbacks.filter(function (f) { return f !== fn; });
  }

  // Register a callback to be invoked when a peer saves a file (file_saved).
  // The callback receives the broadcast data, including the relative `path`.
  function onFileSaved(fn) {
    _fileSavedCallbacks.push(fn);
  }

  // Remove a previously registered file_saved callback.
  function offFileSaved(fn) {
    _fileSavedCallbacks = _fileSavedCallbacks.filter(function (f) { return f !== fn; });
  }

  // Register a callback for presence heartbeats/leaves relayed on the global
  // stream. The callback receives {type:'presence', status, client_id, ...}.
  function onPresence(fn) {
    _presenceCallbacks.push(fn);
  }

  // Remove a previously registered presence callback.
  function offPresence(fn) {
    _presenceCallbacks = _presenceCallbacks.filter(function (f) { return f !== fn; });
  }

  // Register a callback invoked when the server transmits a { type: 'log' } message.
  function onLogLines(fn) {
    _logLinesCallbacks.push(fn);
  }

  function offLogLines(fn) {
    _logLinesCallbacks = _logLinesCallbacks.filter(function (f) { return f !== fn; });
  }

  // Send a server-side channel action (e.g. 'save_state').
  // Returns true if the message was dispatched, false if not connected.
  function perform(action, data) {
    if (!_subscription || !_connected) return false;
    try {
      _subscription.perform(action, data);
      return true;
    } catch (e) {
      return false;
    }
  }

  return {
    connect: connect,
    disconnect: disconnect,
    isConnected: isConnected,
    cableStatus: cableStatus,
    isCableAvailable: isCableAvailable,
    subscribeCollaboration: subscribeCollaboration,
    perform: perform,
    onFilesChanged: onFilesChanged,
    offFilesChanged: offFilesChanged,
    onFileSaved: onFileSaved,
    offFileSaved: offFileSaved,
    onPresence: onPresence,
    offPresence: offPresence,
    onLogLines: onLogLines,
    offLogLines: offLogLines
  };
})();
