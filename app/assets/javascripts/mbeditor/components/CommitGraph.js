'use strict';

var CommitGraph = function CommitGraph(_ref) {
  var commits = _ref.commits;
  var onSelectCommit = _ref.onSelectCommit;

  if (!commits || commits.length === 0) {
    return React.createElement(
      'div',
      { className: 'git-empty' },
      'No commit history available.'
    );
  }

  // Very simplified graph rendering for a single branch view.
  // Full cross-branch line rendering in a web UI is complex;
  // here we render a vertical line with dots for each commit.
  return React.createElement(
    'div',
    { className: 'ide-commit-graph' },
    commits.map(function (commit, idx) {
      var isFirst = idx === 0;
      var isLast = idx === commits.length - 1;
      var dateObj = new Date(commit.date);
      var dateStr = !isNaN(dateObj) ? dateObj.toLocaleString() : commit.date;
      var isLocal = commit.isLocal;

      return React.createElement(
        'div',
        {
          key: commit.hash,
          className: 'commit-row ' + (isLocal ? 'commit-local' : ''),
          onClick: function () { return onSelectCommit && onSelectCommit(commit); }
        },
        React.createElement(
          'div',
          { className: 'commit-graph-col' },
          !isFirst && React.createElement('div', { className: 'commit-line-top' }),
          React.createElement('div', { className: 'commit-dot ' + (isLocal ? 'dot-local' : 'dot-pushed') }),
          !isLast && React.createElement('div', { className: 'commit-line-bottom' })
        ),
        React.createElement(
          'div',
          { className: 'commit-info-col' },
          React.createElement(
            'div',
            { className: 'commit-title', title: commit.title },
            commit.title
          ),
          React.createElement(
            'div',
            { className: 'commit-meta' },
            React.createElement('span', { className: 'commit-hash' }, commit.hash.slice(0, 7)),
            ' \xB7 ',
            commit.author,
            ' \xB7 ',
            dateStr
          )
        )
      );
    })
  );
};

window.CommitGraph = CommitGraph;
