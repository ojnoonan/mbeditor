'use strict';

var GitPanel = function GitPanel(_ref) {
  var gitInfo = _ref.gitInfo;
  var error = _ref.error;
  var onOpenFile = _ref.onOpenFile;

  var workingTree = gitInfo && gitInfo.workingTree || [];
  var unpushedFiles = gitInfo && gitInfo.unpushedFiles || [];
  var branchCommits = gitInfo && gitInfo.branchCommits || [];

  var statusMeta = function statusMeta(rawStatus) {
    var raw = (rawStatus || '').trim();
    if (raw === '??') return { badge: 'NEW', cssKey: 'A', description: 'Untracked local file (not committed yet)' };
    if (raw.startsWith('R')) return { badge: 'R', cssKey: 'R', description: 'Renamed' };

    switch (raw.charAt(0)) {
      case 'M':
        return { badge: 'M', cssKey: 'M', description: 'Modified' };
      case 'A':
        return { badge: 'A', cssKey: 'A', description: 'Added' };
      case 'D':
        return { badge: 'D', cssKey: 'D', description: 'Deleted' };
      case 'U':
        return { badge: 'U', cssKey: 'Q', description: 'Unmerged/conflict' };
      case 'C':
        return { badge: 'C', cssKey: 'R', description: 'Copied' };
      default:
        return { badge: raw || '?', cssKey: 'Q', description: 'Unknown status' };
    }
  };

  var renderFileList = function renderFileList(items, emptyMessage) {
    if (!items || items.length === 0) {
      return React.createElement(
        'div',
        { className: 'git-empty' },
        emptyMessage
      );
    }

    return React.createElement(
      'div',
      { className: 'git-list' },
      items.map(function (item, idx) {
        var name = (item.path || '').split('/').pop() || item.path;
        var meta = statusMeta(item.status);
        var statusClass = 'git-' + meta.cssKey;
        return React.createElement(
          'div',
          { key: item.path + '-' + idx, className: 'git-file-item', onClick: function () {
              return onOpenFile(item.path, name);
            } },
          React.createElement(
            'span',
            { className: 'git-status-badge ' + statusClass, title: meta.description },
            meta.badge
          ),
          React.createElement(
            'span',
            { className: 'git-file-path', title: item.path },
            item.path
          ),
          React.createElement(
            'span',
            { className: 'git-file-status-label', title: meta.description },
            meta.description
          )
        );
      })
    );
  };

  return React.createElement(
    'aside',
    { className: 'ide-git-panel', 'aria-label': 'Git panel' },
    React.createElement(
      'div',
      { className: 'ide-git-panel-header' },
      React.createElement(
        'div',
        null,
        React.createElement(
          'div',
          { className: 'ide-git-panel-title' },
          'Git'
        ),
        React.createElement(
          'div',
          { className: 'ide-git-panel-branch' },
          gitInfo && gitInfo.branch || 'unknown branch'
        )
      )
    ),
    error && React.createElement(
      'div',
      { className: 'git-error' },
      error
    ),
    React.createElement(
      'div',
      { className: 'git-metadata' },
      React.createElement(
        'div',
        null,
        'Ahead: ',
        gitInfo && gitInfo.ahead || 0
      ),
      React.createElement(
        'div',
        null,
        'Behind: ',
        gitInfo && gitInfo.behind || 0
      ),
      React.createElement(
        'div',
        null,
        'Upstream: ',
        gitInfo && gitInfo.upstreamBranch || 'none'
      )
    ),
    React.createElement(
      'div',
      { className: 'git-section' },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        'Working Tree Changes (',
        workingTree.length,
        ')'
      ),
      React.createElement(
        'div',
        { className: 'git-hint' },
        '`NEW` means the file is local/untracked and not committed yet.'
      ),
      renderFileList(workingTree, 'No working tree changes.')
    ),
    React.createElement(
      'div',
      { className: 'git-section' },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        'Unpushed File Changes (',
        unpushedFiles.length,
        ')'
      ),
      renderFileList(unpushedFiles, 'No unpushed file changes.')
    ),
    React.createElement(
      'div',
      { className: 'git-section git-commit-section' },
      React.createElement(
        'div',
        { className: 'git-section-title' },
        'Branch Commit Titles (',
        branchCommits.length,
        ')'
      ),
      branchCommits.length === 0 ? React.createElement(
        'div',
        { className: 'git-empty' },
        'No commits on this branch.'
      ) : React.createElement(
        'div',
        { className: 'git-list' },
        branchCommits.map(function (commit) {
          return React.createElement(
            'div',
            { key: commit.hash, className: 'git-commit-item', title: commit.hash },
            React.createElement(
              'div',
              { className: 'git-commit-title' },
              commit.title
            ),
            React.createElement(
              'div',
              { className: 'git-commit-meta' },
              (commit.hash || '').slice(0, 7),
              ' · ',
              commit.author
            )
          );
        })
      )
    )
  );
};

window.GitPanel = GitPanel;