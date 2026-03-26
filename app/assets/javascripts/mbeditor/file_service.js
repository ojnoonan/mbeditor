// Identify all requests as coming from the mbeditor client.
// The server uses this header to silence editor logs and guard non-GET requests.
axios.defaults.headers.common['X-Mbeditor-Client'] = '1';

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

  function quickFixOffense(path, code, copName) {
    return axios.post(basePath() + '/quick_fix', { path: path, code: code, cop_name: copName }).then(function(res) { return res.data; });
  }

  function formatFile(path) {
    return axios.post(basePath() + '/format', { path: path }).then(function(res) { return res.data; });
  }

  function runTests(path) {
    return axios.post(basePath() + '/test', { path: path }).then(function(res) { return res.data; });
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
    quickFixOffense: quickFixOffense,
    formatFile: formatFile,
    runTests: runTests,
    ping: ping,
    getState: getState,
    saveState: saveState
  };
})();
