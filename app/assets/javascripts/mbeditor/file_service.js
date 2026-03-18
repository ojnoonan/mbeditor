var FileService = (function () {
  function basePath() {
    return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
  }

  function getWorkspace() {
    return axios.get(basePath() + '/workspace').then(function(res) { return res.data; });
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

  function createFile(path, code) {
    return axios.post(basePath() + '/create_file', { path: path, code: code || '' }).then(function(res) { return res.data; });
  }

  function createDir(path) {
    return axios.post(basePath() + '/create_dir', { path: path }).then(function(res) { return res.data; });
  }

  function renamePath(path, newPath) {
    return axios.patch(basePath() + '/rename', { path: path, new_path: newPath }).then(function(res) { return res.data; });
  }

  function deletePath(path) {
    return axios.delete(basePath() + '/delete', { data: { path: path } }).then(function(res) { return res.data; });
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

  function ping() {
    return axios.get(basePath() + '/ping', { timeout: 4000 }).then(function(res) { return res.data; });
  }

  function getState() {
    return axios.get(basePath() + '/state').then(function(res) { return res.data; });
  }

  function saveState(state) {
    return axios.post(basePath() + '/state', { state: state }).then(function(res) { return res.data; });
  }

  return {
    getWorkspace: getWorkspace,
    getTree: getTree,
    getFile: getFile,
    saveFile: saveFile,
    createFile: createFile,
    createDir: createDir,
    renamePath: renamePath,
    deletePath: deletePath,
    lintFile: lintFile,
    formatFile: formatFile,
    reloadRails: reloadRails,
    ping: ping,
    getState: getState,
    saveState: saveState
  };
})();
