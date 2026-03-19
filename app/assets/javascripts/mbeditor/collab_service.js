// CollabService — real-time collaborative editing via Action Cable + Y.js CRDT
//
// Usage (called by EditorPanel.js):
//   CollabService.join(filePath, monacoEditor)
//   CollabService.leave(filePath)
//   CollabService.onPeersChange(function(peers) { ... })
//
// Requires: Y (yjs.min.js), ActionCable (action_cable.js) loaded before this file.

var CollabService = (function () {
  // Random user identity for this browser session
  var USER_ID = Math.random().toString(36).slice(2, 10);
  var COLORS = ['#e06c75', '#61afef', '#98c379', '#c678dd', '#e5c07b', '#56b6c2', '#be5046'];
  var USER_COLOR = COLORS[parseInt(USER_ID, 36) % COLORS.length];

  var consumer = null;         // ActionCable consumer
  var sessions = {};           // { filePath: { doc, yText, sub, decorations, remoteApplying } }
  var peersChangeCallback = null;
  var peers = {};              // { userId: { color, cursor } }

  // ---------------------------------------------------------------------------
  // Base64 helpers for binary Y.js updates over Action Cable JSON
  // ---------------------------------------------------------------------------

  function uint8ToBase64(arr) {
    var binary = '';
    for (var i = 0; i < arr.length; i++) {
      binary += String.fromCharCode(arr[i]);
    }
    return btoa(binary);
  }

  function base64ToUint8(str) {
    var binary = atob(str);
    var arr = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      arr[i] = binary.charCodeAt(i);
    }
    return arr;
  }

  // ---------------------------------------------------------------------------
  // Per-user CSS injection for cursor colours
  // ---------------------------------------------------------------------------

  var injectedStyles = {};

  function ensureUserStyle(userId6, color) {
    if (injectedStyles[userId6]) return;
    injectedStyles[userId6] = true;
    var style = document.createElement('style');
    style.textContent =
      '.collab-cursor-' + userId6 + ' { border-left: 2px solid ' + color + '; margin-left: -1px; pointer-events: none; }' +
      '.collab-sel-' + userId6 + ' { background: ' + color + '40 !important; }';
    document.head.appendChild(style);
  }

  // ---------------------------------------------------------------------------
  // Remote cursor rendering
  // ---------------------------------------------------------------------------

  function renderRemoteCursor(editor, msg) {
    if (msg.userId === USER_ID) return;
    var session = findSessionByEditor(editor);
    if (!session) return;

    var userId6 = msg.userId.slice(0, 6);
    ensureUserStyle(userId6, msg.color);

    session.decorations = session.decorations || {};
    var prevIds = session.decorations[msg.userId] || [];

    if (msg.cursor == null) {
      session.decorations[msg.userId] = editor.deltaDecorations(prevIds, []);
      return;
    }

    var model = editor.getModel();
    if (!model) return;

    var newDecorations = [];

    // Cursor caret — 1-char range (or end-of-line) with a left-border class
    var caretPos = model.getPositionAt(msg.cursor);
    var lineLen = model.getLineLength(caretPos.lineNumber);
    var endCol = caretPos.column < lineLen + 1 ? caretPos.column + 1 : caretPos.column;
    newDecorations.push({
      range: new monaco.Range(caretPos.lineNumber, caretPos.column, caretPos.lineNumber, endCol),
      options: {
        inlineClassName: 'collab-cursor-' + userId6,
        hoverMessage: { value: '\\u200b' + msg.userId },
        zIndex: 1
      }
    });

    // Selection highlight
    if (msg.selection != null && msg.selection.start !== msg.selection.end) {
      var s = Math.min(msg.selection.start, msg.selection.end);
      var e = Math.max(msg.selection.start, msg.selection.end);
      var startPos = model.getPositionAt(s);
      var endPos = model.getPositionAt(e);
      newDecorations.push({
        range: new monaco.Range(startPos.lineNumber, startPos.column, endPos.lineNumber, endPos.column),
        options: { inlineClassName: 'collab-sel-' + userId6 }
      });
    }

    session.decorations[msg.userId] = editor.deltaDecorations(prevIds, newDecorations);
  }

  function findSessionByEditor(editor) {
    for (var path in sessions) {
      if (sessions[path].editor === editor) return sessions[path];
    }
    return null;
  }

  function notifyPeersChange() {
    if (peersChangeCallback) {
      peersChangeCallback(Object.keys(peers).map(function (id) {
        return { userId: id, color: peers[id].color };
      }));
    }
  }

  // ---------------------------------------------------------------------------
  // Monaco ↔ Y.Text binding
  // ---------------------------------------------------------------------------

  function bindYTextToMonaco(session) {
    var doc = session.doc;
    var yText = session.yText;
    var editor = session.editor;
    var model = editor.getModel();

    // Y.Text → Monaco: apply remote changes to the Monaco model
    yText.observe(function (event, txn) {
      if (txn.local) return;
      session.remoteApplying = true;
      try {
        var offset = 0;
        event.delta.forEach(function (op) {
          if (op.retain) {
            offset += op.retain;
          } else if (op.insert) {
            var pos = model.getPositionAt(offset);
            editor.executeEdits('collab', [{
              range: new monaco.Range(pos.lineNumber, pos.column, pos.lineNumber, pos.column),
              text: op.insert
            }]);
            offset += op.insert.length;
          } else if (op.delete) {
            var start = model.getPositionAt(offset);
            var end = model.getPositionAt(offset + op.delete);
            editor.executeEdits('collab', [{
              range: new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column),
              text: ''
            }]);
          }
        });
      } finally {
        session.remoteApplying = false;
      }
    });

    // Monaco → Y.Text: propagate local keystrokes to the Y.js document
    session.contentDisposable = model.onDidChangeContent(function (e) {
      if (session.remoteApplying) return;
      doc.transact(function () {
        e.changes.forEach(function (change) {
          yText.delete(change.rangeOffset, change.rangeLength);
          if (change.text) yText.insert(change.rangeOffset, change.text);
        });
      }, 'local');

      // Broadcast cursor position after every keystroke
      broadcastCursor(session);
    });

    // Broadcast cursor on selection change too
    session.selectionDisposable = editor.onDidChangeCursorSelection(function () {
      broadcastCursor(session);
    });
  }

  function broadcastCursor(session) {
    var editor = session.editor;
    var model = editor.getModel();
    if (!model || !session.sub) return;
    var pos = editor.getPosition();
    var sel = editor.getSelection();
    var offset = pos ? model.getOffsetAt(pos) : null;
    var selection = sel ? {
      start: model.getOffsetAt({ lineNumber: sel.startLineNumber, column: sel.startColumn }),
      end: model.getOffsetAt({ lineNumber: sel.endLineNumber, column: sel.endColumn })
    } : null;
    session.sub.perform('broadcast_cursor', {
      userId: USER_ID,
      color: USER_COLOR,
      cursor: offset,
      selection: selection
    });
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  function getConsumer() {
    if (!consumer && window.ActionCable) {
      var basePath = window.MBEDITOR_BASE_PATH || '';
      var url = basePath.replace(/\/mbeditor$/, '') + '/cable';
      console.log('[Collab] creating ActionCable consumer →', url);
      ActionCable.logger.enabled = true;
      consumer = ActionCable.createConsumer(url);
    } else if (!window.ActionCable) {
      console.warn('[Collab] ActionCable not available on window');
    }
    return consumer;
  }

  function join(filePath, editor) {
    if (sessions[filePath]) return; // already joined

    var cable = getConsumer();
    if (!cable) {
      console.warn('[Collab] no consumer — join aborted for', filePath);
      return;
    }

    console.log('[Collab] joining', filePath);

    var doc = new Y.Doc();
    var yText = doc.getText('content');

    var session = {
      doc: doc,
      yText: yText,
      editor: editor,
      sub: null,
      remoteApplying: false,
      decorations: {},
      contentDisposable: null,
      selectionDisposable: null,
      initialized: false
    };

    sessions[filePath] = session;

    function initializeDoc() {
      if (session.initialized) return;
      session.initialized = true;

      if (yText.length === 0) {
        console.log('[Collab] first client — seeding from Monaco');
        var initialContent = editor.getValue() || '';
        if (initialContent) {
          doc.transact(function () { yText.insert(0, initialContent); });
        }
      } else {
        console.log('[Collab] subsequent client — syncing Monaco from Y.js (' + yText.length + ' chars)');
        session.remoteApplying = true;
        try {
          editor.setValue(yText.toString());
        } finally {
          session.remoteApplying = false;
        }
      }

      bindYTextToMonaco(session);
      console.log('[Collab] initialized and bound for', filePath);

      // Announce ourselves — others will reply with their own join
      sub.perform('broadcast_presence', { userId: USER_ID, color: USER_COLOR, status: 'join' });
    }

    var sub = cable.subscriptions.create(
      { channel: 'Mbeditor::DocumentChannel', path: filePath },
      {
        connected: function () {
          console.log('[Collab] subscription connected for', filePath);
          initializeDoc();
        },
        disconnected: function () {
          console.warn('[Collab] subscription disconnected for', filePath);
        },
        rejected: function () {
          console.error('[Collab] subscription REJECTED for', filePath);
        },
        received: function (msg) {
          console.log('[Collab] received', msg.type, filePath);
          if (msg.type === 'sync' && msg.state) {
            Y.applyUpdate(doc, base64ToUint8(msg.state), 'remote');
          } else if (msg.type === 'update' && msg.update) {
            Y.applyUpdate(doc, base64ToUint8(msg.update), 'remote');
          } else if (msg.type === 'cursor') {
            renderRemoteCursor(editor, msg);
          } else if (msg.type === 'presence') {
            if (msg.userId === USER_ID) return;
            if (msg.status === 'join') {
              peers[msg.userId] = { color: msg.color };
              // Announce our own presence back so they know we're here too
              sub.perform('broadcast_presence', { userId: USER_ID, color: USER_COLOR, status: 'join' });
            } else if (msg.status === 'leave') {
              delete peers[msg.userId];
              // Clear their cursor decorations
              var leaveSession = findSessionByEditor(editor);
              if (leaveSession && leaveSession.decorations && leaveSession.decorations[msg.userId]) {
                editor.deltaDecorations(leaveSession.decorations[msg.userId], []);
                delete leaveSession.decorations[msg.userId];
              }
            }
            notifyPeersChange();
          }
        }
      }
    );

    session.sub = sub;

    doc.on('update', function (update, origin) {
      if (origin === 'remote') return;
      console.log('[Collab] broadcasting update, origin=', origin, 'yText=', yText.toString().slice(0, 40));
      sub.perform('broadcast_update', {
        update: uint8ToBase64(update),
        state: uint8ToBase64(Y.encodeStateAsUpdate(doc))
      });
    });
  }

  function leave(filePath) {
    var session = sessions[filePath];
    if (!session) return;

    if (session.contentDisposable) session.contentDisposable.dispose();
    if (session.selectionDisposable) session.selectionDisposable.dispose();
    if (session.sub) {
      session.sub.perform('broadcast_presence', { userId: USER_ID, color: USER_COLOR, status: 'leave' });
      session.sub.unsubscribe();
    }
    session.doc.destroy();

    delete sessions[filePath];

    // Remove this file's peers from the global peer list
    peers = {};
    notifyPeersChange();
  }

  function onPeersChange(cb) {
    peersChangeCallback = cb;
  }

  return {
    join: join,
    leave: leave,
    onPeersChange: onPeersChange,
    userId: USER_ID,
    userColor: USER_COLOR
  };
}());

window.CollabService = CollabService;
