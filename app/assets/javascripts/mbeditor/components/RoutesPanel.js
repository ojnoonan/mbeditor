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

  var rows;
  if (error) rows = React.createElement('div', { className: 'rails-panel-empty' }, error);
  else if (!routes) rows = React.createElement('div', { className: 'rails-panel-loading' }, 'Loading…');
  else if (shown.length === 0) rows = React.createElement('div', { className: 'rails-panel-empty' }, 'No routes.');
  else rows = shown.map(function (r, i) {
    var target = r.controller + '#' + r.action;
    return React.createElement('div', {
      key: i,
      className: 'rails-group-item',
      title: r.verb + ' ' + r.path + '  ' + target,
      onClick: r.file ? function () { props.onOpenFile(r.file, r.line); } : undefined
    },
      React.createElement('span', { className: 'rails-group-item-kind' }, r.verb),
      React.createElement('span', { className: 'rails-group-item-name' }, r.path + '  ' + target)
    );
  });

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
    rows
  );
}

window.RoutesPanel = RoutesPanel;
