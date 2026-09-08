'use strict';

var FileHistoryPanel = function FileHistoryPanel(_ref) {
  var path = _ref.path;
  var onSelectCommit = _ref.onSelectCommit;
  var onClose = _ref.onClose;

  var _React$useState = React.useState([]),
      commits = _React$useState[0],
      setCommits = _React$useState[1];

  var _React$useState3 = React.useState(true),
      loading = _React$useState3[0],
      setLoading = _React$useState3[1];

  var _React$useState5 = React.useState(null),
      error = _React$useState5[0],
      setError = _React$useState5[1];

  React.useEffect(function () {
    if (!path) return;
    setLoading(true);
    setError(null);

    GitService.fetchFileHistory(path).then(function (data) {
      setCommits(data.commits || []);
      setLoading(false);
    }).catch(function (err) {
      setError(err.response && err.response.data && err.response.data.error || err.message);
      setLoading(false);
    });
  }, [path]);

  return React.createElement(
    React.Fragment,
    null,
    React.createElement('div', { className: 'ide-modal-backdrop', onClick: onClose }),
    React.createElement(
    'div',
    { className: 'ide-modal-panel' },
    React.createElement(
      'div',
      { className: 'ide-file-history-header' },
      React.createElement(
        'div',
        { className: 'ide-file-history-title' },
        React.createElement('i', { className: 'fas fa-history' }),
        React.createElement(
          'span',
          null,
          'History: ',
          path.split('/').pop()
        )
      ),
      React.createElement(
        'button',
        { className: 'ide-icon-btn', onClick: onClose, title: 'Close History' },
        React.createElement('i', { className: 'fas fa-times' })
      )
    ),
    React.createElement(
      'div',
      { className: 'ide-file-history-content' },
      loading ? React.createElement(
        'div',
        { className: 'ide-loading-state', 'aria-busy': 'true' },
        'Loading history…'
      ) : error ? React.createElement(
        'div',
        { className: 'ide-error-state' },
        error
      ) : commits.length === 0 ? React.createElement(
        'div',
        { className: 'ide-empty-state' },
        'No history found for this file.'
      ) : React.createElement(
        'div',
        { className: 'git-list' },
        commits.map(function (commit) {
          var dateObj = new Date(commit.date);
          var dateStr = !isNaN(dateObj) ? dateObj.toLocaleDateString() + ' ' + dateObj.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : commit.date;
          return React.createElement(
            'div',
            { key: commit.hash, className: 'git-commit-item hoverable', onClick: function () {
                return onSelectCommit && onSelectCommit(commit.hash, path);
              } },
            React.createElement(
              'div',
              { className: 'git-commit-title', title: commit.title },
              commit.title
            ),
            React.createElement(
              'div',
              { className: 'git-commit-meta' },
              React.createElement(
                'span',
                { className: 'commit-hash' },
                commit.hash.slice(0, 7)
              ),
              ' \xB7 ',
              commit.author,
              ' \xB7 ',
              dateStr
            )
          );
        })
      )
    )
  )
  );
};

window.FileHistoryPanel = FileHistoryPanel;
