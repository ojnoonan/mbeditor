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
  var _filesChangedCallbacks = [];
  var _serverSupportsWs = false;
  var _reconnectTimer = null;
  var _lastCableAttemptAt = 0;
  var RECONNECT_INTERVAL_MS = 30000;

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
    if (_reconnectTimer || !_serverSupportsWs) return;
    _reconnectTimer = setTimeout(function () {
      _reconnectTimer = null;
      _attemptConnect();
    }, RECONNECT_INTERVAL_MS);
  }

  function _attemptConnect() {
    if (!_serverSupportsWs || !_isActionCableAvailable() || _connected || _subscription) {
      return;
    }

    _lastCableAttemptAt = Date.now();

    try {
      _consumer = _getConsumer();
      _subscription = _consumer.subscriptions.create(
        { channel: 'Mbeditor::EditorChannel' },
        {
          connected: function () {
            _connected = true;
          },
          disconnected: function () {
            _cleanupConsumer();
            _scheduleReconnect();
          },
          rejected: function () {
            _cleanupConsumer();
            _scheduleReconnect();
          },
          received: function (data) {
            if (data && data.type === 'files_changed') {
              _emitFilesChanged(data);
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

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  // Call once after the workspace response is received.
  // serverSupportsWs: boolean from workspace.actionCableEnabled
  function connect(serverSupportsWs) {
    _serverSupportsWs = !!serverSupportsWs;
    if (!_serverSupportsWs || !_isActionCableAvailable()) {
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

  // Register a callback to be invoked when the server broadcasts files_changed.
  function onFilesChanged(fn) {
    _filesChangedCallbacks.push(fn);
  }

  // Remove a previously registered callback.
  function offFilesChanged(fn) {
    _filesChangedCallbacks = _filesChangedCallbacks.filter(function (f) { return f !== fn; });
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
    perform: perform,
    onFilesChanged: onFilesChanged,
    offFilesChanged: offFilesChanged
  };
})();
