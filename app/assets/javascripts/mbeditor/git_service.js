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
    // A full git_info means the repository moved — commit, branch switch, or an
    // external change. That is exactly when a file's last-commit answer can
    // differ, so this is where the per-file history cache is dropped.
    clearHistoryCache();
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

  // Collapses a run of working-tree changes into one /git_info fan-out once
  // the run stops. A branch change is NOT routed through here — that is rare,
  // user-visible, and escalates immediately.
  var GIT_INFO_REFRESH_DEBOUNCE_MS = 1500;
  var _infoRefreshTimer = null;

  function _scheduleInfoRefresh() {
    if (_infoRefreshTimer) clearTimeout(_infoRefreshTimer);
    _infoRefreshTimer = setTimeout(function () {
      _infoRefreshTimer = null;
      fetchInfo();
    }, GIT_INFO_REFRESH_DEBOUNCE_MS);
  }

  // Cheap steady-state poll: hits /git_status (2 git subprocesses) and only
  // escalates to the expensive /git_info fan-out when something actually
  // changed — an external branch switch or a working-tree change. Rich fields
  // from the last full fetch (unpushedCommits, branchCommits, ...) are
  // preserved rather than clobbered.
  // opts.background marks the 5s poll, which is dropped while the server is
  // unreachable rather than failing over and over in the console.
  function fetchStatusLite(opts) {
    var cfg = (opts && opts.background) ? { mbeditorBackground: true } : {};
    return axios.get(window.mbeditorBasePath() + '/git_status', cfg)
      .then(function(res) {
        var data = res.data;
        if (!data || !data.ok) return fetchInfo();

        var st = EditorStore.getState();
        var prevInfo = st.gitInfo;
        var files = data.files || [];
        var gitSig = function(arr) { return arr.map(function(f) { return f.path + '\x00' + f.status; }).join('\x01'); };
        var branchChanged = (data.branch || "") !== (st.gitBranch || "");
        var treeChanged = gitSig(files) !== gitSig(st.gitFiles || []);

        // A checkout rewrites the working tree wholesale, and nothing else
        // tells the editor: the files_changed push only ever announces
        // mbeditor's own writes, and the 10s poll refreshes the tree's shape,
        // not the contents behind open tabs. So every buffer stayed on the old
        // branch's text until something happened to touch it. Announce it and
        // let the app re-read what it is showing.
        if (branchChanged && st.gitBranch) {
          window.dispatchEvent(new CustomEvent('mbeditor:branch-changed', {
            detail: { from: st.gitBranch, to: data.branch || "" }
          }));
        }

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
          // Trailing debounce, because this is the escalation that hurts.
          // Saving a file changes the porcelain signature by definition, so
          // saving a run of files fired the full fan-out — four-plus git
          // subprocesses on the server, the most expensive request the editor
          // makes — once per save, each one arriving while the previous was
          // still running. The cheap fields above are what the badges and the
          // file list actually read; the rich ones (ahead/behind, base branch,
          // unpushed commits) are not worth a fan-out per keystroke-save and
          // are perfectly happy to land once the burst is over.
          _scheduleInfoRefresh();
          return data;
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
  //
  // Two different duplications get collapsed here, both measured:
  //
  //   - Concurrent calls share one flight. The tint effect re-runs as a freshly
  //     opened tab's content version settles, so every file open fired two
  //     identical `git diff` subprocesses about 8ms apart.
  //   - A just-resolved result is reused for a moment afterwards. Creating a
  //     file fetches once when the new tab mounts and again when the server's
  //     broadcast for that same write arrives ~150ms later; both describe the
  //     identical on-disk state.
  //
  // The reuse window is only safe because any local write drops the entry
  // (invalidateLineDiff, called from noteLocalSave). That is what makes this
  // exact rather than a guess: the window can only ever merge two fetches with
  // no write between them, so a save always gets a fresh diff — which matters,
  // because a save's broadcast is the *only* thing that refreshes the tint.
  //
  // ponytail: an external write landing within the window right after an
  // unrelated fetch of the same file can still serve one stale tint; the 10s
  // poll heals it. Thread the write's timestamp through the broadcast if that
  // ever shows up in practice.
  var LINE_DIFF_REUSE_MS = 400;
  var _lineDiffFlights = {};

  function fetchLineDiff(path) {
    var entry = _lineDiffFlights[path];
    if (entry && (entry.resolvedAt === null || Date.now() - entry.resolvedAt < LINE_DIFF_REUSE_MS)) {
      return entry.promise;
    }

    var self = { resolvedAt: null, promise: null };
    var drop = function () { if (_lineDiffFlights[path] === self) delete _lineDiffFlights[path]; };
    self.promise = axios.get(window.mbeditorBasePath() + '/git/line_diff?file=' + encodeURIComponent(path))
      .then(function (res) { self.resolvedAt = Date.now(); return res.data; },
            // A failure is never reused — drop it so the next call retries.
            function (err) { drop(); throw err; });

    _lineDiffFlights[path] = self;
    return self.promise;
  }

  // Called whenever this client writes the file, so the next tint request goes
  // back to git instead of reusing a pre-write answer.
  function invalidateLineDiff(path) {
    delete _lineDiffFlights[path];
  }

  // Which commit last touched this file, for the status bar.
  //
  // Cached per path because the caller keys on the active tab id, so every tab
  // activation re-ran `git log` for that file — including switching straight
  // back to a tab you just left. The answer only moves when the repository
  // does, and tab switching never refreshes git_info, so flicking between
  // files is now free. The cached value is the promise itself, which makes
  // concurrent callers share one flight as well.
  //
  // Dropped wholesale by clearHistoryCache() below, from applyGitInfo — a
  // commit, a branch switch and an external change all produce a full git_info,
  // so anything that can change the answer already clears this.
  var _fileHistoryCache = {};

  function fetchFileHistory(path) {
    var hit = _fileHistoryCache[path];
    if (hit) return hit;

    var flight = axios.get(window.mbeditorBasePath() + '/git/file_history?file=' + encodeURIComponent(path))
      .then(function (res) { return res.data; },
            // A failure must not be cached, or one blip pins the error until
            // the next git event.
            function (err) { delete _fileHistoryCache[path]; throw err; });

    _fileHistoryCache[path] = flight;
    return flight;
  }

  function clearHistoryCache() {
    _fileHistoryCache = {};
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
    invalidateLineDiff: invalidateLineDiff,
    fetchFileHistory: fetchFileHistory,
    fetchCommitGraph: fetchCommitGraph,
    fetchCommitDetail: fetchCommitDetail
  };
})();
