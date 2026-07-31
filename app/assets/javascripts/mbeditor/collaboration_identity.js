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
  var _stored = _load();         // { name, installId } persisted in the browser
  var _listeners = [];           // notified when the effective identity changes

  // A presence participant is one tab/cable connection, so the client id is minted
  // once per page load (NOT persisted — two tabs of the same profile are two
  // distinct participants). Used to key the status-bar presence roster.
  var _clientId = _mintClientId();

  function _mintId() {
    try {
      if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    } catch (e) { /* fall through to Math.random */ }
    return 'c-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  function _mintClientId() {
    return _mintId();
  }

  function _load() {
    var obj = null;
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (raw) {
        var parsed = JSON.parse(raw);
        if (parsed && typeof parsed.name === 'string' && parsed.name) obj = parsed;
      }
    } catch (e) { /* storage unavailable / corrupt — fall through */ }

    obj = obj || { name: _generateName() };
    // Persistent per-browser id, distinct from the per-load client id. The colour
    // is seeded from this so it survives a reload: seeding it from the client id
    // meant every refresh handed you a new colour, and your peers watched your
    // caret change hue for no reason. Backfilled for identities stored before
    // this existed.
    if (typeof obj.installId !== 'string' || !obj.installId) {
      obj.installId = _mintId();
    }
    _persist(obj);
    return obj;
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

  // Stable string hash (djb2) → palette index.
  //
  // Seeded on the persisted install id — not the name, and not the per-load client
  // id. Both of those were tried and both were wrong in opposite directions:
  // hashing the name gave two participants sharing a display name the same colour,
  // making their carets indistinguishable exactly when you most need to tell them
  // apart (and the generated name is one of only 128 adjective+role pairs, a host
  // app's user_name_callback can legitimately return the same name twice, and two
  // tabs of one browser share the stored name outright); hashing the client id
  // fixed that but re-rolled the colour on every page load, so a reload changed
  // your caret's hue in front of everyone you were pairing with.
  // A peer's colour arrives from another machine and is interpolated into a
  // stylesheet to draw their caret, so it is a trust boundary: without this,
  // a colour of `red;} html{display:none} .x{` closes the rule and injects
  // arbitrary CSS into your editor. Accept a hex literal or nothing.
  var HEX_COLOR = /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i;
  var FALLBACK_COLOR = '#888888';

  function safeColor(value) {
    return HEX_COLOR.test(String(value || '')) ? String(value) : FALLBACK_COLOR;
  }

  function _hash(seed) {
    var h = 5381;
    for (var i = 0; i < seed.length; i++) h = ((h << 5) + h + seed.charCodeAt(i)) | 0;
    return Math.abs(h);
  }

  function _colorFor(seed) {
    return PALETTE[_hash(seed) % PALETTE.length];
  }

  function _effectiveName() {
    if (_serverName) return _serverName;
    return _stored.name;
  }

  var _color = _colorFor(_stored.installId);
  // Published so a colour clash resolves the same way on both sides *and* the same
  // way after a reload. Deriving it from the install id rather than sending the id
  // itself keeps a persistent browser identifier off the wire; all the tie-break
  // needs is a stable number to compare.
  var _seed = _hash(_stored.installId);

  function get() {
    return { clientId: _clientId, name: _effectiveName(), color: _color, seed: _seed };
  }

  // Hashing alone still collides: 10 palette entries and 5 participants is a ~70%
  // chance some pair matches. The colour has to be picked *against* the roster,
  // which only exists after connecting — so mint from the hash, then reconcile
  // here whenever the roster changes.
  //
  // Called by every client on the same roster, so the rule has to be one both
  // sides of a clash compute identically or they swap forever: on a collision the
  // higher seed yields and the lower keeps its colour. Two yielders can briefly
  // grab the same free slot; the next roster change re-runs this and the same
  // tie-break settles it, so it converges rather than oscillating.
  //
  // Ordered on the persisted seed, falling back to the per-load client id only
  // when seeds match (two tabs of one browser, which share stored identity). Using
  // the client id as the primary key would decide the yielder afresh on every
  // reload, so a clashing pair swapped colours each time either of them refreshed
  // — the same churn that seeding the colour per-load caused.
  //
  // peers: [{ clientId, color, seed }] — the current roster, excluding us.
  function _yieldsTo(peer) {
    var mine = _seed;
    var theirs = typeof peer.seed === 'number' ? peer.seed : -1;
    if (theirs !== mine) return theirs < mine;
    return String(peer.clientId) < _clientId;
  }

  function reconcileColor(peers) {
    if (!peers || !peers.length) return;

    var clash = peers.some(function (p) {
      return p.color === _color && _yieldsTo(p);
    });
    if (!clash) return;

    var taken = {};
    peers.forEach(function (p) { if (p.color) taken[p.color] = true; });
    var free = PALETTE.filter(function (c) { return !taken[c]; });
    // More participants than colours — a duplicate is unavoidable, so keep ours
    // rather than churn. The hover card names who is who.
    if (!free.length) return;

    var next = free[_seed % free.length];
    if (next === _color) return;
    _color = next;
    _notify();
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
    safeColor: safeColor,
    setName: setName,
    setServerName: setServerName,
    reconcileColor: reconcileColor,
    editName: editName,
    onChange: onChange
  };
})();
