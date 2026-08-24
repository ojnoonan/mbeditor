"use strict";

var _React = React;
var useState = _React.useState;
var useEffect = _React.useEffect;
var useRef = _React.useRef;

// ── localStorage helpers ───────────────────────────────────────────────────

var RECENT_KEY = 'mbeditor_recent_searches';
var FAVS_KEY   = 'mbeditor_favourites';

function loadRecentSearches() {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY)) || []; } catch (e) { return []; }
}
function saveRecentSearches(list) {
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(list)); } catch (e) {}
}
function loadFavourites() {
  try { return JSON.parse(localStorage.getItem(FAVS_KEY)) || []; } catch (e) { return []; }
}
function saveFavourites(list) {
  try { localStorage.setItem(FAVS_KEY, JSON.stringify(list)); } catch (e) {}
}

// ── Component ──────────────────────────────────────────────────────────────

var QuickOpenDialog = function QuickOpenDialog(_ref) {
  var onSelect       = _ref.onSelect;
  var onClose        = _ref.onClose;
  var onSelectFolder = _ref.onSelectFolder;
  var showFolders    = !!_ref.showFolders;

  var _q = useState('');               var query = _q[0];         var setQuery = _q[1];
  var _r = useState([]);               var results = _r[0];       var setResults = _r[1];
  var _i = useState(0);                var selectedIndex = _i[0]; var setSelectedIndex = _i[1];
  var _rs = useState(loadRecentSearches); var recentSearches = _rs[0]; var setRecentSearches = _rs[1];
  var _fv = useState(loadFavourites);  var favourites = _fv[0];   var setFavourites = _fv[1];

  var inputRef = useRef(null);

  // ── Helpers ──────────────────────────────────────────────────────────────

  function addToRecent(q) {
    if (!q || !q.trim()) return;
    var next = [q].concat(recentSearches.filter(function (s) { return s !== q; })).slice(0, 5);
    setRecentSearches(next);
    saveRecentSearches(next);
  }

  function toggleFavourite(path, e) {
    e && e.stopPropagation();
    var next;
    if (favourites.indexOf(path) >= 0) {
      next = favourites.filter(function (p) { return p !== path; });
    } else {
      next = [path].concat(favourites);
    }
    setFavourites(next);
    saveFavourites(next);
  }

  function isFavourite(path) {
    return favourites.indexOf(path) >= 0;
  }

  function handleSelect(path, name) {
    addToRecent(query);
    onSelect(path, name);
  }

  var clearQuery = function clearQuery() {
    setQuery('');
    setResults([]);
    setSelectedIndex(0);
    if (inputRef.current) inputRef.current.focus();
  };

  // Priority tier for a file path: lower = shown first.
  // Order: controller > model > helper > concern > view > job > other > noise
  function getFilePriority(path) {
    var p = (path || '').toLowerCase();
    if (p.indexOf('/controllers/') >= 0) return 1;
    if (p.indexOf('/models/')      >= 0) return 2;
    if (p.indexOf('/helpers/')     >= 0) return 3;
    if (p.indexOf('/concerns/')    >= 0) return 4;
    if (p.indexOf('/views/')       >= 0) return 5;
    if (p.indexOf('/jobs/')        >= 0) return 6;
    // Deprioritise: migrations, schema, compiled assets, vendor, lock files
    if (p.indexOf('/migrate/')  >= 0 || p.indexOf('schema.rb') >= 0) return 90;
    if (p.indexOf('/public/')   >= 0 || p.indexOf('/vendor/')   >= 0) return 91;
    if (p.slice(-7)  === '.min.js' || p.slice(-8) === '.min.css' ||
        p.slice(-4)  === '.map'    || p.slice(-5) === '.lock')        return 92;
    return 50;
  }

  // Recently opened files, most recent first, as a path -> rank lookup. Built
  // once per query rather than per comparison, since the sort calls this for
  // every pair.
  function recentRanks() {
    var ranks = {};
    var recent = (typeof TabManager !== 'undefined' && TabManager.getRecentFiles)
      ? TabManager.getRecentFiles() : [];
    recent.forEach(function (entry, index) {
      var path = typeof entry === 'string' ? entry : (entry && entry.path);
      if (path && !(path in ranks)) ranks[path] = index;
    });
    return ranks;
  }

  // Match relevance within a priority tier: exact basename > prefix > substring > other.
  function getMatchRelevance(result, q) {
    if (!q) return 3;
    var name = (result.name || (result.path || '').split('/').pop() || '').toLowerCase();
    var lq = q.toLowerCase();
    if (name === lq)            return 0;
    if (name.slice(0, lq.length) === lq) return 1;
    if (name.indexOf(lq) >= 0)  return 2;
    return 3;
  }

  var getQuickOpenIcon = function getQuickOpenIcon(path, name, type) {
    if (type === 'dir') {
      return React.createElement('i', { className: 'fas fa-folder quick-open-result-icon quick-open-folder-icon', 'aria-hidden': 'true' });
    }
    var iconClass = window.getFileIcon ? window.getFileIcon(path || name || '') : 'far fa-file-code';
    return React.createElement('i', { className: iconClass + ' quick-open-result-icon', 'aria-hidden': 'true' });
  };

  // ── Effects ──────────────────────────────────────────────────────────────

  useEffect(function () {
    if (inputRef.current) inputRef.current.focus();
  }, []);

  useEffect(function () {
    if (!query) {
      setResults([]);
      setSelectedIndex(0);
      return;
    }
    // Debounced: a MiniSearch query plus a linear pass and a sort over every
    // path in the workspace ran on every keystroke, between the keypress and
    // the character appearing.
    var timer = setTimeout(function () {
      var res = SearchService.searchFiles(query);
      // Filter by type: always include files; include dirs only when showFolders is on
      var filtered = showFolders ? res : res.filter(function(r) { return r.type !== 'dir'; });
      // Sort, in order of precedence:
      //   1. match quality — exact basename > prefix > substring > other, so a
      //      worse match can never jump the queue however recently it was opened
      //   2. how recently the file was opened, most recent first
      //   3. the static file-type tier (controller > model > … > noise)
      //
      // Recency sits above the type tier deliberately: when two files match a
      // query equally well, the one you were just working in is almost always
      // the one you meant, and that beats a guess made from the directory name.
      // Files never opened all tie here and fall through to the type tier, which
      // is what orders the bulk of a cold result list.
      //
      // Directories keep their +100 penalty inside the type tier so files still
      // come first. JS sort is stable in modern engines, so MiniSearch's own
      // relevance order remains the final tiebreaker.
      var ranks = recentRanks();
      var NEVER_OPENED = Infinity;
      filtered.sort(function(a, b) {
        var aRelevance = getMatchRelevance(a, query);
        var bRelevance = getMatchRelevance(b, query);
        if (aRelevance !== bRelevance) return aRelevance - bRelevance;
        var aRecent = a.path in ranks ? ranks[a.path] : NEVER_OPENED;
        var bRecent = b.path in ranks ? ranks[b.path] : NEVER_OPENED;
        if (aRecent !== bRecent) return aRecent - bRecent;
        var aPriority = getFilePriority(a.path) + (a.type === 'dir' ? 100 : 0);
        var bPriority = getFilePriority(b.path) + (b.type === 'dir' ? 100 : 0);
        return aPriority - bPriority;
      });
      setResults(filtered.slice(0, 200));
      setSelectedIndex(0);
    }, 120);
    return function () { clearTimeout(timer); };
  }, [query, showFolders]);

  // ── Keyboard ─────────────────────────────────────────────────────────────

  var handleKeyDown = function handleKeyDown(e) {
    if (e.key === 'Escape') { onClose(); return; }
    if (query) {
      if (e.key === 'ArrowDown') { setSelectedIndex(function (i) { return Math.min(i + 1, results.length - 1); }); return; }
      if (e.key === 'ArrowUp')   { setSelectedIndex(function (i) { return Math.max(i - 1, 0); }); return; }
      if (e.key === 'Enter' && results[selectedIndex]) {
        var res = results[selectedIndex];
        if (res.type === 'dir') {
          addToRecent(query);
          if (onSelectFolder) onSelectFolder(res.path);
          onClose();
        } else {
          handleSelect(res.path, res.name);
        }
      }
    }
  };

  // ── Render helpers ────────────────────────────────────────────────────────

  function renderStarBtn(path) {
    var starred = isFavourite(path);
    return React.createElement(
      'button',
      {
        type: 'button',
        className: 'quick-open-star-btn' + (starred ? ' starred' : ''),
        title: starred ? 'Remove from favourites' : 'Add to favourites',
        onClick: function (e) { toggleFavourite(path, e); }
      },
      React.createElement('i', { className: starred ? 'fas fa-star' : 'far fa-star' })
    );
  }

  function renderFavouritesSection() {
    if (favourites.length === 0) return null;
    var rows = favourites.map(function (path) {
      var parts = path.split('/');
      var name = parts[parts.length - 1] || path;
      return React.createElement(
        'div',
        {
          key: 'fav-' + path,
          className: 'quick-open-result',
          onClick: function () { onSelect(path, name); }
        },
        getQuickOpenIcon(path, name),
        React.createElement(
          'div',
          { className: 'quick-open-result-body' },
          React.createElement('div', { className: 'quick-open-result-name' }, name),
          React.createElement('div', { className: 'quick-open-result-path' }, path)
        ),
        renderStarBtn(path)
      );
    });
    return React.createElement(
      'div',
      { className: 'quick-open-section' },
      React.createElement('div', { className: 'quick-open-section-header' },
        React.createElement('i', { className: 'fas fa-star', style: { marginRight: '6px', fontSize: '10px' } }),
        'Favourites'
      ),
      rows
    );
  }

  function renderRecentSection() {
    if (recentSearches.length === 0) return null;
    var rows = recentSearches.map(function (q) {
      return React.createElement(
        'div',
        {
          key: 'recent-' + q,
          className: 'quick-open-result quick-open-recent-row',
          onClick: function () { setQuery(q); if (inputRef.current) inputRef.current.focus(); }
        },
        React.createElement('i', { className: 'fas fa-history quick-open-result-icon', 'aria-hidden': 'true' }),
        React.createElement(
          'div',
          { className: 'quick-open-result-body' },
          React.createElement('div', { className: 'quick-open-result-name' }, q)
        )
      );
    });
    return React.createElement(
      'div',
      { className: 'quick-open-section' },
      React.createElement('div', { className: 'quick-open-section-header' },
        React.createElement('i', { className: 'fas fa-history', style: { marginRight: '6px', fontSize: '10px' } }),
        'Recent Searches'
      ),
      rows
    );
  }

  function renderRecentFilesSection() {
    var recentFiles = (typeof TabManager !== 'undefined' && TabManager.getRecentFiles)
      ? TabManager.getRecentFiles() : [];
    if (recentFiles.length === 0) return null;
    var rows = recentFiles.map(function (entry) {
      var path = entry.path;
      var name = entry.name || (path.split('/').pop());
      return React.createElement(
        'div',
        {
          key: 'recentfile-' + path,
          className: 'quick-open-result',
          onClick: function () { onSelect(path, name); }
        },
        getQuickOpenIcon(path, name),
        React.createElement(
          'div',
          { className: 'quick-open-result-body' },
          React.createElement('div', { className: 'quick-open-result-name' }, name),
          React.createElement('div', { className: 'quick-open-result-path' }, path)
        ),
        renderStarBtn(path)
      );
    });
    return React.createElement(
      'div',
      { className: 'quick-open-section' },
      React.createElement('div', { className: 'quick-open-section-header' },
        React.createElement('i', { className: 'fas fa-clock', style: { marginRight: '6px', fontSize: '10px' } }),
        'Recently Opened'
      ),
      rows
    );
  }

  // ── Main render ───────────────────────────────────────────────────────────

  return React.createElement(
    'div',
    { className: 'quick-open-overlay', onClick: onClose },
    React.createElement(
      'div',
      { className: 'quick-open-box', onClick: function (e) { e.stopPropagation(); } },
      React.createElement(
        'div',
        { className: 'quick-open-input-wrap' },
        React.createElement('input', {
          ref: inputRef,
          type: 'text',
          className: 'quick-open-input',
          placeholder: 'Search files by name (Ctrl+P)…',
          value: query,
          onChange: function (e) { setQuery(e.target.value); },
          onKeyDown: handleKeyDown
        }),
        query && React.createElement(
          'button',
          {
            type: 'button',
            className: 'quick-open-clear-btn',
            onClick: clearQuery,
            title: 'Clear search',
            'aria-label': 'Clear search'
          },
          React.createElement('i', { className: 'fas fa-times' })
        )
      ),
      React.createElement(
        'div',
        { className: 'quick-open-results' },
        !query
          ? React.createElement(
              React.Fragment,
              null,
              renderRecentFilesSection(),
              renderFavouritesSection(),
              renderRecentSection(),
              favourites.length === 0 && recentSearches.length === 0 && React.createElement(
                'div',
                { className: 'quick-open-empty-hint' },
                React.createElement('i', { className: 'far fa-star', style: { marginRight: '6px' } }),
                'Star files to add favourites. Recent searches will appear here too.'
              )
            )
          : React.createElement(
              React.Fragment,
              null,
              results.map(function (res, i) {
                var isDir = res.type === 'dir';
                return React.createElement(
                  'div',
                  {
                    key: res.id,
                    className: 'quick-open-result ' + (i === selectedIndex ? 'selected' : '') + (isDir ? ' quick-open-result-dir' : ''),
                    onClick: function () {
                      if (isDir) {
                        addToRecent(query);
                        if (onSelectFolder) onSelectFolder(res.path);
                        onClose();
                      } else {
                        handleSelect(res.path, res.name);
                      }
                    },
                    onMouseEnter: function () { setSelectedIndex(i); }
                  },
                  getQuickOpenIcon(res.path, res.name, res.type),
                  React.createElement(
                    'div',
                    { className: 'quick-open-result-body' },
                    React.createElement('div', { className: 'quick-open-result-name' }, res.name),
                    React.createElement('div', { className: 'quick-open-result-path' }, res.path)
                  ),
                  !isDir && renderStarBtn(res.path)
                );
              }),
              results.length === 0 && React.createElement(
                'div',
                { style: { padding: '12px 16px', color: '#666', fontSize: '12px' } },
                'No matching files.'
              )
            )
      )
    )
  );
};

window.QuickOpenDialog = QuickOpenDialog;
