var GitService = (function () {
  function applyGitInfo(data) {
    var files = data.workingTree || data.files || [];
    EditorStore.setState({
      gitFiles: files,
      gitBranch: data.branch || "",
      gitInfo: data,
      gitInfoError: null
    });
  }

  function fetchInfo() {
    return axios.get(window.mbeditorBasePath() + '/git_info')
      .then(function(res) {
        if (res.data && res.data.ok) {
          applyGitInfo(res.data);
        } else {
          EditorStore.setState({ gitInfoError: (res.data && res.data.error) || 'Failed to load git info' });
        }
        return res.data;
      })
      .catch(function(err) {
        EditorStore.setState({ gitInfoError: err.message || 'Failed to load git info' });
        EditorStore.setStatus("Failed to fetch git info: " + err.message, "error");
      });
  }

  function fetchStatus() {
    return fetchInfo().then(function(data) {
      if (data && data.ok) return data;

      return axios.get(window.mbeditorBasePath() + '/git_status')
      .then(function(res) {
        if (res.data.ok) {
          EditorStore.setState({
            gitFiles: res.data.files,
            gitBranch: res.data.branch || "",
            gitInfo: {
              ok: true,
              branch: res.data.branch || "",
              workingTree: res.data.files || [],
              unpushedFiles: [],
              unpushedCommits: [],
              branchCommits: []
            },
            gitInfoError: null
          });
        }
        return res.data;
      })
      .catch(function(err) {
        EditorStore.setStatus("Failed to fetch git status: " + err.message, "error");
      });
    });
  }

  function fetchDiff(path, baseSha, headSha) {
    var query = '?file=' + encodeURIComponent(path);
    if (baseSha) query += '&base=' + encodeURIComponent(baseSha);
    if (headSha) query += '&head=' + encodeURIComponent(headSha);
    
    return axios.get(window.mbeditorBasePath() + '/git/diff' + query).then(function(res) {
      return res.data;
    });
  }

  function fetchBlame(path) {
    return axios.get(window.mbeditorBasePath() + '/git/blame?file=' + encodeURIComponent(path)).then(function(res) {
      return res.data;
    });
  }

  function fetchFileHistory(path) {
    return axios.get(window.mbeditorBasePath() + '/git/file_history?file=' + encodeURIComponent(path)).then(function(res) {
      return res.data;
    });
  }

  function fetchCommitGraph() {
    return axios.get(window.mbeditorBasePath() + '/git/commit_graph').then(function(res) {
      return res.data;
    });
  }

  function fetchCommitDetail(sha) {
    return axios.get(window.mbeditorBasePath() + '/git/commit_detail?sha=' + encodeURIComponent(sha)).then(function(res) {
      return res.data;
    });
  }

  return {
    fetchStatus: fetchStatus,
    fetchInfo: fetchInfo,
    fetchDiff: fetchDiff,
    fetchBlame: fetchBlame,
    fetchFileHistory: fetchFileHistory,
    fetchCommitGraph: fetchCommitGraph,
    fetchCommitDetail: fetchCommitDetail
  };
})();
