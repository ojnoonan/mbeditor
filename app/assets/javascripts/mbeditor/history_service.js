'use strict';

var HistoryService = (function () {
  // _tracking[filePath] = { branch }
  var _tracking = {};
  // _pending["branch:filePath"] = [[sl,sc,el,ec,text], ...]
  var _pending = {};
  // _bases["branch:filePath"] = "original content" — cleared after first flush
  var _bases = {};
  // _replayingPaths: Set of filePaths currently undergoing Phase 2 replay
  var _replayingPaths = {};
  // _idleTimers["branch:filePath"] = timerHandle
  var _idleTimers = {};

  var IDLE_MS = 30000;

  function _key(branch, filePath) {
    return branch + ':' + filePath;
  }

  function beginTracking(branch, filePath, baseContent) {
    _tracking[filePath] = { branch: branch };
    var k = _key(branch, filePath);
    _pending[k] = _pending[k] || [];
    _bases[k] = baseContent;
  }

  function resumeTracking(branch, filePath) {
    _tracking[filePath] = { branch: branch };
    var k = _key(branch, filePath);
    _pending[k] = _pending[k] || [];
  }

  function stopTracking(filePath) {
    var rec = _tracking[filePath];
    if (!rec) return;
    var k = _key(rec.branch, filePath);
    clearTimeout(_idleTimers[k]);
    delete _idleTimers[k];
    flush(rec.branch, filePath);
    delete _tracking[filePath];
  }

  function setReplayInProgress(filePath, inProgress) {
    if (inProgress) {
      _replayingPaths[filePath] = true;
    } else {
      delete _replayingPaths[filePath];
    }
  }

  function recordOps(filePath, changes) {
    if (_replayingPaths[filePath]) return;
    var rec = _tracking[filePath];
    if (!rec) return;
    var k = _key(rec.branch, filePath);
    var bucket = _pending[k] = _pending[k] || [];
    for (var i = 0; i < changes.length; i++) {
      var c = changes[i];
      bucket.push([
        c.range.startLineNumber,
        c.range.startColumn,
        c.range.endLineNumber,
        c.range.endColumn,
        c.text
      ]);
    }
    clearTimeout(_idleTimers[k]);
    _idleTimers[k] = setTimeout(function () { flush(rec.branch, filePath); }, IDLE_MS);
  }

  function flush(branch, filePath) {
    var k = _key(branch, filePath);
    var ops = _pending[k];
    if (!ops || ops.length === 0) return;
    _pending[k] = [];
    clearTimeout(_idleTimers[k]);
    delete _idleTimers[k];

    var body = { branch: branch, path: filePath, ops: ops };
    if (_bases.hasOwnProperty(k)) {
      body.base = _bases[k];
      delete _bases[k];
    }

    try {
      fetch(window.mbeditorBasePath() + '/file_history', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Mbeditor-Client': '1'
        },
        body: JSON.stringify(body)
      }).catch(function () {
        // On failure, put ops back so next flush retries
        var existing = _pending[k] || [];
        _pending[k] = ops.concat(existing);
        if (body.base !== undefined && !_bases.hasOwnProperty(k)) {
          _bases[k] = body.base;
        }
      });
    } catch (e) {}
  }

  function flushAll(options) {
    var useKeepalive = options && options.keepalive;
    Object.keys(_tracking).forEach(function (filePath) {
      var rec = _tracking[filePath];
      var k = _key(rec.branch, filePath);
      var ops = _pending[k];
      if (!ops || ops.length === 0) return;
      var remaining = ops.slice();
      _pending[k] = [];
      clearTimeout(_idleTimers[k]);
      delete _idleTimers[k];

      var body = { branch: rec.branch, path: filePath, ops: remaining };
      if (_bases.hasOwnProperty(k)) {
        body.base = _bases[k];
        delete _bases[k];
      }

      try {
        fetch(window.mbeditorBasePath() + '/file_history', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Mbeditor-Client': '1'
          },
          keepalive: useKeepalive === true,
          body: JSON.stringify(body)
        });
      } catch (e) {}
    });
  }

  function fetchHistory(branch, filePath) {
    return fetch(
      window.mbeditorBasePath() + '/file_history' +
      '?branch=' + encodeURIComponent(branch) +
      '&path='   + encodeURIComponent(filePath),
      { headers: { 'X-Mbeditor-Client': '1' } }
    ).then(function (res) {
      if (!res.ok) return null;
      return res.json();
    }).then(function (data) {
      if (!data || !data.ops || data.ops.length === 0) return null;
      return data;
    }).catch(function () { return null; });
  }

  // Global flush triggers
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flushAll({});
  });

  window.addEventListener('beforeunload', function () {
    flushAll({ keepalive: true });
  });

  function flushForPath(filePath) {
    var rec = _tracking[filePath];
    if (rec) flush(rec.branch, filePath);
  }

  return {
    beginTracking:       beginTracking,
    resumeTracking:      resumeTracking,
    stopTracking:        stopTracking,
    setReplayInProgress: setReplayInProgress,
    recordOps:           recordOps,
    flush:               flush,
    flushAll:            flushAll,
    flushForPath:        flushForPath,
    fetchHistory:        fetchHistory
  };
})();
