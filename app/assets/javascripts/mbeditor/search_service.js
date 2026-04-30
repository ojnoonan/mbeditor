var SearchService = (function () {
  var SEARCH_PAGE_SIZE = 50;

  // --- Result cache ---
  var CACHE_TTL      = 30000; // 30 seconds
  var CACHE_MAX_SIZE = 20;
  var _searchCache   = new Map(); // key -> { data, expiresAt }

  function _cacheKey(query, options, offset) {
    return JSON.stringify([
      query,
      !!options.regex,
      !!options.matchCase,
      !!options.wholeWord,
      offset || 0
    ]);
  }

  function _cacheGet(key) {
    var entry = _searchCache.get(key);
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) {
      _searchCache.delete(key);
      return null;
    }
    return entry.data;
  }

  function _cacheSet(key, data) {
    // FIFO approximation: evict oldest-inserted entry if at capacity (Map preserves insertion order, hits don't move to back)
    if (_searchCache.size >= CACHE_MAX_SIZE && !_searchCache.has(key)) {
      var oldest = _searchCache.keys().next().value;
      _searchCache.delete(oldest);
    }
    _searchCache.set(key, { data: data, expiresAt: Date.now() + CACHE_TTL });
  }

  function invalidate() {
    _searchCache.clear();
  }

  var _miniSearch = new MiniSearch({
    fields: ['path', 'name'],           // indexed fields
    storeFields: ['path', 'name', 'type'] // returned fields (type: 'file'|'dir')
  });

  // Flat doc list kept in sync with _miniSearch so we can do substring lookups.
  var _allDocs = [];

  function buildIndex(treeData) {
    // Capture the tree data immediately so a subsequent refresh doesn't
    // clobber us before the idle callback fires.
    var snapshot = treeData;
    var schedule = window.requestIdleCallback || function(cb) { setTimeout(cb, 50); };
    schedule(function() {
      var docs = [];
      var idCounter = 1;

      function traverse(nodes) {
        nodes.forEach(function(n) {
          if (n.type === 'file') {
            docs.push({ id: idCounter++, path: n.path, name: n.name, type: 'file' });
          } else if (n.type === 'folder') {
            // Always index folders so QuickOpen can show them when the setting is on
            docs.push({ id: idCounter++, path: n.path, name: n.name, type: 'dir' });
            if (n.children) traverse(n.children);
          }
        });
      }

      traverse(snapshot);
      _allDocs = docs.slice();
      _miniSearch.removeAll();
      _miniSearch.addAll(docs);
    });
  }

  // Search files (and optionally folders) in the local MiniSearch index.
  // Also performs a case-insensitive substring scan so that partial-word
  // queries like "project" reliably find "projects_controller.rb".
  // Returns merged results; MiniSearch scored entries come first.
  function searchFiles(query) {
    if (!query) return [];
    var msResults = _miniSearch.search(query, { prefix: true, fuzzy: false, combineWith: 'AND' });
    // Substring fallback — catch anything MiniSearch missed
    var q = query.toLowerCase();
    var msIds = new Set(msResults.map(function(r) { return r.id; }));
    var subResults = _allDocs.filter(function(doc) {
      if (msIds.has(doc.id)) return false;
      return doc.path.toLowerCase().indexOf(q) >= 0 || doc.name.toLowerCase().indexOf(q) >= 0;
    }).map(function(doc) {
      return { id: doc.id, path: doc.path, name: doc.name, type: doc.type, score: 0 };
    });
    return msResults.concat(subResults);
  }

  // Fetch one page of project-wide full-text search results.
  // offset=0 replaces the EditorStore results list; offset>0 appends.
  // The server includes total_count only on offset=0 (fast rg --count pass).
  // options.regex=true enables regex mode on the server.
  function projectSearch(query, offset, limit, options) {
    if (!query) return Promise.resolve({ results: [], hasMore: false, totalCount: 0 });
    var off = (typeof offset === 'number') ? offset : 0;
    var lim = (typeof limit  === 'number') ? limit  : SEARCH_PAGE_SIZE;
    var useRegex = !!(options && options.regex);
    var matchCase = !!(options && options.matchCase);
    var wholeWord = !!(options && options.wholeWord);

    // Check cache before hitting the network
    var key = _cacheKey(query, options, off);
    var cached = _cacheGet(key);
    if (cached) {
      if (off === 0) {
        EditorStore.setState({ searchResults: cached.results, searchHasMore: cached.hasMore });
      } else {
        var prevResults = EditorStore.getState().searchResults || [];
        EditorStore.setState({ searchResults: prevResults.concat(cached.results), searchHasMore: cached.hasMore });
      }
      return Promise.resolve(cached);
    }

    return axios.get(window.mbeditorBasePath() + '/search', {
      params: { q: query, offset: off, limit: lim, regex: useRegex ? 'true' : 'false', match_case: matchCase ? 'true' : 'false', whole_word: wholeWord ? 'true' : 'false' }
    }).then(function(res) {
        var data = res.data;
        var results    = Array.isArray(data) ? data : (data && data.results || []);
        var hasMore    = !Array.isArray(data) && !!(data && data.has_more);
        var totalCount = (data && data.total_count != null) ? data.total_count : null;

        var payload = { results: results, hasMore: hasMore, totalCount: totalCount };
        _cacheSet(key, payload);

        if (off === 0) {
          EditorStore.setState({ searchResults: results, searchHasMore: hasMore });
        } else {
          var prev = EditorStore.getState().searchResults || [];
          EditorStore.setState({ searchResults: prev.concat(results), searchHasMore: hasMore });
        }
        return payload;
      })
      .catch(function(err) {
        EditorStore.setStatus("Search failed: " + err.message, "error");
        return { results: [], hasMore: false, totalCount: null };
      });
  }

  // Fetch a specific page by index without touching EditorStore.
  // Used by the random-access virtual scroll loader.
  function fetchPage(query, pageIndex) {
    if (!query) return Promise.resolve({ results: [], hasMore: false });
    var offset = pageIndex * SEARCH_PAGE_SIZE;
    return axios.get(basePath() + '/search', {
      params: { q: query, offset: offset, limit: SEARCH_PAGE_SIZE }
    }).then(function(res) {
      var data = res.data;
      var results = Array.isArray(data) ? data : (data && data.results || []);
      var hasMore = !Array.isArray(data) && !!(data && data.has_more);
      return { results: results, hasMore: hasMore };
    }).catch(function(err) {
      EditorStore.setStatus("Search failed: " + err.message, "error");
      return { results: [], hasMore: false };
    });
  }

  return {
    buildIndex: buildIndex,
    searchFiles: searchFiles,
    projectSearch: projectSearch,
    fetchPage: fetchPage,
    invalidate: invalidate,
    PAGE_SIZE: SEARCH_PAGE_SIZE
  };
})();
