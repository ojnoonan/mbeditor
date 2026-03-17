var FileService = (function () {
  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

  function getTree() {
    return axios.get(basePath() + '/files').then(function(res) { return res.data; });
  }

  function getFile(path) {
    return axios.get(basePath() + '/file', { params: { path: path } }).then(function(res) { return res.data; });
  }

  function saveFile(path, code) {
    return axios.post(basePath() + '/file', { path: path, code: code }).then(function(res) { return res.data; });
  }

  function lintFile(path, code) {
    return axios.post(basePath() + '/lint', { path: path, code: code }).then(function(res) { return res.data; });
  }

  function formatFile(path) {
    return axios.post(basePath() + '/format', { path: path }).then(function(res) { return res.data; });
  }

  function reloadRails() {
    return axios.post(basePath() + '/reload').then(function(res) { return res.data; });
  }

  function getState() {
    return axios.get(basePath() + '/state').then(function(res) { return res.data; });
  }

  function saveState(state) {
    return axios.post(basePath() + '/state', { state: state }).then(function(res) { return res.data; });
  }

  return {
    getTree: getTree,
    getFile: getFile,
    saveFile: saveFile,
    lintFile: lintFile,
    formatFile: formatFile,
    reloadRails: reloadRails,
    getState: getState,
    saveState: saveState
  };
})();
