// CollaborationIdentity — zero-config participant identity for live collaboration
// (slice 5/9, #56).
//
// Every browser gets a friendly display name and a stable colour with no setup:
// generated once, persisted in localStorage, and editable by the user. The host
// app can override the name through the `user_name_callback` config option — that
// resolved value arrives via /client_config and is applied with setServerName().
// Precedence for the effective name is: server name > user/stored name > generated.
//
// The colour is derived deterministically from the effective name against a fixed
// palette, so the same name always renders in the same colour and two peers get
// visibly distinct carets.
var CollaborationIdentity = (function () {
  var STORAGE_KEY = 'mbeditor.collab.identity';

  // Fixed palette — distinct, saturated hues that read against the dark editor
  // background. Index chosen deterministically from the name (see _colorFor).
  var PALETTE = [
    '#e06c75', '#98c379', '#e5c07b', '#61afef', '#c678dd',
    '#56b6c2', '#d19a66', '#be5046', '#7e9cff', '#3fb950'
  ];

  var ADJECTIVES = [
    'Swift', 'Calm', 'Bright', 'Bold', 'Quiet', 'Clever', 'Brave', 'Lucky',
    'Sunny', 'Witty', 'Nimble', 'Mellow', 'Eager', 'Jolly', 'Keen', 'Spry'
  ];
  var ROLES = [
    'Developer', 'Designer', 'Architect', 'Engineer', 'Coder', 'Hacker', 'Builder', 'Debugger',
    'Tester', 'Analyst', 'Maker', 'Pioneer', 'Wizard', 'Operator', 'Scripter', 'Tinkerer'
  ];

  var _serverName = null;        // set by setServerName() from /client_config
  var _stored = _load();         // { name } persisted in the browser
  var _listeners = [];           // notified when the effective identity changes

  // A presence participant is one tab/cable connection, so the client id is minted
  // once per page load (NOT persisted — two tabs of the same profile are two
  // distinct participants). Used to key the status-bar presence roster.
  var _clientId = _mintClientId();

  function _mintClientId() {
    try {
      if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    } catch (e) { /* fall through to Math.random */ }
    return 'c-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  function _load() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (raw) {
        var obj = JSON.parse(raw);
        if (obj && typeof obj.name === 'string' && obj.name) return obj;
      }
    } catch (e) { /* storage unavailable / corrupt — fall through */ }
    var generated = { name: _generateName() };
    _persist(generated);
    return generated;
  }

  function _persist(obj) {
    try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(obj)); }
    catch (e) { /* private mode / quota — identity still works in-memory */ }
  }

  function _generateName() {
    var a = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
    var n = ROLES[Math.floor(Math.random() * ROLES.length)];
    return a + ' ' + n;
  }

  // Stable string hash (djb2) → palette index. Deterministic across clients so a
  // given name always maps to the same colour.
  function _colorFor(name) {
    var h = 5381;
    for (var i = 0; i < name.length; i++) h = ((h << 5) + h + name.charCodeAt(i)) | 0;
    return PALETTE[Math.abs(h) % PALETTE.length];
  }

  function _effectiveName() {
    if (_serverName) return _serverName;
    return _stored.name;
  }

  function get() {
    var name = _effectiveName();
    return { clientId: _clientId, name: name, color: _colorFor(name) };
  }

  function _notify() {
    var id = get();
    _listeners.forEach(function (cb) {
      try { cb(id); } catch (e) { /* a bad listener must not break the others */ }
    });
  }

  // Host-app override (from user_name_callback via /client_config). A blank value
  // clears the override and falls back to the stored/generated name.
  function setServerName(name) {
    var next = (typeof name === 'string' && name.trim()) ? name.trim() : null;
    if (next === _serverName) return;
    _serverName = next;
    _notify();
  }

  // User edit of their own display name. Persisted; clears any server override so
  // the user's explicit choice wins for the rest of the session.
  function setName(name) {
    var clean = (typeof name === 'string') ? name.trim() : '';
    if (!clean) return;
    _stored = { name: clean };
    _persist(_stored);
    _serverName = null;
    _notify();
  }

  // Prompt-based editor wired to the status-bar presence chip. Returns nothing;
  // listeners pick up the change and push it onto live awareness.
  function editName() {
    var current = get().name;
    var next = window.prompt('Your collaboration name', current);
    if (next != null) setName(next);
  }

  // Subscribe to identity changes (name or colour). Returns an unsubscribe fn.
  function onChange(cb) {
    if (typeof cb !== 'function') return function () {};
    _listeners.push(cb);
    return function () {
      var i = _listeners.indexOf(cb);
      if (i !== -1) _listeners.splice(i, 1);
    };
  }

  return {
    get: get,
    setName: setName,
    setServerName: setServerName,
    editName: editName,
    onChange: onChange
  };
})();
