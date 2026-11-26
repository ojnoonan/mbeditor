'use strict';

// RoutesPanel — sidebar list of the host app's routes. Fetches when mounted
// (the sidebar mounts it only while its tab is open) and on refresh.
function RoutesPanel(props) {
  var _routes = React.useState(null);
  var routes = _routes[0], setRoutes = _routes[1];
  var _filter = React.useState('');
  var filter = _filter[0], setFilter = _filter[1];
  var _error = React.useState(null);
  var error = _error[0], setError = _error[1];

  var load = function load() {
    setError(null);
    FileService.getAllRoutes()
      .then(function (data) { setRoutes(data.routes || []); })
      .catch(function () { setError('Could not load routes.'); });
  };
  React.useEffect(load, []);

  var q = filter.trim().toLowerCase();
  var shown = (routes || []).filter(function (r) {
    return !q || [r.verb, r.path, r.name, r.controller + '#' + r.action].some(function (s) {
      return s && s.toLowerCase().indexOf(q) !== -1;
    });
  });

  var _col = VirtualRows.useCollapsed();
  var collapsed = _col[0], toggle = _col[1];

  // Header row per controller, its routes under it; every row is one 22px line.
  var byController = {};
  var groups = [];
  shown.forEach(function (r, i) {
    var ctrl = r.controller || '(none)';
    if (!byController[ctrl]) {
      byController[ctrl] = { type: 'group', key: 'g:' + ctrl, controller: ctrl, items: [] };
      groups.push(byController[ctrl]);
    }
    byController[ctrl].items.push({ type: 'route', key: 'r:' + i, route: r });
  });
  var rows = [];
  groups.forEach(function (g) {
    rows.push(g);
    if (!collapsed[g.controller]) g.items.forEach(function (item) { rows.push(item); });
  });

  var renderRow = function renderRow(row, style) {
    if (row.type === 'group') {
      return VirtualRows.groupHeader({
        label: row.controller,
        count: row.items.length,
        collapsed: !!collapsed[row.controller],
        onToggle: function () { toggle(row.controller); }
      }, style);
    }
    var r = row.route;
    return React.createElement('div', {
      className: 'search-result-item',
      style: style,
      title: r.verb + ' ' + r.path + '  ' + r.controller + '#' + r.action,
      onClick: r.file ? function () { props.onOpenFile(r.file, r.line); } : undefined
    },
      React.createElement('span', { className: 'search-result-line-num' }, r.verb),
      React.createElement('span', { className: 'search-result-text' }, r.path)
    );
  };

  var body;
  if (error) body = React.createElement('div', { className: 'rails-panel-empty' }, error);
  else if (!routes) body = React.createElement('div', { className: 'rails-panel-loading' }, 'Loading…');
  else if (shown.length === 0) body = React.createElement('div', { className: 'rails-panel-empty' }, 'No routes.');
  else body = React.createElement(VirtualRows, { rows: rows, renderRow: renderRow });

  return React.createElement('div', { className: 'rails-panel' },
    React.createElement('div', { className: 'search-input-shell' },
      React.createElement('input', {
        className: 'search-input',
        placeholder: 'Filter routes…',
        value: filter,
        onChange: function (e) { setFilter(e.target.value); }
      }),
      React.createElement('div', { className: 'search-input-adornments' },
        React.createElement('button', {
          type: 'button', className: 'search-adornment-btn', title: 'Refresh', onClick: load
        }, React.createElement('i', { className: 'fas fa-sync-alt' }))
      )
    ),
    body
  );
}

window.RoutesPanel = RoutesPanel;
