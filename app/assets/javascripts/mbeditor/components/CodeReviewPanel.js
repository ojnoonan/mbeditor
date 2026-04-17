'use strict';

var CodeReviewPanel = function CodeReviewPanel(_ref) {
  var gitInfo = _ref.gitInfo;
  var onClose = _ref.onClose;

  var _React$useState = React.useState(null),
      _React$useState2 = _slicedToArray(_React$useState, 2),
      redmineIssue = _React$useState2[0],
      setRedmineIssue = _React$useState2[1];

  var _React$useState3 = React.useState(null),
      _React$useState4 = _slicedToArray(_React$useState3, 2),
      redmineError = _React$useState4[0],
      setRedmineError = _React$useState4[1];

  var _React$useState5 = React.useState(false),
      _React$useState6 = _slicedToArray(_React$useState5, 2),
      isRedmineLoading = _React$useState6[0],
      setIsRedmineLoading = _React$useState6[1];

  var branchIdMatch = gitInfo && gitInfo.branch && gitInfo.branch.match(/(?:feature|bug|hotfix|task)\/(?:#)?(\d+)/i);
  var issueId = branchIdMatch ? branchIdMatch[1] : null;

  React.useEffect(function () {
    if (!issueId) return;
    setIsRedmineLoading(true);

    // Call the redmine endpoint. It will 503 if disabled via config.
    axios.get(window.mbeditorBasePath() + '/redmine/issue/' + issueId)
      .then(function (res) {
        setRedmineIssue(res.data);
        setIsRedmineLoading(false);
      })
      .catch(function (err) {
        if (err.response && err.response.status !== 503) {
          setRedmineError(err.response.data.error || 'Failed to load Redmine issue.');
        }
        setIsRedmineLoading(false);
      });
  }, [issueId]);

  var handleOpenDiff = function handleOpenDiff(path) {
    var baseSha = gitInfo.upstreamBranch ? gitInfo.upstreamBranch : 'HEAD';
    TabManager.openDiffTab(path, path.split('/').pop(), baseSha, 'WORKING', null);
  };

  var commits = gitInfo && gitInfo.branchCommits || [];
  var unpushed = gitInfo && gitInfo.unpushedFiles || [];

  return React.createElement(
    'div',
    { className: 'ide-code-review' },
    React.createElement(
      'div',
      { className: 'ide-code-review-header' },
      React.createElement(
        'div',
        { className: 'ide-code-review-title' },
        React.createElement('i', { className: 'fas fa-clipboard-check' }),
        ' Code Review: ',
        gitInfo ? gitInfo.branch : 'Unknown Branch'
      ),
      React.createElement(
        'button',
        { className: 'ide-icon-btn', onClick: onClose, title: 'Close Review' },
        React.createElement('i', { className: 'fas fa-times' })
      )
    ),
    React.createElement(
      'div',
      { className: 'ide-code-review-content' },

      // Redmine Issue Section
      issueId && React.createElement(
        'div',
        { className: 'review-section' },
        React.createElement(
          'h3',
          { className: 'review-section-title' },
          'Redmine Issue #',
          issueId
        ),
        isRedmineLoading ? React.createElement(
          'div',
          { className: 'ide-loading-state', 'aria-busy': 'true' },
          'Loading issue details…'
        ) : redmineError ? React.createElement(
          'div',
          { className: 'ide-error-state' },
          redmineError
        ) : redmineIssue ? React.createElement(
          'div',
          { className: 'redmine-card' },
          React.createElement(
            'div',
            { className: 'redmine-card-header' },
            React.createElement('strong', null, redmineIssue.title),
            React.createElement(
              'span',
              { className: 'redmine-badge' },
              redmineIssue.status
            )
          ),
          React.createElement(
            'div',
            { className: 'redmine-meta' },
            'Assigned to: ',
            redmineIssue.author
          ),
          React.createElement(
            'div',
            { className: 'redmine-desc' },
            redmineIssue.description
          )
        ) : null
      ),

      // Files to Review Section
      React.createElement(
        'div',
        { className: 'review-section' },
        React.createElement(
          'h3',
          { className: 'review-section-title' },
          'Files Altered in Branch (',
          unpushed.length,
          ')'
        ),
        unpushed.length === 0 ? React.createElement(
          'div',
          { className: 'ide-empty-state' },
          'No unpushed files to review.'
        ) : React.createElement(
          'div',
          { className: 'git-list' },
          unpushed.map(function (item) {
            return React.createElement(
              'div',
              { key: item.path, className: 'git-commit-item hoverable', onClick: function () {
                  return handleOpenDiff(item.path);
                } },
              React.createElement(
                'div',
                { className: 'git-commit-title' },
                item.path
              ),
              React.createElement(
                'div',
                { className: 'git-commit-meta' },
                'Status: ',
                item.status,
                ' \xB7 Click to view full diff against base branch'
              )
            );
          })
        )
      ),

      // Commits Section
      React.createElement(
        'div',
        { className: 'review-section' },
        React.createElement(
          'h3',
          { className: 'review-section-title' },
          'Branch Commits (',
          commits.length,
          ')'
        ),
        commits.length === 0 ? React.createElement(
          'div',
          { className: 'ide-empty-state' },
          'No local commits.'
        ) : React.createElement(
          'div',
          { className: 'git-list' },
          commits.map(function (commit) {
            return React.createElement(
              'div',
              { key: commit.hash, className: 'git-commit-item' },
              React.createElement(
                'div',
                { className: 'git-commit-title' },
                commit.title
              ),
              React.createElement(
                'div',
                { className: 'git-commit-meta' },
                commit.hash.slice(0, 7),
                ' \xB7 ',
                commit.author
              )
            );
          })
        )
      )
    )
  );
};

window.CodeReviewPanel = CodeReviewPanel;
