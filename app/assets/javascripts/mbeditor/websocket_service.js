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

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  function _isActionCableAvailable() {
    return typeof window.ActionCable !== 'undefined';
  }

  function _getConsumer() {
    // Reuse an existing consumer the host app may have already created (App.cable
    // is the Rails default).  Fall back to creating our own.
    if (typeof window.App !== 'undefined' && window.App.cable) {
      return window.App.cable;
    }
    var cableUrl = window.MBEDITOR_CABLE_URL || '/cable';
    return window.ActionCable.createConsumer(cableUrl);
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
    if (!serverSupportsWs || !_isActionCableAvailable()) {
      return; // polling remains the only refresh mechanism
    }

    try {
      _consumer = _getConsumer();
      _subscription = _consumer.subscriptions.create(
        { channel: 'Mbeditor::EditorChannel' },
        {
          connected: function () {
            _connected = true;
          },
          disconnected: function () {
            _connected = false;
          },
          rejected: function () {
            _connected = false;
            // Channel was rejected — unsubscribe so we stop trying.
            if (_subscription) {
              _subscription.unsubscribe();
              _subscription = null;
            }
          },
          received: function (data) {
            if (data && data.type === 'files_changed') {
              _emitFilesChanged(data);
            }
          }
        }
      );
    } catch (e) {
      // Any setup error means we silently stay in polling-only mode.
      _connected = false;
      _subscription = null;
    }
  }

  function disconnect() {
    if (_subscription) {
      _subscription.unsubscribe();
      _subscription = null;
    }
    _connected = false;
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
