'use strict';

// ModelGraph — an SVG entity diagram of the host app's ActiveRecord models.
//
// Laid out radially rather than left-to-right: the model with the most
// associations sits at the centre and everything else fans out in rings by how
// many hops away it is. A Rails schema is usually a hub with satellites, and a
// column layout turns that into one very wide, very short strip.
var ModelGraph = (function () {
  var NODE_W = 188;
  var HEADER_H = 34;      // model name + table name
  var FIELD_H = 15;
  var MAX_FIELDS = 8;     // the rest are one click away in the schema modal
  var RING_GAP = 150;
  var MIN_RADIUS = 210;
  var NODE_GAP = 56;      // clear space between neighbours on the same ring
  var BARYCENTRE_PASSES = 4;

  function nodeHeight(model) {
    var shown = Math.min((model.columns || []).length, MAX_FIELDS);
    var more = (model.columnCount || 0) > shown ? FIELD_H : 0;
    return HEADER_H + shown * FIELD_H + more + 8;
  }

  // Undirected adjacency: for placement, "A belongs_to B" and "B has_many A"
  // are the same tie and should pull the two together once.
  function adjacency(models, edges) {
    var adj = {};
    models.forEach(function (m) { adj[m.name] = {}; });
    edges.forEach(function (e) {
      if (!adj[e.from] || !adj[e.to] || e.from === e.to) return;
      adj[e.from][e.to] = true;
      adj[e.to][e.from] = true;
    });
    return adj;
  }

  function degreeOf(adj, name) { return Object.keys(adj[name] || {}).length; }

  // Rings by hop count from the busiest model. Disconnected islands are picked
  // up afterwards by their own local hub, so nothing is silently dropped.
  function assignRings(models, adj) {
    var remaining = {};
    models.forEach(function (m) { remaining[m.name] = true; });

    var ring = {};
    var order = [];

    while (Object.keys(remaining).length > 0) {
      var hub = Object.keys(remaining).sort(function (a, b) {
        var d = degreeOf(adj, b) - degreeOf(adj, a);
        return d !== 0 ? d : (a < b ? -1 : 1);
      })[0];

      var queue = [hub];
      ring[hub] = order.length === 0 ? 0 : 1;
      delete remaining[hub];
      order.push(hub);

      while (queue.length) {
        var current = queue.shift();
        Object.keys(adj[current] || {}).sort().forEach(function (next) {
          if (!remaining[next]) return;
          delete remaining[next];
          ring[next] = ring[current] + 1;
          order.push(next);
          queue.push(next);
        });
      }
    }
    return ring;
  }

  // Ordering within a ring is what decides how many lines cross. Repeatedly
  // move each node to the average angle of its already-placed neighbours
  // (a barycentre sweep) — cheap, and it untangles most of the crossings a
  // naive alphabetical ring would create.
  function orderRing(names, angleOf, adj, ringOf, thisRing) {
    var ordered = names.slice();
    for (var pass = 0; pass < BARYCENTRE_PASSES; pass++) {
      var target = {};
      ordered.forEach(function (name) {
        var xs = 0, ys = 0, n = 0;
        Object.keys(adj[name] || {}).forEach(function (nb) {
          // Only anchor to neighbours already pinned by an inner ring;
          // same-ring ties would just chase each other.
          if (ringOf[nb] >= thisRing) return;
          var a = angleOf[nb];
          if (a === undefined) return;
          xs += Math.cos(a); ys += Math.sin(a); n++;
        });
        target[name] = n === 0 ? null : Math.atan2(ys, xs);
      });

      var anchored = ordered.filter(function (n) { return target[n] !== null; });
      var floating = ordered.filter(function (n) { return target[n] === null; });
      anchored.sort(function (a, b) { return target[a] - target[b]; });
      ordered = anchored.concat(floating);
    }
    return ordered;
  }

  function layout(models, edges) {
    var byName = {};
    models.forEach(function (m) { byName[m.name] = m; });

    var adj = adjacency(models, edges);
    var ringOf = assignRings(models, adj);

    var rings = [];
    models.forEach(function (m) {
      var r = ringOf[m.name] || 0;
      (rings[r] = rings[r] || []).push(m.name);
    });

    var positions = {};
    var angleOf = {};
    var maxExtent = 0;
    // Radius and half-footprint of the ring inside this one, so each ring is
    // pushed clear of it. Without this an inner ring with many nodes gets a
    // large circumference-derived radius and the next ring lands inside it.
    var prevRadius = 0;
    var prevHalf = 0;

    rings.forEach(function (names, ringIndex) {
      if (!names) return;

      if (ringIndex === 0) {
        names.forEach(function (name) {
          positions[name] = { x: 0, y: 0, model: byName[name] };
          angleOf[name] = 0;
          prevHalf = Math.max(prevHalf, Math.max(NODE_W, nodeHeight(byName[name])) / 2);
        });
        return;
      }

      var ordered = orderRing(names, angleOf, adj, ringOf, ringIndex);

      // Boxes vary in height with their field count, so each one claims arc
      // proportional to its own footprint. Spacing them evenly by count is what
      // makes a tall box collide with its neighbours.
      var extents = ordered.map(function (name) {
        return Math.max(NODE_W, nodeHeight(byName[name])) + NODE_GAP;
      });
      var totalExtent = extents.reduce(function (a, b) { return a + b; }, 0);
      var thisHalf = Math.max.apply(null, extents) / 2;
      var radius = Math.max(
        MIN_RADIUS,
        totalExtent / (2 * Math.PI),           // wide enough that neighbours clear
        prevRadius + prevHalf + thisHalf + 40  // and outside the ring within
      );
      prevRadius = radius;
      prevHalf = thisHalf;

      var cumulative = 0;
      ordered.forEach(function (name, i) {
        var angle = (2 * Math.PI * (cumulative + extents[i] / 2)) / totalExtent - Math.PI / 2;
        cumulative += extents[i];
        angleOf[name] = angle;
        var h = nodeHeight(byName[name]);
        positions[name] = {
          x: Math.cos(angle) * radius - NODE_W / 2,
          y: Math.sin(angle) * radius - h / 2,
          model: byName[name]
        };
        maxExtent = Math.max(maxExtent, radius + NODE_W, radius + h);
      });
    });

    // Shift everything positive and size the canvas to what was actually drawn.
    var pad = 60;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    Object.keys(positions).forEach(function (name) {
      var p = positions[name];
      var h = nodeHeight(p.model);
      minX = Math.min(minX, p.x); minY = Math.min(minY, p.y);
      maxX = Math.max(maxX, p.x + NODE_W); maxY = Math.max(maxY, p.y + h);
    });
    if (!isFinite(minX)) { minX = 0; minY = 0; maxX = NODE_W; maxY = HEADER_H; }

    Object.keys(positions).forEach(function (name) {
      positions[name].x += pad - minX;
      positions[name].y += pad - minY;
    });

    return {
      positions: positions,
      width: (maxX - minX) + pad * 2,
      height: (maxY - minY) + pad * 2
    };
  }

  // Anchor on whichever side of each box faces the other, so lines leave and
  // arrive at the near edge instead of cutting through their own node.
  function anchors(a, b) {
    var ah = nodeHeight(a.model), bh = nodeHeight(b.model);
    var acx = a.x + NODE_W / 2, acy = a.y + ah / 2;
    var bcx = b.x + NODE_W / 2, bcy = b.y + bh / 2;
    var horizontal = Math.abs(bcx - acx) > Math.abs(bcy - acy);

    if (horizontal) {
      return bcx > acx
        ? { x1: a.x + NODE_W, y1: acy, x2: b.x, y2: bcy, h: true }
        : { x1: a.x, y1: acy, x2: b.x + NODE_W, y2: bcy, h: true };
    }
    return bcy > acy
      ? { x1: acx, y1: a.y + ah, x2: bcx, y2: b.y, h: false }
      : { x1: acx, y1: a.y, x2: bcx, y2: b.y + bh, h: false };
  }

  function edgePath(a, b) {
    var p = anchors(a, b);
    var dx = Math.abs(p.x2 - p.x1), dy = Math.abs(p.y2 - p.y1);
    if (p.h) {
      var cx = Math.max(40, dx / 2);
      return 'M' + p.x1 + ',' + p.y1 +
        ' C' + (p.x1 + (p.x2 > p.x1 ? cx : -cx)) + ',' + p.y1 +
        ' ' + (p.x2 + (p.x2 > p.x1 ? -cx : cx)) + ',' + p.y2 +
        ' ' + p.x2 + ',' + p.y2;
    }
    var cy = Math.max(40, dy / 2);
    return 'M' + p.x1 + ',' + p.y1 +
      ' C' + p.x1 + ',' + (p.y1 + (p.y2 > p.y1 ? cy : -cy)) +
      ' ' + p.x2 + ',' + (p.y2 + (p.y2 > p.y1 ? -cy : cy)) +
      ' ' + p.x2 + ',' + p.y2;
  }

  var MACRO_CLASS = {
    belongs_to: 'mg-edge-belongs',
    has_one: 'mg-edge-has-one',
    has_many: 'mg-edge-has-many',
    has_and_belongs_to_many: 'mg-edge-habtm'
  };

  var MIN_ZOOM = 0.2;
  var MAX_ZOOM = 2.5;

  return function ModelGraphComponent(_ref) {
    var graph = _ref.graph;
    var onOpenModel = _ref.onOpenModel;
    var onRefresh = _ref.onRefresh;
    var loading = _ref.loading;

    var _view = React.useState({ k: 1, x: 0, y: 0 });
    var view = _view[0], setView = _view[1];
    var dragRef = React.useRef(null);
    var svgRef = React.useRef(null);

    // Laid out before the early returns so the fit effect below can see it.
    var placed = (graph && graph.ok && (graph.models || []).length)
      ? layout(graph.models, graph.edges || [])
      : null;

    // Frame the whole graph on load. Without this the view starts at the
    // top-left of a canvas much larger than the pane and the diagram looks
    // empty until you go looking for it.
    var fitToPane = React.useCallback(function () {
      var el = svgRef.current;
      if (!el || !placed) return;
      var rect = el.getBoundingClientRect();
      if (!rect.width || !rect.height) return;

      var k = Math.min(1, Math.min(rect.width / placed.width, rect.height / placed.height));
      setView({
        k: k,
        x: (rect.width - placed.width * k) / 2,
        y: (rect.height - placed.height * k) / 2
      });
    }, [placed && placed.width, placed && placed.height]);

    React.useEffect(function () { fitToPane(); }, [fitToPane]);

    // Same mounting problem as the wheel listener: the fit effect can run
    // before the SVG exists and not again afterwards. Kept current so the
    // callback ref can fit as soon as the element is really there.
    var fitRef = React.useRef(fitToPane);
    fitRef.current = fitToPane;

    // A callback ref rather than useRef + useEffect. The SVG mounts on a
    // render where `graph` has not changed — loading flips false separately
    // from the data arriving — so an effect keyed on the data never re-runs
    // once the element finally exists, and the listener is never attached.
    // A callback ref fires exactly when the node appears.
    //
    // The listener is manual and non-passive: React's onWheel is passive, so
    // preventDefault is ignored there and the editor scrolls instead of the
    // diagram zooming.
    var wheelCleanup = React.useRef(null);
    var attachSvg = React.useCallback(function (el) {
      if (wheelCleanup.current) { wheelCleanup.current(); wheelCleanup.current = null; }
      svgRef.current = el;
      if (!el) return;

      var onWheel = function (e) {
        e.preventDefault();
        var rect = el.getBoundingClientRect();
        var px = e.clientX - rect.left;
        var py = e.clientY - rect.top;
        setView(function (v) {
          var k = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, v.k * (e.deltaY < 0 ? 1.12 : 1 / 1.12)));
          // Keep the point under the cursor pinned while scaling.
          return { k: k, x: px - (px - v.x) * (k / v.k), y: py - (py - v.y) * (k / v.k) };
        });
      };
      el.addEventListener('wheel', onWheel, { passive: false });
      wheelCleanup.current = function () { el.removeEventListener('wheel', onWheel); };

      // After layout, so the pane has a measurable size to fit into.
      window.requestAnimationFrame(function () { fitRef.current(); });
    }, []);

    if (loading) {
      return React.createElement('div', { className: 'ide-model-graph-empty' }, 'Building the model graph…');
    }
    if (!graph) {
      return React.createElement('div', { className: 'ide-model-graph-empty' }, 'Loading…');
    }
    if (!graph.ok) {
      return React.createElement(
        'div',
        { className: 'ide-model-graph-empty' },
        React.createElement('div', null, graph.error || 'No model graph available.'),
        React.createElement('button', {
          type: 'button', className: 'ide-model-graph-btn', onClick: onRefresh
        }, 'Try again')
      );
    }

    var models = graph.models || [];
    var edges = graph.edges || [];
    if (models.length === 0 || !placed) {
      return React.createElement('div', { className: 'ide-model-graph-empty' }, 'No ActiveRecord models found.');
    }

    var onMouseDown = function (e) {
      if (e.button !== 0) return;
      dragRef.current = { sx: e.clientX, sy: e.clientY, ox: view.x, oy: view.y, moved: false };
    };
    var onMouseMove = function (e) {
      var d = dragRef.current;
      if (!d) return;
      var dx = e.clientX - d.sx, dy = e.clientY - d.sy;
      if (Math.abs(dx) > 3 || Math.abs(dy) > 3) d.moved = true;
      setView(function (v) { return { k: v.k, x: d.ox + dx, y: d.oy + dy }; });
    };
    var endDrag = function () { dragRef.current = null; };

    return React.createElement(
      'div',
      { className: 'ide-model-graph' },
      React.createElement(
        'div',
        { className: 'ide-model-graph-toolbar' },
        React.createElement('span', null, models.length + ' models, ' + edges.length + ' associations'),
        graph.truncated && React.createElement('span', { className: 'ide-model-graph-warn' }, ' (truncated)'),
        React.createElement('span', { className: 'ide-model-graph-hint' }, 'drag to pan · scroll to zoom · click a model for its schema'),
        React.createElement('button', {
          type: 'button', className: 'ide-model-graph-btn', title: 'Fit the whole graph',
          onClick: fitToPane
        }, React.createElement('i', { className: 'fas fa-compress-arrows-alt' })),
        React.createElement('button', {
          type: 'button', className: 'ide-model-graph-btn',
          title: 'Rebuild from the current code', onClick: onRefresh
        }, React.createElement('i', { className: 'fas fa-sync' }))
      ),
      React.createElement(
        'svg',
        {
          ref: attachSvg,
          className: 'ide-model-graph-svg' + (dragRef.current ? ' mg-dragging' : ''),
          onMouseDown: onMouseDown,
          onMouseMove: onMouseMove,
          onMouseUp: endDrag,
          onMouseLeave: endDrag
        },
        React.createElement(
          'defs',
          null,
          React.createElement(
            'marker',
            {
              id: 'mg-arrow', viewBox: '0 0 10 10', refX: '9', refY: '5',
              markerWidth: '5', markerHeight: '5', orient: 'auto-start-reverse'
            },
            React.createElement('path', { d: 'M 0 0 L 10 5 L 0 10 z', className: 'mg-arrow-head' })
          )
        ),
        React.createElement(
          'g',
          { transform: 'translate(' + view.x + ',' + view.y + ') scale(' + view.k + ')' },
          edges.map(function (e, i) {
            var a = placed.positions[e.from];
            var b = placed.positions[e.to];
            if (!a || !b || e.from === e.to) return null;
            return React.createElement(
              'path',
              {
                key: 'e' + i,
                d: edgePath(a, b),
                className: 'mg-edge ' + (MACRO_CLASS[e.macro] || ''),
                markerEnd: 'url(#mg-arrow)'
              },
              React.createElement('title', null,
                e.from + '.' + e.name + ' — ' + e.macro + (e.through ? ' through ' + e.through : ''))
            );
          }),
          models.map(function (m) {
            var pos = placed.positions[m.name];
            if (!pos) return null;
            var fields = (m.columns || []).slice(0, MAX_FIELDS);
            var hidden = (m.columnCount || 0) - fields.length;
            var h = nodeHeight(m);
            return React.createElement(
              'g',
              {
                key: m.name,
                className: 'mg-node',
                transform: 'translate(' + pos.x + ',' + pos.y + ')',
                onClick: function () {
                  // A drag that ends over a box must not also open it.
                  if (dragRef.current && dragRef.current.moved) return;
                  if (onOpenModel) onOpenModel(m);
                }
              },
              React.createElement('title', null, m.name + ' — click for the full schema'),
              React.createElement('rect', { className: 'mg-box', width: NODE_W, height: h, rx: 4 }),
              React.createElement('rect', { className: 'mg-box-header', width: NODE_W, height: HEADER_H, rx: 4 }),
              React.createElement('text', { className: 'mg-name', x: 10, y: 15 }, m.name),
              React.createElement('text', { className: 'mg-table', x: 10, y: 27 },
                (m.table || '—') + (m.columnCount ? ' · ' + m.columnCount + ' cols' : '')),
              fields.map(function (c, i) {
                var y = HEADER_H + 11 + i * FIELD_H;
                return React.createElement(
                  React.Fragment,
                  { key: c.name },
                  React.createElement('text', { className: 'mg-field', x: 10, y: y }, c.name),
                  React.createElement('text', { className: 'mg-field-type', x: NODE_W - 10, y: y, textAnchor: 'end' }, c.type)
                );
              }),
              hidden > 0 && React.createElement('text', {
                className: 'mg-field-more', x: 10, y: HEADER_H + 11 + fields.length * FIELD_H
              }, '+' + hidden + ' more…'),
              // No connection means no columns to show; say so rather than
              // rendering an empty box that looks like a model with no fields.
              fields.length === 0 && React.createElement('text', {
                className: 'mg-field-more', x: 10, y: HEADER_H + 11
              }, 'no database connection')
            );
          })
        )
      )
    );
  };
})();

window.ModelGraph = ModelGraph;

// ModelList — the sidebar half: just the models, click to open the diagram or
// jump to a file. The diagram itself needs the full editor width.
var ModelList = (function () {
  return function ModelListComponent(_ref) {
    var graph = _ref.graph;
    var loading = _ref.loading;
    var onRefresh = _ref.onRefresh;
    var onOpenDiagram = _ref.onOpenDiagram;
    var onOpenFile = _ref.onOpenFile;

    if (loading) {
      return React.createElement('div', { className: 'ide-model-graph-empty' }, 'Building the model graph…');
    }
    if (!graph) {
      return React.createElement('div', { className: 'ide-model-graph-empty' }, 'Loading…');
    }
    if (!graph.ok) {
      return React.createElement(
        'div',
        { className: 'ide-model-graph-empty' },
        React.createElement('div', null, graph.error || 'No model graph available.'),
        React.createElement('button', {
          type: 'button', className: 'ide-model-graph-btn', onClick: onRefresh
        }, 'Try again')
      );
    }

    return React.createElement(
      'div',
      { className: 'ide-model-list' },
      React.createElement(
        'div',
        { className: 'ide-model-graph-toolbar' },
        React.createElement('span', null, (graph.models || []).length + ' models'),
        React.createElement('button', {
          type: 'button', className: 'ide-model-graph-btn',
          title: 'Rebuild from the current code', onClick: onRefresh
        }, React.createElement('i', { className: 'fas fa-sync' }))
      ),
      React.createElement('button', {
        type: 'button', className: 'ide-model-open-diagram', onClick: onOpenDiagram
      }, React.createElement('i', { className: 'fas fa-project-diagram' }), ' Open diagram'),
      React.createElement(
        'div',
        { className: 'ide-model-list-items' },
        (graph.models || []).map(function (m) {
          return React.createElement(
            'button',
            {
              key: m.name,
              type: 'button',
              className: 'ide-model-name' + (m.file ? '' : ' ide-model-name-external'),
              title: m.file || m.name + ' is defined outside the workspace',
              disabled: !m.file,
              onClick: function () { if (m.file && onOpenFile) onOpenFile(m.file, 1); }
            },
            m.name,
            React.createElement('span', { className: 'ide-model-count' }, m.table || '')
          );
        })
      )
    );
  };
})();

window.ModelList = ModelList;
