'use strict';

// LogPanel — bottom drawer that renders the live Rails log. Auto-scrolls to the
// tail, pauses auto-scroll when the user scrolls up, and supports a substring
// filter and clear. Driven entirely by LogService.
var LogPanel = function LogPanel(_ref) {
  var onClose = _ref.onClose;

  var _lines = React.useState([]);
  var lines = _lines[0], setLines = _lines[1];
  var _filter = React.useState('');
  var filter = _filter[0], setFilter = _filter[1];
  var _autoScroll = React.useState(true);
  var autoScroll = _autoScroll[0], setAutoScroll = _autoScroll[1];

  var bodyRef = React.useRef(null);

  React.useEffect(function () {
    LogService.start();
    var unsub = LogService.subscribe(function (next) {
      // copy so React sees a new array reference
      setLines(next.slice());
    });
    setLines(LogService.getLines().slice());
    return function () {
      unsub();
      LogService.stop();
    };
  }, []);

  React.useEffect(function () {
    if (autoScroll && bodyRef.current) {
      bodyRef.current.scrollTop = bodyRef.current.scrollHeight;
    }
  }, [lines, autoScroll]);

  var onScroll = function onScroll() {
    var el = bodyRef.current;
    if (!el) return;
    var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
    setAutoScroll(atBottom);
  };

  var shown = filter
    ? lines.filter(function (l) { return l.toLowerCase().indexOf(filter.toLowerCase()) !== -1; })
    : lines;

  return React.createElement(
    'div',
    { className: 'ide-log-drawer' },
    React.createElement(
      'div',
      { className: 'ide-log-header' },
      React.createElement('i', { className: 'fas fa-stream' }),
      React.createElement('span', { className: 'ide-log-title' }, 'Rails log'),
      React.createElement('input', {
        className: 'ide-log-filter',
        type: 'text',
        placeholder: 'Filter…',
        value: filter,
        onChange: function (e) { setFilter(e.target.value); }
      }),
      !autoScroll && React.createElement('span', { className: 'ide-log-paused' }, 'paused'),
      React.createElement('button', {
        type: 'button', className: 'ide-log-btn',
        title: 'Clear', onClick: function () { LogService.clear(); }
      }, React.createElement('i', { className: 'fas fa-ban' })),
      React.createElement('button', {
        type: 'button', className: 'ide-log-btn',
        title: 'Close', onClick: onClose
      }, React.createElement('i', { className: 'fas fa-times' }))
    ),
    React.createElement(
      'div',
      { className: 'ide-log-body', ref: bodyRef, onScroll: onScroll },
      shown.map(function (line, i) {
        return React.createElement('div', { className: 'ide-log-line', key: i }, line);
      })
    )
  );
};

window.LogPanel = LogPanel;
