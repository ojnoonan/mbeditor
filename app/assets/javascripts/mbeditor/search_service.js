var SearchService = (function () {
  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

  var _miniSearch = new MiniSearch({
    fields: ['path', 'name'], // indexed fields
    storeFields: ['path', 'name'] // returned fields
  });

  function buildIndex(treeData) {
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

    traverse(treeData);
    _miniSearch.removeAll();
    _miniSearch.addAll(docs);
  }

  function searchFiles(query) {
    if (!query) return [];
    return _miniSearch.search(query, { prefix: true, fuzzy: 0.2 });
  }

  function projectSearch(query) {
    if (!query) return Promise.resolve([]);
    return axios.get(basePath() + '/search', { params: { q: query } })
      .then(function(res) {
        EditorStore.setState({ searchResults: res.data });
        return res.data;
      })
      .catch(function(err) {
        EditorStore.setStatus("Search failed: " + err.message, "error");
        return [];
      });
  }

  return {
    buildIndex: buildIndex,
    searchFiles: searchFiles,
    projectSearch: projectSearch
  };
})();
