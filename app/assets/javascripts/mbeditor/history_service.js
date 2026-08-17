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

  // Reusing a cached model: the ops already recorded against this key still
  // apply, so an existing base must not be replaced. But the key is per
  // BRANCH, so switching branch (or clearing history) lands here with nothing
  // recorded on either side, and a base-less first flush is a guaranteed
  // "base required for initial history" 400. With no ops pending, the current
  // content IS the base. The server ignores it once history exists.
  function resumeTracking(branch, filePath, baseContent) {
    _tracking[filePath] = { branch: branch };
    var k = _key(branch, filePath);
    _pending[k] = _pending[k] || [];
    if (!_bases.hasOwnProperty(k) && _pending[k].length === 0 && baseContent !== undefined) {
      _bases[k] = baseContent;
    }
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

  function flush(branch, filePath, keepalive) {
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

    // Put the ops — and the base, which this attempt consumed — back so the
    // next flush retries. fetch only rejects on a transport failure, so a
    // rejected POST has to be requeued from the response as well: a 400 used
    // to discard the base along with the ops, and every later flush for that
    // file was then a fresh "base required for initial history" 400. One
    // dropped request permanently disabled persistent undo for the file.
    function requeue() {
      _pending[k] = ops.concat(_pending[k] || []);
      if (body.base !== undefined && !_bases.hasOwnProperty(k)) {
        _bases[k] = body.base;
      }
    }

    try {
      fetch(window.mbeditorBasePath() + '/file_history', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Mbeditor-Client': '1'
        },
        keepalive: keepalive === true,
        body: JSON.stringify(body)
      }).then(function (res) {
        if (!res.ok) requeue();
      })["catch"](requeue);
    } catch (e) {
      requeue();
    }
  }

  function flushAll(options) {
    var keepalive = !!(options && options.keepalive);
    Object.keys(_tracking).forEach(function (filePath) {
      flush(_tracking[filePath].branch, filePath, keepalive);
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
