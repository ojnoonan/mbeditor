'use strict';

var FileHistoryPanel = function FileHistoryPanel(_ref) {
  var path = _ref.path;
  var onSelectCommit = _ref.onSelectCommit;
  var onClose = _ref.onClose;

  var _React$useState = React.useState([]),
      _React$useState2 = _slicedToArray(_React$useState, 2),
      commits = _React$useState2[0],
      setCommits = _React$useState2[1];

  var _React$useState3 = React.useState(true),
      _React$useState4 = _slicedToArray(_React$useState3, 2),
      loading = _React$useState4[0],
      setLoading = _React$useState4[1];

  var _React$useState5 = React.useState(null),
      _React$useState6 = _slicedToArray(_React$useState5, 2),
      error = _React$useState6[0],
      setError = _React$useState6[1];

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
    'div',
    { className: 'ide-file-history' },
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
        { className: 'ide-loading-state' },
        React.createElement('i', { className: 'fas fa-spinner fa-spin' }),
        ' Loading history...'
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
  );
};

window.FileHistoryPanel = FileHistoryPanel;
