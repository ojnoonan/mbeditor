'use strict';

// VirtualRows — windowed list of fixed-height rows, the technique the search
// results use (see SEARCH_ROW_HEIGHT in MbeditorApp.js). Only the rows on
// screen plus a buffer are built; a spacer of rows.length * rowHeight keeps
// the scrollbar honest. Every row must be exactly rowHeight tall, which is why
// the row classes pin their height and clip to one line.
//
// props: rows, rowHeight (22), renderRow(row, style) -> element, className.
// A row may carry `key`; otherwise its index is used.
var VIRTUAL_ROW_BUFFER = 5;

function VirtualRows(props) {
  var rowHeight = props.rowHeight || 22;
  var rows = props.rows;
  var _vp = React.useState({ scrollTop: 0, height: 0 });
  var viewport = _vp[0], setViewport = _vp[1];
  var observerRef = React.useRef(null);

  // Same-value updates return prev, so an idle ResizeObserver or a scroll that
  // moved nothing never re-renders.
  var measure = function measure(el) {
    setViewport(function (prev) {
      if (prev.height === el.clientHeight && prev.scrollTop === el.scrollTop) return prev;
      return { scrollTop: el.scrollTop, height: el.clientHeight };
    });
  };

  // Callback ref, not an effect: the element mounts and unmounts with the panel
  // state (loading -> results), which an effect's dependency list never sees.
  var attach = React.useRef(function (el) {
    if (observerRef.current) { observerRef.current.disconnect(); observerRef.current = null; }
    if (!el) return;
    measure(el);
    if (typeof ResizeObserver === 'undefined') return;
    observerRef.current = new ResizeObserver(function () { measure(el); });
    observerRef.current.observe(el);
  }).current;

  var start = Math.max(0, Math.floor(viewport.scrollTop / rowHeight) - VIRTUAL_ROW_BUFFER);
  var end = Math.min(rows.length, Math.ceil((viewport.scrollTop + (viewport.height || 600)) / rowHeight) + VIRTUAL_ROW_BUFFER);

  return React.createElement('div', {
    className: 'virtual-rows' + (props.className ? ' ' + props.className : ''),
    ref: attach,
    onScroll: function (e) { measure(e.currentTarget); }
  },
    React.createElement('div', { style: { height: rows.length * rowHeight, position: 'relative' } },
      rows.slice(start, end).map(function (row, vi) {
        var i = start + vi;
        var style = { position: 'absolute', top: i * rowHeight, left: 0, right: 0 };
        return React.createElement(React.Fragment, { key: row.key != null ? row.key : i }, props.renderRow(row, style));
      })
    )
  );
}

// Collapsed-group state, keyed by group name so it survives scrolling out of
// the window. Returns [collapsedMap, toggle].
VirtualRows.useCollapsed = function useCollapsed() {
  var _c = React.useState({});
  var toggle = React.useRef(function (key) {
    _c[1](function (prev) {
      var next = Object.assign({}, prev);
      if (next[key]) delete next[key]; else next[key] = true;
      return next;
    });
  }).current;
  return [_c[0], toggle];
};

// A search-style group header: chevron, name, muted sub text, count pill.
VirtualRows.groupHeader = function groupHeader(opts, style) {
  return React.createElement('div', {
    className: 'search-result-file-row',
    style: style,
    title: opts.title || opts.label,
    onClick: opts.onToggle
  },
    React.createElement('i', { className: 'fas fa-chevron-' + (opts.collapsed ? 'right' : 'down') + ' search-result-chevron' }),
    React.createElement('span', { className: 'search-result-file-name' }, opts.label),
    opts.sub && React.createElement('span', { className: 'search-result-file-dir' }, opts.sub),
    React.createElement('span', { className: 'search-result-count' }, opts.count)
  );
};

window.VirtualRows = VirtualRows;
