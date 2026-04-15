var SearchService = (function () {
  var SEARCH_PAGE_SIZE = 50;

  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

  var _miniSearch = new MiniSearch({
    fields: ['path', 'name'],           // indexed fields
    storeFields: ['path', 'name', 'type'] // returned fields (type: 'file'|'dir')
  });

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
      _miniSearch.removeAll();
      _miniSearch.addAll(docs);
    });
  }

  // Search files (and optionally folders) in the local MiniSearch index.
  // Returns raw MiniSearch results; caller can filter by .type.
  function searchFiles(query) {
    if (!query) return [];
    return _miniSearch.search(query, { prefix: true, fuzzy: 0.2 });
  }

  // Fetch one page of project-wide full-text search results.
  // offset=0 replaces the EditorStore results list; offset>0 appends.
  function projectSearch(query, offset, limit) {
    if (!query) return Promise.resolve({ results: [], hasMore: false });
    var off = (typeof offset === 'number') ? offset : 0;
    var lim = (typeof limit  === 'number') ? limit  : SEARCH_PAGE_SIZE;

    return axios.get(basePath() + '/search', {
      params: { q: query, offset: off, limit: lim }
    }).then(function(res) {
        var data = res.data;
        var results = Array.isArray(data) ? data : (data && data.results || []);
        var hasMore = !Array.isArray(data) && !!(data && data.has_more);

        if (off === 0) {
          EditorStore.setState({ searchResults: results, searchHasMore: hasMore });
        } else {
          var prev = EditorStore.getState().searchResults || [];
          EditorStore.setState({ searchResults: prev.concat(results), searchHasMore: hasMore });
        }
        return { results: results, hasMore: hasMore };
      })
      .catch(function(err) {
        EditorStore.setStatus("Search failed: " + err.message, "error");
        return { results: [], hasMore: false };
      });
  }

  return {
    buildIndex: buildIndex,
    searchFiles: searchFiles,
    projectSearch: projectSearch,
    PAGE_SIZE: SEARCH_PAGE_SIZE
  };
})();
