var GitService = (function () {
  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

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
    return axios.get(basePath() + '/git_info')
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

      return axios.get(basePath() + '/git_status')
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

  return { fetchStatus: fetchStatus, fetchInfo: fetchInfo };
})();
