'use strict';

// MigrationsPanel — read-only list of db/migrate files with applied/pending
// status. Fetches on mount; there is deliberately no action that changes anything.
var MigrationsPanel = function MigrationsPanel(_ref) {
  var onOpenFile = _ref.onOpenFile;

  var _result = React.useState(null);
  var result = _result[0], setResult = _result[1];
  var _busy = React.useState(false);
  var busy = _busy[0], setBusy = _busy[1];
  var _error = React.useState(null);
  var error = _error[0], setError = _error[1];

  var load = function load() {
    setBusy(true);
    setError(null);
    axios.get(window.mbeditorBasePath() + '/migrations').then(function (res) {
      setResult(res.data);
    }).catch(function (err) {
      setError((err.response && err.response.data && err.response.data.error) || err.message);
    }).then(function () {
      setBusy(false);
    });
  };

  React.useEffect(function () { load(); }, []);

  var summary = null;
  if (result) {
    if (result.db !== 'ok') {
      summary = 'Database unavailable — showing files only';
    } else {
      var pending = result.migrations.filter(function (m) { return m.status === 'down'; }).length;
      summary = pending + ' pending';
    }
  }

  return React.createElement(
    'div',
    { className: 'rails-panel' },
    React.createElement(
      'div',
      { className: 'ide-problems-actions', style: { padding: '0 12px 8px' } },
      React.createElement('button', { type: 'button', className: 'ide-problems-btn', onClick: load, disabled: busy },
        busy ? 'Loading…' : 'Refresh')
    ),
    error && React.createElement('div', { className: 'rails-panel-empty' }, error),
    summary && React.createElement('div', { className: 'rails-panel-empty' }, summary),
    result && result.orphaned.length > 0 && React.createElement('div', { className: 'rails-panel-empty' },
      result.orphaned.length + ' applied version(s) with no file'),
    result && result.migrations.map(function (m) {
      return React.createElement(
        'button',
        {
          key: m.version,
          type: 'button',
          className: 'ide-problems-item',
          title: m.file,
          onClick: function () { onOpenFile(m.file); }
        },
        React.createElement('span', { className: 'ide-problems-msg' }, m.version + ' ' + m.name),
        m.tables.length > 0 && React.createElement('span', { className: 'ide-problems-source' }, m.tables.join(', ')),
        m.status === 'down' && React.createElement('span', { className: 'ide-problems-file-count' }, 'pending')
      );
    })
  );
};
