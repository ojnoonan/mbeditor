var GitPanel = function GitPanel(_ref) {
  var gitInfo = _ref.gitInfo;
  var error = _ref.error;
  var redmineEnabled = _ref.redmineEnabled;
  var onOpenFile = _ref.onOpenFile;
  var onOpenDiff = _ref.onOpenDiff;
  var onOpenAllChanges = _ref.onOpenAllChanges;
  var onRefresh = _ref.onRefresh;
  var onClose = _ref.onClose;

  var useState = React.useState;
  var useEffect = React.useEffect;

  var _s1 = useState(true);  var localExpanded  = _s1[0]; var setLocalExpanded  = _s1[1];
  var _s2 = useState(true);  var branchExpanded = _s2[0]; var setBranchExpanded = _s2[1];
  var _s3 = useState(true);  var historyExpanded= _s3[0]; var setHistoryExpanded= _s3[1];
  // { [hash]: true|false }
  var _s4 = useState({});    var expandedCommits = _s4[0]; var setExpandedCommits = _s4[1];
  // { [hash]: { loading, files: [{status,path}], error } }
  var _s5 = useState({});    var commitFiles = _s5[0]; var setCommitFiles = _s5[1];
  var _s6 = useState(false); var refreshing = _s6[0]; var setRefreshing = _s6[1];

  // ── Redmine state ───────────────────────────────────────────────────────────
  var _sr1 = useState(null);   var redmineIssue   = _sr1[0]; var setRedmineIssue   = _sr1[1];
  var _sr2 = useState(null);   var redmineError   = _sr2[0]; var setRedmineError   = _sr2[1];
  var _sr3 = useState(false);  var redmineLoading = _sr3[0]; var setRedmineLoading = _sr3[1];
  var _sr4 = useState(true);   var redmineExpanded = _sr4[0]; var setRedmineExpanded = _sr4[1];

  var workingTree     = gitInfo && gitInfo.workingTree     || [];
  var unpushedFiles   = gitInfo && gitInfo.unpushedFiles   || [];
  var unpushedCommits = gitInfo && gitInfo.unpushedCommits || [];
  var upstreamBranch  = gitInfo && gitInfo.upstreamBranch;

  // Build a set of unpushed (local) commit hashes for quick lookup
  var localHashes = {};
  unpushedCommits.forEach(function (c) { if (c && c.hash) localHashes[c.hash] = true; });

  var rawBranchCommits = gitInfo && gitInfo.branchCommits || [];
  var branchCommits = rawBranchCommits.map(function (c) {
    return Object.assign({}, c, { isLocal: !!localHashes[c.hash] });
  });

  // Redmine ticket ID is resolved server-side based on redmine_ticket_source config
  var redmineTicketId = (redmineEnabled && gitInfo && gitInfo.redmineTicketId) || null;

  // Fetch Redmine issue whenever the ticket ID changes
  useEffect(function () {
    if (!redmineEnabled) return;
    if (!redmineTicketId) {
      setRedmineIssue(null);
      setRedmineError(null);
      return;
    }
    setRedmineLoading(true);
    setRedmineIssue(null);
    setRedmineError(null);
    var basePath = (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
    axios.get(basePath + '/redmine/issue/' + redmineTicketId)
      .then(function (res) {
        setRedmineIssue(res.data);
        setRedmineLoading(false);
      })
      .catch(function (err) {
        var msg = (err.response && err.response.data && err.response.data.error) || err.message || 'Failed to load Redmine issue.';
        setRedmineError(msg);
        setRedmineLoading(false);
      });
  }, [redmineEnabled, redmineTicketId]);

  var statusMeta = function statusMeta(rawStatus) {
    var raw = (rawStatus || '').trim();
    if (raw === '??') return { badge: 'NEW', cssKey: 'A', description: 'Untracked' };
    if (raw.startsWith('R')) return { badge: 'R', cssKey: 'R', description: 'Renamed' };
    switch (raw.charAt(0)) {
      case 'M': return { badge: 'M', cssKey: 'M', description: 'Modified' };
      case 'A': return { badge: 'A', cssKey: 'A', description: 'Added' };
      case 'D': return { badge: 'D', cssKey: 'D', description: 'Deleted' };
      case 'U': return { badge: 'U', cssKey: 'Q', description: 'Conflict' };
      case 'C': return { badge: 'C', cssKey: 'R', description: 'Copied' };
      default:  return { badge: raw || '?', cssKey: 'Q', description: 'Unknown' };
    }
  };

  var fileIcon = function fileIcon(filename) {
    return React.createElement('i', { className: (window.getFileIcon ? window.getFileIcon(filename) : 'far fa-file-code') + ' git-file-type-icon' });
  };

  // Renders a file row used in Local Changes and Changes in Branch sections
  var renderFileRow = function renderFileRow(item, baseSha, headSha, showOpen) {
    var parts = (item.path || '').split('/');
    var name = parts.pop() || item.path;
    var dir = parts.join('/');
    var meta = statusMeta(item.status);
    var statusClass = 'git-' + meta.cssKey;
    return React.createElement(
      'div',
      { key: item.path, className: 'git-file-item', style: { cursor: 'pointer' }, onClick: function () { onOpenFile && onOpenFile(item.path, name); } },
      fileIcon(name),
      React.createElement(
        'div',
        { className: 'git-file-info', title: item.path },
        React.createElement('span', { className: 'git-file-name' }, name),
        dir ? React.createElement('span', { className: 'git-file-dir' }, dir) : null
      ),
      (item.added !== undefined || item.removed !== undefined) ? React.createElement(
        'span',
        { className: 'git-diff-counts' },
        item.added !== undefined ? React.createElement('span', { className: 'git-stat-add' }, '+' + item.added) : null,
        item.removed !== undefined ? React.createElement('span', { className: 'git-stat-del' }, '-' + item.removed) : null
      ) : null,
      React.createElement('span', { className: 'git-status-badge ' + statusClass, title: meta.description }, meta.badge),
      React.createElement(
        'div',
        { className: 'git-file-actions' },
        showOpen ? React.createElement(
          'button',
          { className: 'git-action-btn', title: 'Open file', onClick: function (e) { e.stopPropagation(); onOpenFile && onOpenFile(item.path, name); } },
          React.createElement('i', { className: 'fas fa-file-code' })
        ) : null,
        React.createElement(
          'button',
          { className: 'git-action-btn', title: 'View diff', onClick: function (e) { e.stopPropagation(); onOpenDiff && onOpenDiff(item.path, name, baseSha, headSha); } },
          React.createElement('i', { className: 'fas fa-exchange-alt' })
        )
      )
    );
  };

  var toggleCommit = function toggleCommit(hash) {
    var nowExpanded = !expandedCommits[hash];
    setExpandedCommits(function (prev) {
      var next = Object.assign({}, prev);
      next[hash] = nowExpanded;
      return next;
    });
    if (nowExpanded && !commitFiles[hash]) {
      setCommitFiles(function (prev) {
        var next = Object.assign({}, prev);
        next[hash] = { loading: true, files: [], error: null };
        return next;
      });
      GitService.fetchCommitDetail(hash).then(function (data) {
        setCommitFiles(function (prev) {
          var next = Object.assign({}, prev);
          next[hash] = { loading: false, files: data.files || [], error: null };
          return next;
        });
      }).catch(function (err) {
        setCommitFiles(function (prev) {
          var next = Object.assign({}, prev);
          next[hash] = { loading: false, files: [], error: err.message || 'Failed to load files' };
          return next;
        });
      });
    }
  };

  var handleRefresh = function handleRefresh() {
    if (!onRefresh || refreshing) return;

    var result;
    try {
      setRefreshing(true);
      result = onRefresh();
    } catch (err) {
      setRefreshing(false);
      throw err;
    }

    return Promise.resolve(result).finally(function () {
      setRefreshing(false);
    });
  };

  var renderCommit = function renderCommit(commit, idx) {
    var isFirst = idx === 0;
    var isLast = idx === branchCommits.length - 1;
    var isExpanded = !!expandedCommits[commit.hash];
    var fd = commitFiles[commit.hash];
    var isLocal = commit.isLocal;
    var colorClass = isLocal ? 'commit-local' : 'commit-pushed';
    var dateObj = new Date(commit.date);
    var dateStr = !isNaN(dateObj) ? dateObj.toLocaleString() : (commit.date || '');

    // Main commit header row
    var headerRow = React.createElement(
      'div',
      { className: 'commit-row ' + colorClass + (isExpanded ? ' commit-expanded' : ''), onClick: function () { toggleCommit(commit.hash); } },
      React.createElement(
        'div',
        { className: 'commit-graph-col' },
        !isFirst && React.createElement('div', { className: 'commit-line-top' }),
        React.createElement('div', { className: 'commit-dot ' + (isLocal ? 'dot-local' : 'dot-pushed') }),
        // Draw bottom line if: not the last commit, OR this commit is expanded (sub-items appear in same wrapper)
        (!isLast || isExpanded) && React.createElement('div', { className: 'commit-line-bottom' })
      ),
      React.createElement(
        'div',
        { className: 'commit-info-col' },
        React.createElement(
          'div',
          { className: 'commit-title', title: commit.title || ('no message \u2014 ' + commit.hash.slice(0, 7)) },
          commit.title
            ? commit.title
            : React.createElement('span', { className: 'commit-title-empty' }, commit.hash.slice(0, 7) + ' \u2014 no message')
        ),
        React.createElement(
          'div',
          { className: 'commit-meta' },
          React.createElement('span', { className: 'commit-hash' }, commit.hash.slice(0, 7)),
          ' \xB7 ',
          React.createElement('span', { className: 'commit-meta-author' }, commit.author),
          ' \xB7 ',
          dateStr
        )
      )
    );

    // Expanded: nested file rows with continued graph line on the left.
    // These are siblings of headerRow inside a wrapper flex-column, so bottom:0 on
    // the header's spine and top:0 on the sub-row's spine connect without any pixel tricks.
    var subItems = [];
    if (isExpanded) {
      var makeSubRow = function makeSubRow(key, extra, children) {
        return React.createElement(
          'div',
          Object.assign({ key: key, className: 'commit-subfile-row git-file-item ' + colorClass }, extra),
          React.createElement('div', { className: 'commit-graph-col' },
            React.createElement('div', { className: 'commit-line-full' })
          ),
          children
        );
      };

      if (!fd || fd.loading) {
        subItems.push(makeSubRow(commit.hash + '-load', {},
          React.createElement('span', { className: 'git-commit-loading' }, 'Loading\u2026')
        ));
      } else if (fd.error) {
        subItems.push(makeSubRow(commit.hash + '-err', {},
          React.createElement('span', { className: 'git-commit-loading' }, fd.error)
        ));
      } else if (fd.files.length === 0) {
        subItems.push(makeSubRow(commit.hash + '-empty', {},
          React.createElement('span', { className: 'git-commit-loading' }, 'No files changed.')
        ));
      } else {
        fd.files.forEach(function (f, fi) {
          var fParts = (f.path || '').split('/');
          var fName = fParts.pop() || f.path;
          var fDir  = fParts.join('/');
          var fStatus = (f.status || '').trim();
          var fCssKey = fStatus === 'M' ? 'M' : fStatus === 'A' ? 'A' : fStatus === 'D' ? 'D' : fStatus.startsWith('R') ? 'R' : 'Q';
          subItems.push(makeSubRow(commit.hash + '-f-' + fi, { style: { cursor: 'pointer' }, onClick: function () { onOpenFile && onOpenFile(f.path, fName); } },
            [
              fileIcon(fName),
              React.createElement(
                'div',
                { key: 'info', className: 'git-file-info', title: f.path },
                React.createElement('span', { className: 'git-file-name' }, fName),
                fDir ? React.createElement('span', { className: 'git-file-dir' }, fDir) : null
              ),
              (f.added !== undefined || f.removed !== undefined) ? React.createElement(
                'span',
                { key: 'counts', className: 'git-diff-counts' },
                f.added !== undefined ? React.createElement('span', { key: 'a', className: 'git-stat-add' }, '+' + f.added) : null,
                f.removed !== undefined ? React.createElement('span', { key: 'r', className: 'git-stat-del' }, '-' + f.removed) : null
              ) : null,
              React.createElement('span', { key: 'badge', className: 'git-status-badge git-' + fCssKey }, fStatus || '?'),
              React.createElement(
                'div',
                { key: 'actions', className: 'git-file-actions' },
                React.createElement(
                  'button',
                  { className: 'git-action-btn', title: 'View diff for this commit', onClick: function (e) { e.stopPropagation(); onOpenDiff && onOpenDiff(f.path, fName, commit.hash + '^', commit.hash); } },
                  React.createElement('i', { className: 'fas fa-exchange-alt' })
                )
              )
            ]
          ));
        });
      }
    }

    // Wrap the header row + sub-items in a single flex-column group.
    // A 6px spacer element at the end of every non-last group draws the
    // spine line through the visual gap between groups.
    return React.createElement(
      'div',
      { key: commit.hash, className: 'commit-group ' + colorClass + (isExpanded ? ' is-expanded' : '') + (isLast ? ' is-last' : '') },
      headerRow,
      subItems,
      !isLast && React.createElement('div', { className: 'commit-spacer ' + colorClass },
        React.createElement('div', { className: 'commit-graph-col' },
          React.createElement('div', { className: 'commit-line-full' })
        )
      )
    );
  };

  // One element per commit (wrapper div)
  var historyRows = branchCommits.map(function (commit, idx) {
    return renderCommit(commit, idx);
  });

  return React.createElement(
    'aside',
    { className: 'ide-git-panel', 'aria-label': 'Git panel' },

    // Header
    React.createElement(
      'div',
      { className: 'ide-git-panel-header' },
      React.createElement(
        'div',
        { className: 'ide-git-panel-header-info' },
        React.createElement('div', { className: 'ide-git-panel-title' }, 'Source Control'),
        React.createElement(
          'div',
          { className: 'ide-git-panel-branch' },
          React.createElement('i', { className: 'fas fa-code-branch', style: { marginRight: '5px', fontSize: '11px', opacity: 0.7 } }),
          gitInfo && gitInfo.branch || 'unknown branch',
          gitInfo && gitInfo.ahead > 0 && React.createElement('span', { className: 'git-ahead-chip', title: gitInfo.ahead + ' ahead' }, '\u2191' + gitInfo.ahead),
          gitInfo && gitInfo.behind > 0 && React.createElement('span', { className: 'git-behind-chip', title: gitInfo.behind + ' behind' }, '\u2193' + gitInfo.behind)
        )
      ),
      React.createElement(
        'div',
        { className: 'ide-git-panel-actions' },
        onRefresh && React.createElement(
          'button',
          { className: 'git-header-btn', onClick: handleRefresh, title: 'Refresh', disabled: refreshing, 'aria-busy': refreshing },
          React.createElement('i', { className: 'fas fa-sync-alt' + (refreshing ? ' fa-spin' : '') })
        ),
        onClose && React.createElement(
          'button',
          { className: 'git-header-btn', onClick: onClose, title: 'Close panel' },
          React.createElement('i', { className: 'fas fa-times' })
        )
      )
    ),

    error && React.createElement('div', { className: 'git-error' }, error),

    // ── Redmine Issue Section ───────────────────────────────────────────────
    redmineEnabled && React.createElement(
      'div',
      { className: 'git-section ' + (redmineExpanded ? 'expanded' : '') + ' git-section--redmine' },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        React.createElement(
          'div',
          { className: 'git-section-title-main hoverable', onClick: function () { setRedmineExpanded(!redmineExpanded); } },
          React.createElement(
            'span',
            { className: 'git-redmine-section-label' },
            React.createElement('i', { className: 'fas ' + (redmineExpanded ? 'fa-chevron-down' : 'fa-chevron-right'), style: { width: '14px', fontSize: '10px' } }),
            '\u2002Redmine',
            redmineTicketId && React.createElement('span', { className: 'git-section-count', style: { marginLeft: '4px' } }, '#' + redmineTicketId)
          ),
          redmineIssue && React.createElement('span', { className: 'redmine-badge redmine-badge--section' }, redmineIssue.status)
        )
      ),
      redmineExpanded && React.createElement(
        'div',
        { className: 'git-redmine-content' },
        redmineLoading
          ? React.createElement('div', { className: 'git-empty' },
              React.createElement('i', { className: 'fas fa-spinner fa-spin', style: { marginRight: '6px' } }),
              'Loading issue\u2026'
            )
          : !redmineTicketId
            ? React.createElement('div', { className: 'git-empty' }, 'No matching ticket found in branch commits.')
            : redmineError
              ? React.createElement('div', { className: 'git-redmine-error' },
                  React.createElement('i', { className: 'fas fa-exclamation-circle', style: { marginRight: '6px', color: '#f48771' } }),
                  redmineError
                )
              : redmineIssue
                ? React.createElement(
                      'div',
                      { className: 'git-redmine-issue' },
                      React.createElement('div', { className: 'git-redmine-title' }, redmineIssue.title),
                      redmineIssue.description
                        ? React.createElement('div', { className: 'git-redmine-desc' }, redmineIssue.description)
                        : null,
                      React.createElement(
                        'div',
                        { className: 'git-redmine-footer' },
                        redmineIssue.author || ''
                      )
                  )
                : null
        )
    ),

    // ── Section 1: Local Changes ────────────────────────────────────────────
    React.createElement(
      'div',
      { className: 'git-section ' + (localExpanded ? 'expanded' : '') },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        React.createElement(
          'div',
          { className: 'git-section-title-main hoverable', onClick: function () { setLocalExpanded(!localExpanded); } },
          React.createElement('i', { className: 'fas ' + (localExpanded ? 'fa-chevron-down' : 'fa-chevron-right'), style: { width: '14px', fontSize: '10px' } }),
          ' Local Changes\u2002',
          React.createElement('span', { className: 'git-section-count' }, workingTree.length)
        ),
        workingTree.length > 0 && React.createElement(
          'button',
          {
            className: 'git-section-action-btn',
            title: 'View all local changes',
            onClick: function (e) { e.stopPropagation(); onOpenAllChanges && onOpenAllChanges('local', 'Local Changes'); }
          },
          React.createElement('i', { className: 'fas fa-layer-group' })
        )
      ),
      localExpanded && React.createElement(
        'div',
        { className: 'git-list' },
        workingTree.length === 0
          ? React.createElement('div', { className: 'git-empty' }, 'No local changes.')
          : workingTree.map(function (item, idx) { return renderFileRow(item, 'HEAD', null, false); })
      )
    ),

    // ── Section 2: Changes in Branch ───────────────────────────────────────
    React.createElement(
      'div',
      { className: 'git-section ' + (branchExpanded ? 'expanded' : '') },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        React.createElement(
          'div',
          { className: 'git-section-title-main hoverable', onClick: function () { setBranchExpanded(!branchExpanded); } },
          React.createElement('i', { className: 'fas ' + (branchExpanded ? 'fa-chevron-down' : 'fa-chevron-right'), style: { width: '14px', fontSize: '10px' } }),
          ' Changes in Branch\u2002',
          React.createElement('span', { className: 'git-section-count' }, unpushedFiles.length)
        ),
        unpushedFiles.length > 0 && React.createElement(
          'button',
          {
            className: 'git-section-action-btn',
            title: 'View all branch changes',
            onClick: function (e) { e.stopPropagation(); onOpenAllChanges && onOpenAllChanges('branch', 'Changes in Branch'); }
          },
          React.createElement('i', { className: 'fas fa-layer-group' })
        )
      ),
      branchExpanded && React.createElement(
        React.Fragment,
        null,
        upstreamBranch
          ? React.createElement('div', { className: 'git-hint' }, 'All files changed vs ', React.createElement('code', null, upstreamBranch))
          : React.createElement('div', { className: 'git-hint' }, 'No upstream branch tracked.'),
        React.createElement(
          'div',
          { className: 'git-list' },
          unpushedFiles.length === 0
            ? React.createElement('div', { className: 'git-empty' }, 'No changes vs upstream.')
            : unpushedFiles.map(function (item) { return renderFileRow(item, upstreamBranch, 'HEAD', true); })
        )
      )
    ),

    // ── Section 3: History ─────────────────────────────────────────────────
    React.createElement(
      'div',
      { className: 'git-section git-history-section ' + (historyExpanded ? 'expanded' : '') },
      React.createElement(
        'div',
        { className: 'git-section-title hoverable', onClick: function () { setHistoryExpanded(!historyExpanded); } },
        React.createElement('i', { className: 'fas ' + (historyExpanded ? 'fa-chevron-down' : 'fa-chevron-right'), style: { width: '14px', fontSize: '10px' } }),
        ' History\u2002',
        React.createElement('span', { className: 'git-section-count' }, branchCommits.length)
      ),
      historyExpanded && React.createElement(
        'div',
        { className: 'git-history-graph-wrap' },
        branchCommits.length === 0
          ? React.createElement('div', { className: 'git-empty' }, 'No commit history.')
          : historyRows
      )
    )
  );
};

window.GitPanel = GitPanel;
