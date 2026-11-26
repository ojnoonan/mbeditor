'use strict';

// MigrationsPanel — read-only list of db/migrate files with applied/pending
// status. Fetches on mount; there is deliberately no action that changes anything.
var ORPHAN_HELP = 'This version is recorded in schema_migrations but no db/migrate file has it — usually a migration from another branch or a deleted file.';

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

  var _col = VirtualRows.useCollapsed();
  var collapsed = _col[0], toggle = _col[1];

  // One group per model, a multi-table migration listed under each of its
  // models. The service already sorts newest first, so groups keep that order.
  var rows = [];
  if (result) {
    var byModel = {};
    result.migrations.forEach(function (m) {
      m.models.forEach(function (model) { (byModel[model] = byModel[model] || []).push(m); });
    });
    Object.keys(byModel).sort(function (a, b) {
      return (a === 'Other') - (b === 'Other') || (a < b ? -1 : a > b ? 1 : 0);
    }).forEach(function (model) {
      var items = byModel[model];
      var pending = items.filter(function (m) { return m.status === 'down'; }).length;
      rows.push({ type: 'group', key: 'g:' + model, group: model, label: model, count: items.length,
                  sub: pending ? pending + ' pending' : '' });
      if (!collapsed[model]) items.forEach(function (m) { rows.push({ type: 'migration', key: 'm:' + model + ':' + m.version, m: m }); });
    });
    if (result.orphaned.length > 0) {
      rows.push({ type: 'group', key: 'g:!orphans', group: '!orphans', label: 'Applied, file missing',
                  count: result.orphaned.length, title: ORPHAN_HELP });
      if (!collapsed['!orphans']) result.orphaned.forEach(function (v) { rows.push({ type: 'orphan', key: 'o:' + v, version: v }); });
    }
  }

  var renderRow = function renderRow(row, style) {
    if (row.type === 'group') {
      return VirtualRows.groupHeader({
        label: row.label, sub: row.sub, count: row.count, title: row.title,
        collapsed: !!collapsed[row.group],
        onToggle: function () { toggle(row.group); }
      }, style);
    }
    if (row.type === 'orphan') {
      return React.createElement('div', { className: 'search-result-item', style: style, title: ORPHAN_HELP },
        React.createElement('span', { className: 'search-result-text' }, row.version));
    }
    var m = row.m;
    return React.createElement('div', {
      className: 'search-result-item',
      style: style,
      title: m.version + '  ' + m.file + (m.tables.length ? '  (' + m.tables.join(', ') + ')' : ''),
      onClick: function () { onOpenFile(m.file); }
    },
      React.createElement('span', { className: 'search-result-text' }, m.name),
      m.status === 'down' && React.createElement('span', { className: 'search-result-count' }, 'pending')
    );
  };

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
    result && React.createElement(VirtualRows, { rows: rows, renderRow: renderRow })
  );
};
