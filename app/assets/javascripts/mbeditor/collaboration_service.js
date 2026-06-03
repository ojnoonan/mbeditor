// CollaborationService — realtime collaborative editing (slice 4/9).
//
// Manages one Yjs document per open file and a custom ActionCable provider built
// on WebSocketService's shared consumer, with a y-monaco MonacoBinding rendering
// converged text. The "provider" is just the CollaborationChannel subscription
// plus two glue listeners: outbound (doc.on('update') -> doc_update action) and
// inbound (received -> Y.applyUpdate). Bytes cross the wire as base64 strings;
// the server (CollaborationDocStore) stores them opaquely.
//
// Activation rides on cable presence: when ActionCable is unavailable the module
// is inert and the editor stays exactly as it is today (no binding, native undo).
//
// Scope of slice 4: content convergence + late-join + first-opener seed +
// local-origin-scoped undo. Slice 5 (#56) adds awareness — remote carets,
// selections and labelled participant identity — layered onto the same binding.
// Save/snapshot reconciliation (#57) is still out of scope.
var CollaborationService = (function () {
  // Per-path room. Persistent across tab switches (the Monaco model is reused):
  //   { doc, text, subscription, synced, model, editor, binding, undoManager,
  //     lateJoin, onSeeded, attachRequested, degraded, fallbackTimer,
  //     awareness, editors, cursorDisposers, identityUnsub, seenClients }
  var _rooms = {};

  // Identity tag marking updates that arrived from the wire, so the outbound
  // sender never echoes them back and the local UndoManager never tracks them.
  var REMOTE = {};

  // Follow mode (slice 8): the presence client_id of the participant whose
  // scroll/viewport we're tracking, or null when navigating independently. Set
  // by setFollow()/clearFollow(); read on every awareness change to snap the
  // live editor to their viewport. The matching file-open is driven separately
  // by MbeditorApp from the presence roster's current_file.
  var _followedClientId = null;

  var IMAGE_RE = /\.(png|jpe?g|gif|svg|ico|webp|bmp|avif)$/i;

  // ---------------------------------------------------------------------------
  // base64 <-> Uint8Array (Yjs updates are Uint8Array; ActionCable carries JSON)
  // ---------------------------------------------------------------------------
  function _u8ToB64(u8) {
    var CHUNK = 0x8000;
    var parts = [];
    for (var i = 0; i < u8.length; i += CHUNK) {
      parts.push(String.fromCharCode.apply(null, u8.subarray(i, i + CHUNK)));
    }
    return btoa(parts.join(''));
  }

  function _b64ToU8(b64) {
    var bin = atob(b64);
    var len = bin.length;
    var u8 = new Uint8Array(len);
    for (var i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }

  // ---------------------------------------------------------------------------
  // Gating
  // ---------------------------------------------------------------------------
  function _globalsReady() {
    return typeof window.Y !== 'undefined' &&
           typeof window.MonacoBinding !== 'undefined' &&
           typeof WebSocketService !== 'undefined' &&
           WebSocketService.isCableAvailable();
  }

  // Is collaboration available at all right now? The Yjs globals and the cable
  // connection come up asynchronously after page load, so this can flip from false
  // to true shortly after the editor first mounts. EditorPanel polls it to join
  // already-open tabs once it turns true (path-independent — no per-file checks).
  function isAvailable() {
    return _globalsReady();
  }

  // Synchronous predicate: should this path participate in collaboration at all?
  // Excludes virtual/preview/image paths. EditorPanel uses this up-front to decide
  // whether to suspend its persistent-undo machinery.
  function isEnabledFor(path) {
    if (!path) return false;
    if (path.indexOf('diff://') === 0 || path.indexOf('combined-diff://') === 0) return false;
    if (path.indexOf('::preview') !== -1) return false;
    if (IMAGE_RE.test(path)) return false;
    return _globalsReady();
  }

  // ---------------------------------------------------------------------------
  // Room lifecycle
  // ---------------------------------------------------------------------------

  // Open the Yjs document + channel subscription for a file and start the sync
  // handshake. Idempotent. Returns true when a live room exists (so the caller
  // can gate its own behavior), false when collaboration could not activate.
  function ensureRoom(path) {
    if (_rooms[path]) return true;
    if (!isEnabledFor(path)) return false;

    var doc = new window.Y.Doc();
    var room = {
      doc: doc,
      text: doc.getText('monaco'),
      subscription: null,
      synced: false,
      model: null,
      editor: null,
      binding: null,
      undoManager: null,
      lateJoin: false,
      onSeeded: null,
      attachRequested: false,
      degraded: false,
      fallbackTimer: null,
      // Awareness (slice 5): editors is the LIVE set y-monaco renders remote
      // carets into; cursorDisposers holds our per-editor cursor->awareness
      // writers; seenClients tracks peers we've announced ourselves to.
      // viewportDisposers (slice 8): per-editor scroll->awareness writers, so a
      // follower can track where we've scrolled.
      awareness: null,
      editors: new Set(),
      boundEditor: null,
      broadcastAwareness: null,
      cursorDisposers: new Map(),
      viewportDisposers: new Map(),
      identityUnsub: null,
      seenClients: new Set()
    };

    // Outbound: relay local updates (seed, local edits, local undo/redo) to peers.
    // Updates that came from the wire carry the REMOTE origin and are not re-sent.
    doc.on('update', function (update, origin) {
      if (origin === REMOTE) return;
      if (!room.subscription) return;
      try {
        room.subscription.perform('doc_update', { update: _u8ToB64(update) });
      } catch (e) { /* not connected yet / cable down — peers reconcile on next op */ }
    });

    room.subscription = WebSocketService.subscribeCollaboration(path, {
      received: function (data) { _onMessage(room, data); }
    });

    if (!room.subscription) {
      doc.destroy();
      return false;
    }

    _rooms[path] = room;
    return true;
  }

  function _onMessage(room, data) {
    if (!data || !data.type) return;
    if (data.type === 'sync') {
      // One-shot handshake. Apply any existing server state BEFORE binding so the
      // binding can distinguish first-opener (empty) from late-join (non-empty).
      if (data.snapshot) {
        window.Y.applyUpdate(room.doc, _b64ToU8(data.snapshot), REMOTE);
      }
      if (data.deltas && data.deltas.length) {
        data.deltas.forEach(function (d) {
          if (d) window.Y.applyUpdate(room.doc, _b64ToU8(d), REMOTE);
        });
      }
      room.synced = true;
      _maybeAttach(room);
    } else if (data.type === 'doc_update') {
      if (data.update) window.Y.applyUpdate(room.doc, _b64ToU8(data.update), REMOTE);
    } else if (data.type === 'awareness') {
      if (data.awareness && room.awareness && window.awarenessProtocol) {
        // REMOTE origin keeps the outbound handler from echoing peer state back.
        window.awarenessProtocol.applyAwarenessUpdate(
          room.awareness, _b64ToU8(data.awareness), REMOTE
        );
        _announceToNewPeers(room);
      }
    }
  }

  // Register the current editor/model for a room and request a binding. Called on
  // every editor (re)creation (tab switch recreates the editor; the model and the
  // Yjs doc persist). opts.onSeeded is invoked once the binding has set the model,
  // so EditorPanel can rebaseline its clean-state.
  function bindEditor(path, editor, model, opts) {
    var room = _rooms[path];
    if (!room) return;
    room.editor = editor;
    room.model = model;
    room.onSeeded = (opts && opts.onSeeded) || room.onSeeded;
    room.attachRequested = true;
    _applyUndoKeybindings(room, editor);

    // The editor is recreated on every tab switch while the model (and binding)
    // persist. If the binding already exists, register this fresh editor so its
    // caret broadcasts and remote carets render in it.
    if (room.binding) _attachEditorToBinding(room, editor);

    if (!room.fallbackTimer && !room.binding) {
      // Safety net: if the sync handshake never lands (e.g. channel rejected),
      // stop waiting and let the natively-loaded content stand.
      room.fallbackTimer = setTimeout(function () { _fallbackLocal(room); }, 6000);
    }
    _maybeAttach(room);
  }

  function _maybeAttach(room) {
    if (room.binding || !room.synced || !room.attachRequested || !room.model) return;
    _doAttach(room);
  }

  function _doAttach(room) {
    var model = room.model;
    room.lateJoin = room.text.length > 0; // server already had shared state

    if (!room.lateJoin && model.getValue().length > 0) {
      // First opener whose disk content is already in the model: seed the shared
      // doc from it before constructing the binding, otherwise the binding would
      // overwrite the model to match the (empty) Y.Text and wipe the content.
      room.doc.transact(function () { room.text.insert(0, model.getValue()); });
    }

    // Awareness carries each participant's caret/selection + identity. Optional:
    // if the y-protocols global is missing the editor still converges content,
    // just without remote cursors (matches slice-4 behaviour).
    room.awareness = window.awarenessProtocol
      ? new window.awarenessProtocol.Awareness(room.doc)
      : null;

    // Pass the room's LIVE editors set. y-monaco reads it lazily on every awareness
    // change, so editors added on a later tab switch start rendering remote carets
    // without rebuilding the binding. The set must be NON-EMPTY at construction —
    // y-monaco registers its caret-render listener (and the attach-time editor's
    // caret writer) inside a forEach over the set, so an empty set would render
    // nothing. The attach-time editor (boundEditor) is therefore owned by y-monaco;
    // editors added later get an equivalent caret writer from us.
    room.boundEditor = room.editor || null;
    if (room.boundEditor) room.editors.add(room.boundEditor);
    room.binding = new window.MonacoBinding(room.text, model, room.editors, room.awareness);

    if (room.awareness) _initAwareness(room);

    // Undo scoped to this client's edits only: y-monaco tags model->doc edits with
    // the binding as origin, so undo can never revert a peer's edit.
    room.undoManager = new window.Y.UndoManager(room.text, {
      trackedOrigins: new Set([room.binding])
    });

    // y-monaco owns the bound editor's caret writer but never fires it until the
    // first cursor move — seed the initial caret so peers see us right away.
    if (room.awareness && room.boundEditor) {
      _writeSelection(room, room.boundEditor);
      _wireEditorViewport(room, room.boundEditor);
    }

    if (room.fallbackTimer) { clearTimeout(room.fallbackTimer); room.fallbackTimer = null; }
    if (room.onSeeded) {
      try { room.onSeeded(); } catch (e) { /* rebaseline is best-effort */ }
    }
  }

  // ---------------------------------------------------------------------------
  // Awareness (remote carets, selections, participant identity)
  // ---------------------------------------------------------------------------

  function _userState() {
    var id = (typeof CollaborationIdentity !== 'undefined')
      ? CollaborationIdentity.get()
      : { name: 'Anonymous', color: '#888888', clientId: null };
    // clientId ties this awareness state back to the presence roster entry, so a
    // follower can pick our viewport out of the per-file awareness states.
    return { name: id.name, color: id.color, clientId: id.clientId };
  }

  // Wire a room's awareness once, at binding construction: publish our identity,
  // relay local awareness changes to peers (throttled), keep identity live, and
  // re-render the per-participant caret styles whenever any state changes.
  function _initAwareness(room) {
    // Throttle ALL local awareness broadcasts at the outbound boundary (vendored
    // lodash) — this covers both our own caret writer and y-monaco's caret writer
    // for the attach-time editor, so a fast-moving cursor never floods the channel.
    // Trailing edge guarantees the final resting position lands.
    var send = function () { _sendLocalAwareness(room); };
    room.broadcastAwareness = (window._ && window._.throttle)
      ? window._.throttle(send, 50, { leading: true, trailing: true })
      : send;

    room.awareness.setLocalStateField('user', _userState());

    room.identityUnsub = (typeof CollaborationIdentity !== 'undefined')
      ? CollaborationIdentity.onChange(function () {
          if (room.awareness) room.awareness.setLocalStateField('user', _userState());
        })
      : null;

    // Outbound: peer-applied state carries the REMOTE origin and is never echoed.
    room.awareness.on('update', function (_changes, origin) {
      if (origin === REMOTE) return;
      room.broadcastAwareness();
    });

    room.awareness.on('change', _renderCursorStyles);
    // Follow mode: when a tracked peer's viewport (or presence in this room)
    // changes, snap our editor to match.
    room.awareness.on('change', _applyFollow);
  }

  // Encode our own current awareness state and relay it to peers (one-shot).
  function _sendLocalAwareness(room) {
    if (!room.awareness || !room.subscription) return;
    try {
      var update = window.awarenessProtocol.encodeAwarenessUpdate(
        room.awareness, [room.awareness.clientID]
      );
      room.subscription.perform('awareness', { awareness: _u8ToB64(update) });
    } catch (e) { /* not connected yet — peers reconcile on the next change */ }
  }

  // Register an editor with the binding's live set so remote carets render in it.
  // The attach-time editor (boundEditor) already has its caret writer from y-monaco;
  // editors added later (tab switch) get an equivalent writer from us. Idempotent.
  function _attachEditorToBinding(room, editor) {
    if (!room.binding || !editor || room.editors.has(editor)) return;
    room.editors.add(editor);

    if (room.awareness) {
      if (editor !== room.boundEditor) _wireEditorCursor(room, editor);
      _wireEditorViewport(room, editor);
      // Force y-monaco to paint existing peers' carets into this newly added
      // editor (its decoration pass reads the live set but only runs on change).
      try { room.awareness.emit('change', [{ added: [], updated: [], removed: [] }, 'local']); } catch (e) {}
    }
  }

  // Write an editor's current caret/selection into awareness (Yjs relative
  // positions so peers resolve it against their own copy of the text).
  function _writeSelection(room, editor) {
    if (!room.awareness || editor.getModel() !== room.model) return;
    var sel = editor.getSelection();
    if (!sel) return;
    try {
      var start = room.model.getOffsetAt(sel.getStartPosition());
      var end = room.model.getOffsetAt(sel.getEndPosition());
      room.awareness.setLocalStateField('selection', {
        anchor: window.Y.createRelativePositionFromTypeIndex(room.text, start),
        head: window.Y.createRelativePositionFromTypeIndex(room.text, end)
      });
    } catch (e) { /* position encoding unavailable — caret just won't render */ }
  }

  // Mirror an editor's caret/selection into awareness on every move. Unthrottled
  // here — the outbound broadcast is what's throttled (see _initAwareness).
  function _wireEditorCursor(room, editor) {
    var disposable = editor.onDidChangeCursorSelection(function () {
      _writeSelection(room, editor);
    });
    room.cursorDisposers.set(editor, function () {
      try { disposable.dispose(); } catch (e) { /* ignore */ }
    });
    _writeSelection(room, editor); // publish the initial caret position immediately
  }

  // ---------------------------------------------------------------------------
  // Follow mode (slice 8): publish our viewport; track a followed peer's viewport
  // ---------------------------------------------------------------------------

  // Write an editor's top visible line into awareness. A line number (not a pixel
  // scrollTop) survives differences in font size / zoom / wrapping between peers.
  function _writeViewport(room, editor) {
    if (!room.awareness || editor.getModel() !== room.model) return;
    try {
      var ranges = editor.getVisibleRanges();
      if (!ranges || !ranges.length) return;
      room.awareness.setLocalStateField('viewport', { top: ranges[0].startLineNumber });
    } catch (e) { /* viewport unavailable — a follower just won't track this editor */ }
  }

  // Mirror an editor's viewport into awareness on every scroll. Unthrottled here —
  // the outbound broadcast is throttled (see _initAwareness), like the caret.
  // Wired for EVERY editor including the bound one: y-monaco owns the bound
  // editor's caret writer but never its viewport.
  function _wireEditorViewport(room, editor) {
    if (typeof editor.onDidScrollChange !== 'function') return;
    var disposable = editor.onDidScrollChange(function () { _writeViewport(room, editor); });
    room.viewportDisposers.set(editor, function () {
      try { disposable.dispose(); } catch (e) { /* ignore */ }
    });
    _writeViewport(room, editor); // publish the initial viewport immediately
  }

  // Snap our live editor(s) to the followed peer's viewport. Runs on every
  // awareness change in any room; cheap (small participant counts) and idempotent
  // — re-applying the same scroll position is a no-op. No-op when not following.
  function _applyFollow() {
    if (!_followedClientId) return;
    Object.keys(_rooms).forEach(function (path) {
      var room = _rooms[path];
      if (!room.awareness || room.editors.size === 0) return;
      var mine = room.awareness.clientID;
      room.awareness.getStates().forEach(function (state, cid) {
        if (cid === mine) return;
        var user = state && state.user;
        if (!user || user.clientId !== _followedClientId) return;
        var vp = state.viewport;
        if (!vp || typeof vp.top !== 'number') return;
        room.editors.forEach(function (editor) {
          try { editor.setScrollTop(editor.getTopForLineNumber(vp.top)); }
          catch (e) { /* editor disposed / API missing — skip */ }
        });
      });
    });
  }

  // Begin tracking a participant's viewport (by presence client_id). The matching
  // file-open is MbeditorApp's job (from the roster's current_file); here we only
  // snap scroll to their already-known viewport, if any.
  function setFollow(clientId) {
    _followedClientId = clientId || null;
    _applyFollow();
  }

  // Resume independent navigation.
  function clearFollow() {
    _followedClientId = null;
  }

  // When a peer we haven't greeted appears, re-broadcast our own state so a late
  // joiner sees our caret without waiting for us to move (awareness is not
  // server-persisted; the channel only relays live deltas).
  function _announceToNewPeers(room) {
    if (!room.awareness) return;
    var mine = room.awareness.clientID;
    var fresh = false;
    room.awareness.getStates().forEach(function (_state, cid) {
      if (cid !== mine && !room.seenClients.has(cid)) {
        room.seenClients.add(cid);
        fresh = true;
      }
    });
    if (fresh) _sendLocalAwareness(room);
  }

  // Rebuild the per-participant caret/selection CSS from every room's awareness.
  // Client IDs are globally unique, so one shared <style> element covers all open
  // files. Re-runs on any awareness change (cheap; small participant counts).
  var _styleEl = null;
  function _renderCursorStyles() {
    if (typeof document === 'undefined') return;
    if (!_styleEl) {
      _styleEl = document.createElement('style');
      _styleEl.id = 'mbeditor-collab-cursors';
      document.head.appendChild(_styleEl);
    }
    var seen = {};
    var css = '';
    Object.keys(_rooms).forEach(function (path) {
      var room = _rooms[path];
      if (!room.awareness) return;
      var mine = room.awareness.clientID;
      room.awareness.getStates().forEach(function (state, cid) {
        if (cid === mine || seen[cid]) return;
        var user = state && state.user;
        if (!user || !user.color) return;
        seen[cid] = true;
        var color = String(user.color);
        var name = _cssString(user.name || 'Anonymous');
        css +=
          '.yRemoteSelection-' + cid + '{background-color:' + _hexToRgba(color, 0.30) + ';}' +
          '.yRemoteSelectionHead-' + cid + '{position:absolute;border-left:' + color +
            ' solid 2px;border-bottom:' + color + ' solid 2px;height:100%;box-sizing:border-box;}' +
          '.yRemoteSelectionHead-' + cid + '::after{position:absolute;content:"' + name +
            '";white-space:nowrap;top:-1.4em;left:-2px;font-size:11px;line-height:normal;' +
            'background-color:' + color + ';color:#1e1e2e;padding:0 4px;border-radius:3px;' +
            'font-family:sans-serif;z-index:10;pointer-events:none;}';
      });
    });
    _styleEl.textContent = css;
  }

  function _hexToRgba(hex, alpha) {
    var h = hex.replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var n = parseInt(h, 16);
    if (isNaN(n)) return 'rgba(136,136,136,' + alpha + ')';
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + alpha + ')';
  }

  function _cssString(s) {
    // Neutralise quotes/backslashes/newlines so the name can't break out of the
    // CSS string literal in the generated ::after content.
    return String(s).replace(/[\\"\n\r]/g, function (c) {
      return c === '\n' || c === '\r' ? ' ' : '\\' + c;
    });
  }

  function _applyUndoKeybindings(room, editor) {
    if (!editor || typeof editor.addCommand !== 'function' || !window.monaco) return;
    var KeyMod = window.monaco.KeyMod;
    var KeyCode = window.monaco.KeyCode;
    var undo = function () { if (room.undoManager) room.undoManager.undo(); };
    var redo = function () { if (room.undoManager) room.undoManager.redo(); };
    // Override native Monaco undo/redo so they route through the Yjs UndoManager.
    // The commands die with the editor on dispose, so no explicit teardown.
    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyZ, undo);
    editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyY, redo);
    editor.addCommand(KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.KeyZ, redo);
  }

  function _fallbackLocal(room) {
    room.fallbackTimer = null;
    if (room.binding || room.degraded) return;
    room.degraded = true;
    if (room.onSeeded) {
      try { room.onSeeded(); } catch (e) { /* best-effort */ }
    }
  }

  // True when the room owns the file's content (a late-join applied shared state):
  // EditorPanel must then NOT apply the disk content at open, which would clobber it.
  // Later external on-disk edits are filtered earlier, at the change-detection source
  // (MbeditorApp.checkOpenTabsForExternalChanges), which skips any collab-bound file.
  function consumesDiskLoad(path) {
    var room = _rooms[path];
    return !!(room && room.binding && room.lateJoin);
  }

  // Detach the current editor (tab switch / editor dispose). The binding stays
  // bound to the persistent model, so the room and its undo history survive.
  function unbindEditor(path) {
    var room = _rooms[path];
    if (!room) return;
    var editor = room.editor;
    if (editor) {
      // Detach this editor from the binding so a disposed editor isn't iterated
      // and stops broadcasting a stale caret.
      room.editors.delete(editor);
      var dispose = room.cursorDisposers.get(editor);
      if (dispose) { dispose(); room.cursorDisposers.delete(editor); }
      var disposeVp = room.viewportDisposers.get(editor);
      if (disposeVp) { disposeVp(); room.viewportDisposers.delete(editor); }
    }
    // No editor is showing this file in this pane now — drop our caret/viewport so
    // peers don't render a frozen cursor or a follower track a stale scroll. The
    // doc/binding/awareness survive (the file is still open); a re-bind republishes.
    if (room.awareness && room.editors.size === 0) {
      room.awareness.setLocalStateField('selection', null);
      room.awareness.setLocalStateField('viewport', null);
    }
    room.editor = null;
  }

  // Destroy the room entirely. Called when the Monaco model is actually disposed
  // (file no longer open in any pane), via tab_manager.
  function leaveRoom(path) {
    var room = _rooms[path];
    if (!room) return;
    if (room.fallbackTimer) { clearTimeout(room.fallbackTimer); room.fallbackTimer = null; }
    room.cursorDisposers.forEach(function (dispose) { try { dispose(); } catch (e) { /* ignore */ } });
    room.cursorDisposers.clear();
    room.viewportDisposers.forEach(function (dispose) { try { dispose(); } catch (e) { /* ignore */ } });
    room.viewportDisposers.clear();
    if (room.identityUnsub) { try { room.identityUnsub(); } catch (e) { /* ignore */ } }
    if (room.broadcastAwareness && room.broadcastAwareness.cancel) {
      room.broadcastAwareness.cancel();
    }
    if (room.awareness) {
      // Tell peers our caret is gone before tearing down (file closed). Remove our
      // state, then send the resulting (null-state) update directly — the throttled
      // path can't be trusted to flush before destroy().
      try {
        window.awarenessProtocol.removeAwarenessStates(
          room.awareness, [room.awareness.clientID], 'leave'
        );
        _sendLocalAwareness(room);
      } catch (e) { /* ignore */ }
      try { room.awareness.destroy(); } catch (e) { /* ignore */ }
      room.awareness = null;
    }
    try { if (room.undoManager) room.undoManager.destroy(); } catch (e) { /* ignore */ }
    try { if (room.binding) room.binding.destroy(); } catch (e) { /* ignore */ }
    try { if (room.subscription) room.subscription.unsubscribe(); } catch (e) { /* ignore */ }
    try { if (room.doc) room.doc.destroy(); } catch (e) { /* ignore */ }
    delete _rooms[path];
    _renderCursorStyles();
  }

  function isBound(path) {
    return !!_rooms[path];
  }

  // True once the y-monaco binding is live for a path: the room is sharing the
  // model's content with peers. Distinct from isBound (which is true as soon as
  // the room/subscription exists, before the sync handshake attaches a binding).
  function isAttached(path) {
    var room = _rooms[path];
    return !!(room && room.binding);
  }

  // Push a fresh full snapshot to the server so it can compact the doc store:
  // CollaborationDocStore.replace_snapshot swaps the cached snapshot and clears
  // the buffered deltas. Called after a manual save, when the shared buffer is
  // known to be coherent and matches what just landed on disk. No-op when the
  // file is not collaboratively bound or the wire isn't ready.
  function pushSnapshot(path) {
    var room = _rooms[path];
    if (!room || !room.subscription || !_globalsReady()) return false;
    try {
      var snapshot = window.Y.encodeStateAsUpdate(room.doc);
      room.subscription.perform('snapshot', { snapshot: _u8ToB64(snapshot) });
      return true;
    } catch (e) {
      return false;
    }
  }

  return {
    isAvailable: isAvailable,
    isEnabledFor: isEnabledFor,
    ensureRoom: ensureRoom,
    bindEditor: bindEditor,
    unbindEditor: unbindEditor,
    leaveRoom: leaveRoom,
    consumesDiskLoad: consumesDiskLoad,
    isBound: isBound,
    isAttached: isAttached,
    pushSnapshot: pushSnapshot,
    setFollow: setFollow,
    clearFollow: clearFollow
  };
})();
