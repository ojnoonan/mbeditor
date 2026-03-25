var SearchService = (function () {
  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

  var _miniSearch = new MiniSearch({
    fields: ['path', 'name'], // indexed fields
    storeFields: ['path', 'name'] // returned fields
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
            docs.push({ id: idCounter++, path: n.path, name: n.name });
          } else if (n.children) {
            traverse(n.children);
          }
        });
      }

      traverse(snapshot);
      _miniSearch.removeAll();
      _miniSearch.addAll(docs);
    });
  }

  function searchFiles(query) {
    if (!query) return [];
    return _miniSearch.search(query, { prefix: true, fuzzy: 0.2 });
  }

  function projectSearch(query) {
    if (!query) return Promise.resolve({ results: [], capped: false });
    return axios.get(basePath() + '/search', { params: { q: query } })
      .then(function(res) {
        var data = res.data;
        // Handle both old array response and new {results, capped} shape
        var results = Array.isArray(data) ? data : (data && data.results || []);
        var capped = !Array.isArray(data) && !!(data && data.capped);
        EditorStore.setState({ searchResults: results, searchCapped: capped });
        return { results: results, capped: capped };
      })
      .catch(function(err) {
        EditorStore.setStatus("Search failed: " + err.message, "error");
        return { results: [], capped: false };
      });
  }

  return {
    buildIndex: buildIndex,
    searchFiles: searchFiles,
    projectSearch: projectSearch
  };
})();
