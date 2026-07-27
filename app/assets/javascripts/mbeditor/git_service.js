var GitService = (function () {
  function applyGitInfo(data) {
    var files = data.workingTree || data.files || [];
    var current = EditorStore.getState().gitFiles;
    var stateUpdate = {
      gitBranch: data.branch || "",
      gitInfo: data,
      gitInfoError: null
    };
    var gitSig = function(arr) { return arr.map(function(f) { return f.path + '\x00' + f.status; }).join('\x01'); };
    if (gitSig(files) !== gitSig(current)) {
      stateUpdate.gitFiles = files;
    }
    EditorStore.setState(stateUpdate);
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

  // Cheap steady-state poll: hits /git_status (2 git subprocesses) and only
  // escalates to the expensive /git_info fan-out when something actually
  // changed — an external branch switch or a working-tree change. Rich fields
  // from the last full fetch (unpushedCommits, branchCommits, ...) are
  // preserved rather than clobbered.
  function fetchStatusLite() {
    return axios.get(window.mbeditorBasePath() + '/git_status')
      .then(function(res) {
        var data = res.data;
        if (!data || !data.ok) return fetchInfo();

        var st = EditorStore.getState();
        var prevInfo = st.gitInfo;
        var files = data.files || [];
        var gitSig = function(arr) { return arr.map(function(f) { return f.path + '\x00' + f.status; }).join('\x01'); };
        var branchChanged = (data.branch || "") !== (st.gitBranch || "");
        var treeChanged = gitSig(files) !== gitSig(st.gitFiles || []);

        // No full snapshot yet, or the branch changed under us (external
        // `git checkout`) — run the full fan-out.
        if (!prevInfo || !prevInfo.ok || branchChanged) return fetchInfo();

        if (treeChanged) {
          // Patch the cheap fields immediately for responsiveness, then
          // refresh the rich fields in the background.
          EditorStore.setState({
            gitBranch: data.branch || "",
            gitFiles: files,
            gitInfo: Object.assign({}, prevInfo, { branch: data.branch || "", workingTree: files }),
            gitInfoError: null
          });
          return fetchInfo();
        }

        return data;
      })
      .catch(function () {}); // transient poll errors retry on the next tick
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

  // Per-line add/modify/delete ranges for one file, used to tint line numbers.
  function fetchLineDiff(path) {
    return axios.get(window.mbeditorBasePath() + '/git/line_diff?file=' + encodeURIComponent(path)).then(function(res) {
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
    fetchStatusLite: fetchStatusLite,
    fetchInfo: fetchInfo,
    fetchDiff: fetchDiff,
    fetchBlame: fetchBlame,
    fetchLineDiff: fetchLineDiff,
    fetchFileHistory: fetchFileHistory,
    fetchCommitGraph: fetchCommitGraph,
    fetchCommitDetail: fetchCommitDetail
  };
})();
