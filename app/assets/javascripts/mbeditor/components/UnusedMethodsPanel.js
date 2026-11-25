'use strict';

// UnusedMethodsPanel — sidebar panel for the Unused methods scan. The scan walks
// the whole workspace, so it runs only when Scan is clicked, never on mount.
var UnusedMethodsPanel = function UnusedMethodsPanel(_ref) {
  var onOpenFile = _ref.onOpenFile;

  var _result = React.useState(null);
  var result = _result[0], setResult = _result[1];
  var _busy = React.useState(false);
  var busy = _busy[0], setBusy = _busy[1];
  var _error = React.useState(null);
  var error = _error[0], setError = _error[1];

  var scan = function scan() {
    setBusy(true);
    setError(null);
    axios.get(window.mbeditorBasePath() + '/unused_methods').then(function (res) {
      setResult(res.data);
    }).catch(function (err) {
      setError((err.response && err.response.data && err.response.data.error) || err.message);
    }).then(function () {
      setBusy(false);
    });
  };

  var allUnused = {};
  if (result) result.files.forEach(function (path) { allUnused[path] = true; });

  var groups = [];
  if (result) {
    var byFile = {};
    result.methods.forEach(function (m) {
      if (!byFile[m.file]) {
        byFile[m.file] = [];
        groups.push({ file: m.file, items: byFile[m.file] });
      }
      byFile[m.file].push(m);
    });
  }

  return React.createElement(
    'div',
    { className: 'rails-panel' },
    React.createElement(
      'div',
      { className: 'rails-panel-empty' },
      'Text heuristic: dynamic dispatch can hide uses, so check before deleting.'
    ),
    React.createElement(
      'div',
      { className: 'ide-problems-actions', style: { padding: '0 12px 8px' } },
      React.createElement('button', { type: 'button', className: 'ide-problems-btn', onClick: scan, disabled: busy },
        busy ? 'Scanning…' : 'Scan')
    ),
    error && React.createElement('div', { className: 'rails-panel-empty' }, error),
    result && React.createElement('div', { className: 'ide-problems-file-name' }, React.createElement('span', null, 'Unused views'),
      React.createElement('span', { className: 'ide-problems-file-count' }, result.views.length)),
    result && result.views.length === 0 && React.createElement('div', { className: 'rails-panel-empty' }, 'No unused views found.'),
    result && result.views.map(function (path) {
      return React.createElement('button', {
        key: path,
        type: 'button',
        className: 'ide-problems-item',
        onClick: function () { onOpenFile(path); }
      }, React.createElement('span', { className: 'ide-problems-msg' }, path.replace(/^app\/views\//, '')));
    }),
    result && React.createElement('div', { className: 'ide-problems-file-name' }, React.createElement('span', null, 'Unused methods')),
    result && groups.length === 0 && React.createElement('div', { className: 'rails-panel-empty' },
      'No unused methods found in ' + result.scanned + ' files.'),
    result && result.truncated && React.createElement('div', { className: 'rails-panel-empty' },
      'Showing the first ' + result.methods.length + ' results.'),
    groups.map(function (group) {
      var slash = group.file.lastIndexOf('/');
      var base = slash === -1 ? group.file : group.file.slice(slash + 1);
      return React.createElement(
        'div',
        { key: group.file },
        React.createElement(
          'div',
          { className: 'ide-problems-file-name' },
          React.createElement('span', null, base),
          slash !== -1 && React.createElement('span', { className: 'ide-problems-dir' }, group.file.slice(0, slash)),
          allUnused[group.file] && React.createElement('span', { className: 'ide-problems-file-count' }, 'all unused')
        ),
        group.items.map(function (m) {
          return React.createElement(
            'button',
            {
              key: m.line + ':' + m.name,
              type: 'button',
              className: 'ide-problems-item',
              onClick: function () { onOpenFile(m.file, m.line); }
            },
            React.createElement('span', { className: 'ide-problems-msg' }, m.name),
            React.createElement('span', { className: 'ide-problems-source' }, 'line ' + m.line)
          );
        })
      );
    })
  );
};
