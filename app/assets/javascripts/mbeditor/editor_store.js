// EditorStore — central state store for the browser IDE
// All state lives here; UI subscribes via listeners.
var EditorStore = (function () {
  var _state = {
    panes: [
      { id: 1, tabs: [], activeTabId: null },
      { id: 2, tabs: [], activeTabId: null }
    ],
    focusedPaneId: 1, // which pane currently has focus
    activeTabId: null, // alias for backwards compat/easy access to the currently focused tab in the focused pane
    gitFiles:      [],   // [{ status, path }]
    gitBranch:     "",
    gitInfo:       null,
    gitInfoError:  null,
    searchResults: [],
    searchCapped: false,
    statusMessage: { text: "", kind: "info" },
    pendingReloads: [],
    canUndo: false,
    canRedo: false,
  };

  var _listeners = [];
  var _statusTimer = null;

  function getState() { return _state; }

  function subscribe(fn) {
    _listeners.push(fn);
    return function unsubscribe() {
      _listeners = _listeners.filter(function (l) { return l !== fn; });
    };
  }

  function emit() {
    _listeners.forEach(function (fn) { fn(_state); });
  }

  function setState(patch) {
    _state = Object.assign({}, _state, patch);
    emit();
  }

  // Subscribe to changes in a specific subset of state keys.
  // The listener is only called when at least one of the watched keys changes
  // by reference (===), preventing unnecessary re-renders for unrelated updates.
  // IMPORTANT: all state updates MUST produce a new object reference for any
  // nested value (use Object.assign / spread — never mutate in place), otherwise
  // subscribeToSlice will not detect the change.
  function subscribeToSlice(keys, fn) {
    var prev = {};
    keys.forEach(function(k) { prev[k] = _state[k]; });
    return subscribe(function(newState) {
      var changed = keys.some(function(k) { return newState[k] !== prev[k]; });
      if (changed) {
        keys.forEach(function(k) { prev[k] = newState[k]; });
        fn(newState);
      }
    });
  }

  function setStatus(text, kind) {
    kind = kind || "info";
    setState({ statusMessage: { text: text, kind: kind } });
    if (_statusTimer !== null) {
      clearTimeout(_statusTimer);
      _statusTimer = null;
    }
    if (kind !== "error") {
      _statusTimer = setTimeout(function () {
        _statusTimer = null;
        if (_state.statusMessage.text === text) {
          setState({ statusMessage: { text: "", kind: "info" } });
        }
      }, 4000);
    }
  }

  return { getState: getState, subscribe: subscribe, subscribeToSlice: subscribeToSlice, setState: setState, setStatus: setStatus };
})();
