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

  var MIN_HEIGHT = 120;
  var _height = React.useState(function () {
    var saved = parseInt(window.localStorage.getItem('mbeditorLogHeight'), 10);
    return (saved && saved >= MIN_HEIGHT) ? saved : 240;
  });
  var height = _height[0], setHeight = _height[1];

  var bodyRef = React.useRef(null);
  // Mirror height into a ref so the drag end-handler can persist the final value
  // (setHeight is async, so reading state in onMouseUp would be stale).
  var heightRef = React.useRef(height);
  heightRef.current = height;

  // Drag the top edge to resize the drawer. Delta-based: track how far the
  // pointer has moved from where the drag started and add that to the starting
  // height. Dragging up grows the drawer. This is independent of where the
  // drawer is anchored and survives a zero/unknown viewport height.
  var onResizeMouseDown = function (e) {
    e.preventDefault();
    var startY = e.clientY;
    var startHeight = heightRef.current;
    var onMove = function (ev) {
      var vh = window.innerHeight || document.documentElement.clientHeight || 0;
      var maxH = vh > 0 ? Math.round(vh * 0.85) : Infinity;
      var next = Math.min(maxH, Math.max(MIN_HEIGHT, startHeight + (startY - ev.clientY)));
      heightRef.current = next;
      setHeight(next);
    };
    var onUp = function () {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      window.localStorage.setItem('mbeditorLogHeight', String(heightRef.current));
    };
    document.body.style.cursor = 'ns-resize';
    document.body.style.userSelect = 'none';
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  };

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
    { className: 'ide-log-drawer', style: { height: height + 'px' } },
    React.createElement('div', {
      className: 'ide-log-resize',
      title: 'Drag to resize',
      onMouseDown: onResizeMouseDown
    }),
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
