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

  var _col = VirtualRows.useCollapsed();
  var collapsed = _col[0], toggle = _col[1];

  // Grouped by model first, then views before methods inside each group: the
  // model is what you decide on ("is User cleanup worth it"), the kind is detail.
  var allUnused = {};
  var rows = [];
  if (result) {
    result.files.forEach(function (f) { allUnused[f.path] = true; });
    var byGroup = {};
    var bucket = function (name) { return (byGroup[name] = byGroup[name] || []); };
    result.views.forEach(function (v) { bucket(v.group).push({ type: 'view', key: 'v:' + v.path, v: v }); });
    result.methods.forEach(function (m) { bucket(m.group).push({ type: 'method', key: 'm:' + m.file + ':' + m.line + ':' + m.name, m: m }); });
    Object.keys(byGroup).sort().forEach(function (g) {
      rows.push({ type: 'group', key: 'g:' + g, group: g, count: byGroup[g].length });
      if (!collapsed[g]) byGroup[g].forEach(function (item) { rows.push(item); });
    });
  }

  var renderRow = function renderRow(row, style) {
    if (row.type === 'group') {
      return VirtualRows.groupHeader({
        label: row.group, count: row.count, collapsed: !!collapsed[row.group],
        onToggle: function () { toggle(row.group); }
      }, style);
    }
    if (row.type === 'view') {
      return React.createElement('div', {
        className: 'search-result-item', style: style, title: row.v.path,
        onClick: function () { onOpenFile(row.v.path); }
      },
        React.createElement('span', { className: 'search-result-line-num' }, 'view'),
        React.createElement('span', { className: 'search-result-text' }, row.v.path.replace(/^app\/views\//, ''))
      );
    }
    var m = row.m;
    var base = m.file.slice(m.file.lastIndexOf('/') + 1);
    return React.createElement('div', {
      className: 'search-result-item', style: style,
      title: m.file + ':' + m.line + (allUnused[m.file] ? ' (every method in this file is unused)' : ''),
      onClick: function () { onOpenFile(m.file, m.line); }
    },
      React.createElement('span', { className: 'search-result-line-num' }, m.line),
      React.createElement('span', { className: 'search-result-text' }, m.name + '  ' + base + (allUnused[m.file] ? '  (all unused)' : ''))
    );
  };

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
    result && rows.length === 0 && React.createElement('div', { className: 'rails-panel-empty' },
      'No unused views or methods found in ' + result.scanned + ' files.'),
    result && result.truncated && React.createElement('div', { className: 'rails-panel-empty' },
      'Showing the first ' + result.methods.length + ' results.'),
    result && rows.length > 0 && React.createElement(VirtualRows, { rows: rows, renderRow: renderRow })
  );
};
