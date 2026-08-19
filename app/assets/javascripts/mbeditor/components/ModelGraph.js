'use strict';

// ModelGraph — an SVG entity diagram of the host app's ActiveRecord models.
//
// Laid out by the Sugiyama method — the same one Graphviz `dot` uses, and so
// the same one Rails ERD produces this picture with. See the layout section
// below for the phases.
//
// Two earlier attempts are worth knowing about, because both looked reasonable
// on a demo app and failed on a real one. A radial layout put the busiest model
// at the centre and fanned the rest out in rings; at 300 models that is a single
// enormous circle, fitted so far out that no box is legible. A clustered grid
// was scannable but placed models by traversal order, so a box's position
// carried no information at all. Only a layered layout derives position from
// the associations themselves.
var ModelGraph = (function () {
  // Boxes are sized to their contents rather than all being one width. A fixed
  // 188px meant a model with a long name or long column names had its labels
  // truncated while a model called Tag wasted most of its box. Clamped at both
  // ends so one pathological name cannot stretch a whole layer.
  var NODE_W_MIN = 168;
  var NODE_W_MAX = 320;
  var NODE_W = NODE_W_MIN;   // fallback for anything without a measured model
  var HEADER_H = 34;      // model name + table name
  var FIELD_H = 15;
  var MAX_FIELDS = 8;     // the rest are one click away in the schema modal
  var ROW_GAP = 36;
  var LAYER_GAP = 110;    // horizontal space between layers
  var ORDER_PASSES = 4;   // median sweeps for crossing reduction
  var STRAIGHTEN_PASSES = 3;
  var MAX_ASSOC_LISTED = 12;
  var MAX_SEARCH_RESULTS = 50;  // the card stays readable; the rest are counted
  var BLOCK_PAD = 26;     // breathing room inside a cluster's boundary
  var BLOCK_GAP = 56;     // space between neighbouring clusters

  // SVG text neither wraps nor ellipsises: a long model or column name simply
  // draws straight out past the edge of its box and over whatever is beside it.
  // Measure with a cached canvas context and cut to fit — accurate for whatever
  // font the theme actually resolves, unlike a characters-per-pixel guess.
  var _measureCtx = null;
  var _measureCache = {};

  function textWidth(text, font) {
    var key = font + '\u0000' + text;
    if (_measureCache[key] !== undefined) return _measureCache[key];
    if (!_measureCtx) {
      if (typeof document === 'undefined') return text.length * 6;
      _measureCtx = document.createElement('canvas').getContext('2d');
    }
    _measureCtx.font = font;
    var w = _measureCtx.measureText(text).width;
    // Unbounded growth would be a leak on a large schema; the cache only needs
    // to cover one render's worth of labels.
    if (Object.keys(_measureCache).length > 4000) _measureCache = {};
    _measureCache[key] = w;
    return w;
  }

  function fitText(text, maxWidth, font) {
    text = String(text == null ? '' : text);
    if (!text || textWidth(text, font) <= maxWidth) return text;
    var lo = 0, hi = text.length;
    while (lo < hi) {
      var mid = Math.ceil((lo + hi) / 2);
      if (textWidth(text.slice(0, mid) + '…', font) <= maxWidth) lo = mid; else hi = mid - 1;
    }
    return lo > 0 ? text.slice(0, lo) + '…' : '…';
  }

  // Must match the .mg-name / .mg-table / .mg-field rules in editor.css.
  var FONT_NAME  = '600 12px ui-monospace, SFMono-Regular, Menlo, monospace';
  var FONT_SMALL = '9px ui-monospace, SFMono-Regular, Menlo, monospace';
  var FONT_FIELD = '10px ui-monospace, SFMono-Regular, Menlo, monospace';

  function nodeWidth(model) {
    if (model && model.__mgWidth) return model.__mgWidth;
    if (!model) return NODE_W;

    // Header: name plus the open-schema button, and the table/count line.
    var need = textWidth(String(model.name || ''), FONT_NAME) + 20 + 26;
    need = Math.max(need, textWidth(
      (model.table || '—') + (model.columnCount ? ' · ' + model.columnCount + ' cols' : ''),
      FONT_SMALL) + 20 + 26);

    (model.columns || []).slice(0, MAX_FIELDS).forEach(function (c) {
      // name on the left, type right-aligned, with a gap between them
      need = Math.max(need,
        textWidth(String(c.name || ''), FONT_FIELD) +
        textWidth(String(c.type || ''), FONT_SMALL) + 32);
    });

    var w = Math.round(Math.min(NODE_W_MAX, Math.max(NODE_W_MIN, need)));
    try { model.__mgWidth = w; } catch (e) { /* frozen payload — recompute */ }
    return w;
  }

  function nodeHeight(model) {
    var shown = Math.min((model.columns || []).length, MAX_FIELDS);
    var more = (model.columnCount || 0) > shown ? FIELD_H : 0;
    // With no columns the box still draws one line — "no database connection" —
    // and not counting it left that text hanging below the box it belongs to.
    var placeholder = shown === 0 ? FIELD_H : 0;
    return HEADER_H + shown * FIELD_H + more + placeholder + 8;
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

  // ── Layout: Sugiyama layered, the standard for entity diagrams ────────────
  //
  // Associations are directed (belongs_to points a child at its parent), which
  // is exactly the input a layered layout wants, and it is what Graphviz `dot`
  // uses — and therefore Rails ERD, the usual tool for drawing this picture.
  // The four classic phases: break cycles, assign layers, order within layers
  // to cut crossings, then assign coordinates.
  //
  // Earlier attempts placed models by traversal order poured into grid cells.
  // That put related models near each other only by accident: a box's position
  // carried no information, so the diagram could not actually be read.

  // Unique directed edges; self-references are dropped as placement constraints.
  function directedEdges(models, edges) {
    var known = {};
    models.forEach(function (m) { known[m.name] = true; });
    var seen = {};
    var out = [];
    edges.forEach(function (e) {
      if (!known[e.from] || !known[e.to] || e.from === e.to) return;
      var key = e.from + ' ' + e.to;
      if (seen[key]) return;
      seen[key] = true;
      out.push({ from: e.from, to: e.to });
    });
    return out;
  }

  // Phase 1 — break cycles. Rails schemas are full of them (a belongs_to paired
  // with a has_many the other way, or a genuine loop), and layering needs a DAG.
  // Depth-first search, dropping any edge that points back at a node still on
  // the stack. Those edges are still drawn in their true direction; they just
  // stop constraining which layer a node lands in.
  function breakCycles(names, edges) {
    var out = {}, state = {};   // 0 unvisited, 1 on stack, 2 done
    names.forEach(function (n) { out[n] = []; state[n] = 0; });
    edges.forEach(function (e) { out[e.from].push(e.to); });

    var acyclic = [];
    names.forEach(function (root) {
      if (state[root] !== 0) return;
      // Iterative: a 300-model schema nests deeper than is comfortable for
      // recursion.
      var stack = [{ node: root, i: 0 }];
      state[root] = 1;
      while (stack.length) {
        var top = stack[stack.length - 1];
        if (top.i < out[top.node].length) {
          var next = out[top.node][top.i++];
          if (state[next] === 1) continue;
          acyclic.push({ from: top.node, to: next });
          if (state[next] === 0) { state[next] = 1; stack.push({ node: next, i: 0 }); }
        } else {
          state[top.node] = 2;
          stack.pop();
        }
      }
    });
    return acyclic;
  }

  // Phase 2 — longest-path layering. A node sits one layer past its deepest
  // predecessor, so every edge points forwards and depth reads left to right.
  function assignLayers(names, acyclic) {
    var incoming = {}, outgoing = {}, indeg = {};
    names.forEach(function (n) { incoming[n] = []; outgoing[n] = []; indeg[n] = 0; });
    acyclic.forEach(function (e) {
      outgoing[e.from].push(e.to);
      incoming[e.to].push(e.from);
      indeg[e.to]++;
    });

    var layer = {};
    var queue = names.filter(function (n) { return indeg[n] === 0; });
    queue.forEach(function (n) { layer[n] = 0; });

    var pending = {};
    names.forEach(function (n) { pending[n] = indeg[n]; });

    while (queue.length) {
      var n = queue.shift();
      outgoing[n].forEach(function (m) {
        layer[m] = Math.max(layer[m] || 0, layer[n] + 1);
        if (--pending[m] === 0) queue.push(m);
      });
    }
    // Anything left sits in a knot the cycle-breaker could not fully unwind;
    // park it past its deepest known predecessor rather than dropping it.
    names.forEach(function (n) {
      if (layer[n] !== undefined) return;
      var base = 0;
      incoming[n].forEach(function (p) { base = Math.max(base, (layer[p] || 0) + 1); });
      layer[n] = base;
    });
    return layer;
  }

  // Phase 3 — crossing reduction by the median heuristic, swept down then up.
  // Each node moves to the median position of its neighbours in the adjacent
  // layer; repeated sweeps settle into far fewer crossings than any fixed
  // ordering. This is the same heuristic dot uses.
  function orderLayers(layers, adjIn, adjOut) {
    var pos = {};
    layers.forEach(function (names) {
      names.forEach(function (n, i) { pos[n] = i; });
    });

    var medianOf = function (name, neighbours) {
      var ps = (neighbours[name] || []).map(function (nb) { return pos[nb]; })
        .filter(function (v) { return v !== undefined; })
        .sort(function (a, b) { return a - b; });
      if (!ps.length) return -1;
      var mid = Math.floor(ps.length / 2);
      return ps.length % 2 ? ps[mid] : (ps[mid - 1] + ps[mid]) / 2;
    };

    var sweep = function (from, to, step, neighbours) {
      for (var li = from; li !== to; li += step) {
        var names = layers[li];
        if (!names || !names.length) continue;
        var keyed = names.map(function (n, i) { return { n: n, m: medianOf(n, neighbours), i: i }; });
        keyed.sort(function (a, b) {
          // A node with no neighbour in the reference layer keeps its relative
          // place rather than being bunched at one end.
          if (a.m < 0 && b.m < 0) return a.i - b.i;
          if (a.m < 0) return -1;
          if (b.m < 0) return 1;
          return a.m - b.m || a.i - b.i;
        });
        layers[li] = keyed.map(function (k) { return k.n; });
        layers[li].forEach(function (n, i) { pos[n] = i; });
      }
    };

    for (var pass = 0; pass < ORDER_PASSES; pass++) {
      sweep(1, layers.length, 1, adjIn);
      sweep(layers.length - 2, -1, -1, adjOut);
    }
    return layers;
  }

  // Phase 4 — coordinates. x is the layer; y stacks within a layer, then a few
  // relaxation passes pull each node toward the average of its neighbours so
  // chains come out straight instead of stepped. After each pass the layer is
  // re-separated in order, so relaxation can never overlap two boxes.
  function assignCoords(layers, byName, adjIn, adjOut) {
    var y = {};
    layers.forEach(function (names) {
      if (!names) return;
      var cursor = 0;
      names.forEach(function (n) {
        y[n] = cursor;
        cursor += nodeHeight(byName[n]) + ROW_GAP;
      });
    });

    for (var pass = 0; pass < STRAIGHTEN_PASSES; pass++) {
      layers.forEach(function (names) {
        if (!names || !names.length) return;
        names.forEach(function (n) {
          var ns = (adjIn[n] || []).concat(adjOut[n] || []);
          var vals = ns.map(function (nb) { return y[nb]; })
            .filter(function (v) { return v !== undefined; });
          if (!vals.length) return;
          var want = vals.reduce(function (a, b) { return a + b; }, 0) / vals.length;
          y[n] = y[n] + (want - y[n]) * 0.5;
        });
        var cursor = -Infinity;
        names.forEach(function (n) {
          if (y[n] < cursor) y[n] = cursor;
          cursor = y[n] + nodeHeight(byName[n]) + ROW_GAP;
        });
      });
    }

    var minY = Infinity;
    Object.keys(y).forEach(function (n) { minY = Math.min(minY, y[n]); });
    if (!isFinite(minY)) minY = 0;

    // Layers are as wide as their widest box, and each starts where the previous
    // one ended. A fixed stride assumed every box was NODE_W and would overlap
    // the next layer as soon as one of them grew.
    var layerX = [];
    var cursorX = 0;
    layers.forEach(function (names, li) {
      layerX[li] = cursorX;
      var widest = 0;
      (names || []).forEach(function (n) { widest = Math.max(widest, nodeWidth(byName[n])); });
      cursorX += (widest || NODE_W_MIN) + LAYER_GAP;
    });

    var positions = {};
    var maxX = 0, maxY = 0;
    layers.forEach(function (names, li) {
      if (!names) return;
      names.forEach(function (n) {
        var x = layerX[li];
        var yy = y[n] - minY;
        positions[n] = { x: x, y: yy, model: byName[n] };
        maxX = Math.max(maxX, x + nodeWidth(byName[n]));
        maxY = Math.max(maxY, yy + nodeHeight(byName[n]));
      });
    });
    return { positions: positions, width: maxX, height: maxY };
  }

  // Connected components are laid out independently and stacked, the way dot
  // handles a disconnected graph. Packing them together would interleave
  // unrelated parts of the schema for no reason.
  function components(names, adj) {
    var seen = {}, out = [];
    names.forEach(function (start) {
      if (seen[start]) return;
      var group = [], queue = [start];
      seen[start] = true;
      while (queue.length) {
        var cur = queue.shift();
        group.push(cur);
        Object.keys(adj[cur] || {}).forEach(function (nb) {
          if (seen[nb]) return;
          seen[nb] = true;
          queue.push(nb);
        });
      }
      out.push(group);
    });
    return out.sort(function (a, b) { return b.length - a.length; });
  }

  function layout(models, edges) {
    var byName = {};
    models.forEach(function (m) { byName[m.name] = m; });

    var dir = directedEdges(models, edges);
    var adj = adjacency(models, edges);
    var allNames = models.map(function (m) { return m.name; });

    var positions = {};
    var regions = [];
    var pad = 60;

    // Lay each component out first, then pack the finished blocks. Blocks used
    // to be stacked in a single column, so a schema with a big connected core
    // and a handful of one-model islands ran off the bottom of the canvas with
    // the whole right-hand side empty. Shelf packing wraps them instead, which
    // is both more compact and closer to how the eye scans a page.
    var blocks = components(allNames, adj).map(function (group) {
      var inGroup = {};
      group.forEach(function (n) { inGroup[n] = true; });
      var groupEdges = dir.filter(function (e) { return inGroup[e.from] && inGroup[e.to]; });

      var acyclic = breakCycles(group, groupEdges);
      var layerOf = assignLayers(group, acyclic);

      var layers = [];
      group.forEach(function (n) {
        var l = layerOf[n] || 0;
        (layers[l] = layers[l] || []).push(n);
      });
      for (var i = 0; i < layers.length; i++) if (!layers[i]) layers[i] = [];
      layers.forEach(function (names) { names.sort(); }); // deterministic start

      var adjIn = {}, adjOut = {};
      group.forEach(function (n) { adjIn[n] = []; adjOut[n] = []; });
      acyclic.forEach(function (e) { adjOut[e.from].push(e.to); adjIn[e.to].push(e.from); });

      orderLayers(layers, adjIn, adjOut);
      var laid = assignCoords(layers, byName, adjIn, adjOut);

      return {
        laid: laid,
        group: group,
        w: laid.width + BLOCK_PAD * 2,
        h: laid.height + BLOCK_PAD * 2
      };
    });

    // Wrap at whichever is wider: a roughly square canvas, or the widest single
    // block (which can never be split).
    var totalArea = blocks.reduce(function (a, b) { return a + b.w * b.h; }, 0);
    var widest = blocks.reduce(function (a, b) { return Math.max(a, b.w); }, 0);
    var targetW = Math.max(widest, Math.sqrt(totalArea * 1.6));

    var shelfX = pad, shelfY = pad, shelfH = 0, maxRight = pad;

    blocks.forEach(function (b) {
      if (shelfX > pad && shelfX + b.w > pad + targetW) {
        shelfX = pad;
        shelfY += shelfH + BLOCK_GAP;
        shelfH = 0;
      }

      Object.keys(b.laid.positions).forEach(function (n) {
        var q = b.laid.positions[n];
        positions[n] = {
          x: shelfX + BLOCK_PAD + q.x,
          y: shelfY + BLOCK_PAD + q.y,
          model: q.model
        };
      });

      regions.push({
        x: shelfX, y: shelfY, w: b.w, h: b.h,
        label: b.group.length > 1 ? b.group.length + ' related models' : b.group[0]
      });

      maxRight = Math.max(maxRight, shelfX + b.w);
      shelfH = Math.max(shelfH, b.h);
      shelfX += b.w + BLOCK_GAP;
    });

    return {
      positions: positions,
      regions: regions,
      width: maxRight + pad,
      height: shelfY + shelfH + pad
    };
  }

  function anchors(a, b) {
    var ah = nodeHeight(a.model), bh = nodeHeight(b.model);
    var aw = nodeWidth(a.model), bw = nodeWidth(b.model);
    var acx = a.x + aw / 2, acy = a.y + ah / 2;
    var bcx = b.x + bw / 2, bcy = b.y + bh / 2;
    var horizontal = Math.abs(bcx - acx) > Math.abs(bcy - acy);

    if (horizontal) {
      return bcx > acx
        ? { x1: a.x + aw, y1: acy, x2: b.x, y2: bcy, h: true }
        : { x1: a.x, y1: acy, x2: b.x + bw, y2: bcy, h: true };
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

  // What the association means in cardinality terms, since the arrow alone
  // only shows direction.
  var MACRO_CARDINALITY = {
    belongs_to: 'many → one',
    has_one: 'one → one',
    has_many: 'one → many',
    has_and_belongs_to_many: 'many ↔ many'
  };

  // Low enough that a few hundred models genuinely fit on screen. At the old
  // 0.2 floor a large app could not be framed at all, so fit-to-pane produced a
  // view the zoom controls then refused to honour.
  var MIN_ZOOM = 0.04;
  var MAX_ZOOM = 2.5;

  return function ModelGraphComponent(_ref) {
    var graph = _ref.graph;
    var onOpenModel = _ref.onOpenModel;
    var onRefresh = _ref.onRefresh;
    var loading = _ref.loading;

    // The view is a ref, not state, and is written straight onto the <g>'s
    // transform. Every pan and zoom tick used to be a setState, which re-ran the
    // whole layout (it was computed in the render body) and rebuilt every box,
    // field and edge — around 10,000 SVG elements on a 300-model app. That is
    // what made the graph unusable at real scale rather than anything about the
    // drawing itself.
    var viewRef = React.useRef({ k: 1, x: 0, y: 0 });
    var sceneRef = React.useRef(null);
    // Which layout we have already framed, so reopening the tab refits but a
    // re-render for any other reason does not yank the view back.
    var fittedForRef = React.useRef(null);

    var applyView = React.useCallback(function () {
      var g = sceneRef.current;
      if (!g) return;
      var v = viewRef.current;
      g.setAttribute('transform', 'translate(' + v.x + ',' + v.y + ') scale(' + v.k + ')');
    }, []);

    var setView = React.useCallback(function (next) {
      viewRef.current = typeof next === 'function' ? next(viewRef.current) : next;
      applyView();
    }, [applyView]);

    var _search = React.useState('');
    var search = _search[0], setSearch = _search[1];
    var _searchOpen = React.useState(false);
    var searchOpen = _searchOpen[0], setSearchOpen = _searchOpen[1];
    var _highlight = React.useState(0);
    var highlight = _highlight[0], setHighlight = _highlight[1];
    var _focused = React.useState(null);
    var focused = _focused[0], setFocused = _focused[1];
    var _hovered = React.useState(null);
    var hovered = _hovered[0], setHovered = _hovered[1];
    var _pointer = React.useState({ x: 0, y: 0 });
    var pointer = _pointer[0], setPointer = _pointer[1];
    var dragRef = React.useRef(null);
    var svgRef = React.useRef(null);

    // Memoised on the graph payload. This used to run on every render — which,
    // with the view in state, meant on every wheel tick and every mousemove of a
    // drag.
    var placed = React.useMemo(function () {
      return (graph && graph.ok && (graph.models || []).length)
        ? layout(graph.models, graph.edges || [])
        : null;
    }, [graph]);

    // Every association each model takes part in, both directions, built once.
    // Scanning the edge list per hover would be 513 comparisons on every
    // mouseenter across a canvas of 300 boxes.
    var associationsBy = React.useMemo(function () {
      var byModel = {};
      (graph && graph.edges || []).forEach(function (e) {
        (byModel[e.from] = byModel[e.from] || []).push({ edge: e, outgoing: true });
        if (e.to !== e.from) (byModel[e.to] = byModel[e.to] || []).push({ edge: e, outgoing: false });
      });
      return byModel;
    }, [graph]);

    // Prefix matches first, then anything containing the term — the ordering a
    // name-completion list is expected to have. Capped so a large schema cannot
    // render a list taller than the window.
    var searchMatches = React.useMemo(function () {
      var all = (graph && graph.models) || [];
      var q = search.trim().toLowerCase();
      if (!q) return all.slice(0, MAX_SEARCH_RESULTS);
      var starts = [], contains = [];
      all.forEach(function (m) {
        var i = m.name.toLowerCase().indexOf(q);
        if (i === 0) starts.push(m); else if (i > 0) contains.push(m);
      });
      return starts.concat(contains).slice(0, MAX_SEARCH_RESULTS);
    }, [graph, search]);

    var hoverCardRef = React.useRef(null);
    var _modelHover = React.useState(null);
    var modelHover = _modelHover[0], setModelHover = _modelHover[1];

    // Highlighting is done by touching the DOM directly. Routing it through
    // React would rebuild all ~7,000 elements of the scene on every mouseenter,
    // which is the same trap the pan/zoom transform was in.
    var litRef = React.useRef([]);
    var clearLit = React.useCallback(function () {
      litRef.current.forEach(function (el) { el.classList.remove('mg-lit'); });
      litRef.current = [];
      if (sceneRef.current) sceneRef.current.classList.remove('mg-focus-mode');
    }, []);

    var moveHoverCard = React.useCallback(function (ev) {
      var card = hoverCardRef.current;
      var el = svgRef.current;
      if (!card || !el) return;
      var rect = el.getBoundingClientRect();
      var x = ev.clientX - rect.left;
      var y = ev.clientY - rect.top;
      // Flip before the card would run off the pane rather than after.
      card.style.left = (x > rect.width - 300 ? x - 290 : x + 18) + 'px';
      card.style.top = Math.min(y + 18, Math.max(0, rect.height - 240)) + 'px';
    }, []);

    var enterModel = React.useCallback(function (name, ev) {
      if (dragRef.current) return;   // panning, not inspecting
      clearLit();
      var scene = sceneRef.current;
      if (scene) {
        scene.classList.add('mg-focus-mode');
        var sel = '[data-from="' + name + '"],[data-to="' + name + '"]';
        litRef.current = Array.prototype.slice.call(scene.querySelectorAll(sel));
        litRef.current.forEach(function (el) { el.classList.add('mg-lit'); });
      }
      setModelHover(name);
      moveHoverCard(ev);
    }, [clearLit, moveHoverCard]);

    var leaveModel = React.useCallback(function () {
      clearLit();
      setModelHover(null);
    }, [clearLit]);

    // Frame the whole graph on load. Without this the view starts at the
    // top-left of a canvas much larger than the pane and the diagram looks
    // empty until you go looking for it.
    var fitToPane = React.useCallback(function (attempt) {
      var el = svgRef.current;
      if (!el || !placed) return;
      var rect = el.getBoundingClientRect();
      // The pane can still be unsized on the commit that mounts the SVG — the
      // graph tab is opening at the same time. Bailing out here left the view at
      // its 1:1 default and nothing ever retried, so a 300-model graph opened
      // showing one corner of itself. Retry on the next frames until it has a
      // size, then give up rather than spin.
      if (!rect.width || !rect.height) {
        if ((attempt || 0) < 10) {
          window.requestAnimationFrame(function () { fitRef.current((attempt || 0) + 1); });
        }
        return;
      }

      // Clamped to the same range the wheel enforces. Without the MIN_ZOOM
      // clamp a large graph fitted to something like k=0.04, which is below the
      // floor — so the first scroll snapped it up to MIN_ZOOM, a five-fold jump
      // anchored on the cursor, and the diagram appeared to leap somewhere
      // random. The view must never sit outside the range the controls allow.
      var raw = Math.min(rect.width / placed.width, rect.height / placed.height);
      var k = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, Math.min(1, raw)));
      setView({
        k: k,
        x: (rect.width - placed.width * k) / 2,
        y: (rect.height - placed.height * k) / 2
      });
    }, [placed, setView]);

    React.useEffect(function () { fitToPane(); }, [fitToPane]);

    // Bring one model to the middle of the pane at the current zoom, and mark
    // it so it's findable in a dense graph once it gets there.
    var centreOn = React.useCallback(function (name) {
      var el = svgRef.current;
      var pos = placed && placed.positions[name];
      if (!el || !pos) return;
      var rect = el.getBoundingClientRect();
      var h = nodeHeight(pos.model);
      setFocused(name);
      setView(function (v) {
        // Close half the distance to actual size, so a model found while
        // fitted (often ~0.3) lands readable. Never zooms out: if you were
        // already past 1:1 you meant to be there.
        var k = v.k >= 1 ? v.k : Math.min(MAX_ZOOM, v.k + (1 - v.k) / 2);
        return {
          k: k,
          x: rect.width / 2 - (pos.x + nodeWidth(pos.model) / 2) * k,
          y: rect.height / 2 - (pos.y + h / 2) * k
        };
      });
    }, [placed]);

    // Same mounting problem as the wheel listener: the fit effect can run
    // before the SVG exists and not again afterwards. Kept current so the
    // callback ref can fit as soon as the element is really there.
    // Held in a ref so the memoised node elements can call it without listing it
    // as a dependency — otherwise every centre would rebuild the whole scene.
    var centreRef = React.useRef(centreOn);
    centreRef.current = centreOn;

    // Same reason as centreRef: MbeditorApp passes a fresh closure on every one
    // of its renders, and listing onOpenModel in the scene memo's deps rebuilt
    // all ~10,000 SVG elements each time — once per keystroke, whenever this
    // tab happened to be open.
    var openModelRef = React.useRef(onOpenModel);
    openModelRef.current = onOpenModel;

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

      // getBoundingClientRect forces a synchronous layout, and we had just
      // written a new transform onto a <g> holding thousands of elements — so
      // reading it per wheel tick made the browser re-lay-out the entire scene
      // before the handler could continue. Measured at 27 ms a tick on a
      // 300-model graph. The pane's own rect only changes when the window or
      // the panel layout does, so cache it and refresh once per frame.
      var rectRef = { current: null };
      var invalidateRect = function () { rectRef.current = null; };
      var paneRect = function () {
        if (!rectRef.current) {
          rectRef.current = el.getBoundingClientRect();
          window.requestAnimationFrame(invalidateRect);
        }
        return rectRef.current;
      };

      var onWheel = function (e) {
        e.preventDefault();
        var rect = paneRect();
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

    // Memoised so hovering a model does not rebuild every box and edge.
    // The highlight itself is applied by toggling DOM classes; only the
    // association card is React state, and it lives outside this subtree.
    var sceneChildren = React.useMemo(function () {
      if (!placed) return null;
      var models = (graph && graph.models) || [];
      var edges = (graph && graph.edges) || [];
      return [
          // Behind everything: one soft area per connected cluster, so the
          // grouping is something you can see rather than infer.
          (placed.regions || []).map(function (r, i) {
            return React.createElement(
              'g',
              { key: 'r' + i, className: 'mg-region' },
              React.createElement('rect', {
                className: 'mg-region-box',
                x: r.x, y: r.y, width: r.w, height: r.h, rx: 10
              }),
              React.createElement('text', {
                className: 'mg-region-label', x: r.x + 12, y: r.y + 17
              }, r.label)
            );
          }),
          edges.map(function (e, i) {
            var a = placed.positions[e.from];
            var b = placed.positions[e.to];
            if (!a || !b || e.from === e.to) return null;
            var d = edgePath(a, b);
            return React.createElement(
              'g',
              // Tagged so a node hover can find its own edges with one DOM query
              // instead of a React pass over every edge.
              { key: 'e' + i, 'data-from': e.from, 'data-to': e.to },
              // A transparent, much thicker copy of the line under the real
              // one. A 1.2px stroke is its own hit area, which makes hovering
              // an association essentially impossible without this.
              React.createElement('path', {
                d: d,
                className: 'mg-edge-hit',
                // The lit class goes on the DOM node directly, the way
                // enterModel/litRef do. `hovered` is React state read from
                // inside this memo, and it is deliberately not a dep — putting
                // it there would rebuild the whole scene on every edge hover —
                // so a className derived from it never updated at all.
                onMouseEnter: function (ev) {
                  var line = ev.currentTarget.nextElementSibling;
                  if (line) line.classList.add('mg-edge-hovered');
                  setHovered({ index: i, edge: e });
                },
                onMouseMove: function (ev) {
                  var rect = svgRef.current.getBoundingClientRect();
                  setPointer({ x: ev.clientX - rect.left, y: ev.clientY - rect.top });
                },
                onMouseLeave: function (ev) {
                  var line = ev.currentTarget.nextElementSibling;
                  if (line) line.classList.remove('mg-edge-hovered');
                  setHovered(null);
                }
              }),
              React.createElement('path', {
                d: d,
                className: 'mg-edge ' + (MACRO_CLASS[e.macro] || ''),
                markerEnd: 'url(#mg-arrow)'
              })
            );
          }),
          models.map(function (m) {
            var pos = placed.positions[m.name];
            if (!pos) return null;
            var fields = (m.columns || []).slice(0, MAX_FIELDS);
            var hidden = (m.columnCount || 0) - fields.length;
            var h = nodeHeight(m);
            var w = nodeWidth(m);
            return React.createElement(
              'g',
              {
                key: m.name,
                className: 'mg-node' + (focused === m.name ? ' mg-focused' : ''),
                transform: 'translate(' + pos.x + ',' + pos.y + ')',
                onMouseEnter: function (ev) { enterModel(m.name, ev); },
                onMouseMove: function (ev) { moveHoverCard(ev); },
                onMouseLeave: function () { leaveModel(); },
                onClick: function () {
                  // A drag that ends over a box must not also act on it.
                  if (dragRef.current && dragRef.current.moved) return;
                  // Clicking the box navigates: zoom to it. Opening the schema
                  // is the explicit button in the header, so a stray click while
                  // exploring no longer throws a modal in your way.
                  centreRef.current(m.name);
                }
              },
              React.createElement('rect', { className: 'mg-box', width: w, height: h, rx: 4 }),
              React.createElement('rect', { className: 'mg-box-header', width: w, height: HEADER_H, rx: 4 }),
              // Budget stops short of the header button, which sits at w - 26.
              React.createElement('text', { className: 'mg-name', x: 10, y: 15 },
                fitText(m.name, w - 44, FONT_NAME)),
              React.createElement('text', { className: 'mg-table', x: 10, y: 27 },
                fitText((m.table || '—') + (m.columnCount ? ' · ' + m.columnCount + ' cols' : ''),
                        w - 44, FONT_SMALL)),
              // Opening the full schema is now an explicit target rather than
              // anything-anywhere on the box, so clicking around to navigate
              // cannot keep throwing a modal at you.
              React.createElement(
                'g',
                {
                  className: 'mg-open-btn',
                  onClick: function (ev) {
                    ev.stopPropagation();
                    if (dragRef.current && dragRef.current.moved) return;
                    if (openModelRef.current) openModelRef.current(m);
                  }
                },
                React.createElement('title', null, 'Open the full schema for ' + m.name),
                React.createElement('rect', {
                  className: 'mg-open-btn-bg', x: w - 26, y: 7, width: 19, height: 19, rx: 3
                }),
                // Three stacked bars — a table, matching what the button opens.
                React.createElement('rect', { className: 'mg-open-btn-bar', x: w - 22, y: 11, width: 11, height: 2 }),
                React.createElement('rect', { className: 'mg-open-btn-bar', x: w - 22, y: 15.5, width: 11, height: 2 }),
                React.createElement('rect', { className: 'mg-open-btn-bar', x: w - 22, y: 20, width: 11, height: 2 })
              ),
              fields.map(function (c, i) {
                var y = HEADER_H + 11 + i * FIELD_H;
                var typeW = Math.min(64, textWidth(String(c.type == null ? '' : c.type), FONT_SMALL));
                return React.createElement(
                  React.Fragment,
                  { key: c.name },
                  // The type is right-aligned, so the name's budget is whatever
                  // the type does not claim — otherwise the two met in the middle.
                  React.createElement('text', { className: 'mg-field', x: 10, y: y },
                    fitText(c.name, w - 28 - typeW, FONT_FIELD)),
                  React.createElement('text', { className: 'mg-field-type', x: w - 10, y: y, textAnchor: 'end' },
                    fitText(c.type, 64, FONT_SMALL))
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
      ];
    }, [placed, graph, focused]);

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
      var v = viewRef.current;
      dragRef.current = { sx: e.clientX, sy: e.clientY, ox: v.x, oy: v.y, moved: false };
      if (svgRef.current) svgRef.current.classList.add('mg-dragging');
    };
    var onMouseMove = function (e) {
      var d = dragRef.current;
      if (!d) return;
      var dx = e.clientX - d.sx, dy = e.clientY - d.sy;
      if (Math.abs(dx) > 3 || Math.abs(dy) > 3) d.moved = true;
      setView(function (v) { return { k: v.k, x: d.ox + dx, y: d.oy + dy }; });
    };
    var endDrag = function () {
      dragRef.current = null;
      if (svgRef.current) svgRef.current.classList.remove('mg-dragging');
    };

    return React.createElement(
      'div',
      { className: 'ide-model-graph' },
      React.createElement(
        'div',
        { className: 'ide-model-graph-toolbar' },
        React.createElement('span', null, models.length + ' models, ' + edges.length + ' associations'),
        graph.truncated && React.createElement('span', { className: 'ide-model-graph-warn' }, ' (truncated)'),
        React.createElement('span', { className: 'ide-model-graph-hint' }, 'drag to pan · scroll to zoom · click a model to zoom to it · hover for its associations'),
        React.createElement(
          'div',
          { className: 'ide-model-graph-actions' },
          // A real dropdown rather than a native <datalist>. The datalist was
          // chosen to get filtering and keyboard handling for free, but the
          // browser renders it as an unstyleable list in the platform's own
          // chrome — wrong font, wrong colours, and no way to show which model
          // is in which cluster. This is a few more lines and looks like the
          // rest of the editor.
          React.createElement(
            'div',
            { className: 'mg-search-wrap' },
            React.createElement('input', {
              className: 'ide-model-graph-search',
              type: 'text',
              placeholder: 'Centre on a model…',
              value: search,
              onChange: function (e) { setSearch(e.target.value); setSearchOpen(true); setHighlight(0); },
              onFocus: function () { setSearchOpen(true); },
              // A click on an option would otherwise be lost: blur fires first
              // and unmounts the list before mousedown lands.
              onBlur: function () { window.setTimeout(function () { setSearchOpen(false); }, 120); },
              onKeyDown: function (e) {
                if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                  e.preventDefault();
                  setSearchOpen(true);
                  setHighlight(function (h) {
                    var next = h + (e.key === 'ArrowDown' ? 1 : -1);
                    if (next < 0) return searchMatches.length - 1;
                    if (next >= searchMatches.length) return 0;
                    return next;
                  });
                  return;
                }
                if (e.key === 'Escape') { setSearchOpen(false); return; }
                if (e.key !== 'Enter') return;
                var pick = searchMatches[highlight] || searchMatches[0];
                if (pick) { setSearch(pick.name); setSearchOpen(false); centreOn(pick.name); }
              }
            }),
            searchOpen && searchMatches.length > 0 && React.createElement(
              'ul',
              { className: 'mg-search-list' },
              searchMatches.map(function (m, i) {
                return React.createElement(
                  'li',
                  {
                    key: m.name,
                    className: 'mg-search-option' + (i === highlight ? ' mg-search-option-active' : ''),
                    onMouseEnter: function () { setHighlight(i); },
                    onMouseDown: function (ev) {
                      ev.preventDefault();   // keep focus so blur cannot beat us
                      setSearch(m.name);
                      setSearchOpen(false);
                      centreOn(m.name);
                    }
                  },
                  React.createElement('span', { className: 'mg-search-option-name' }, m.name),
                  React.createElement('span', { className: 'mg-search-option-meta' },
                    (m.table || '') + (m.columnCount ? ' · ' + m.columnCount + ' cols' : ''))
                );
              })
            )
          ),
          React.createElement('button', {
            type: 'button', className: 'ide-model-graph-btn', title: 'Fit the whole graph',
            onClick: fitToPane
          }, React.createElement('i', { className: 'fas fa-compress-arrows-alt' })),
          React.createElement('button', {
            type: 'button', className: 'ide-model-graph-btn',
            title: 'Rebuild from the current code', onClick: onRefresh
          }, React.createElement('i', { className: 'fas fa-sync' }))
        )
      ),
      // Every association a hovered model takes part in. The graph shows that a
      // line exists; this says what it actually is, which is the thing you need
      // when a model has a dozen of them fanning out.
      React.createElement(
        'div',
        {
          ref: hoverCardRef,
          className: 'mg-assoc-card' + (modelHover ? '' : ' mg-assoc-card-hidden')
        },
        modelHover && React.createElement('div', { className: 'mg-assoc-title' }, modelHover),
        modelHover && (function () {
          var list = associationsBy[modelHover] || [];
          if (!list.length) {
            return React.createElement('div', { className: 'mg-assoc-empty' }, 'No associations');
          }
          return React.createElement(
            'div',
            { className: 'mg-assoc-list' },
            React.createElement('div', { className: 'mg-assoc-count' },
              list.length + (list.length === 1 ? ' association' : ' associations')),
            list.slice(0, MAX_ASSOC_LISTED).map(function (a, i) {
              var e = a.edge;
              var other = a.outgoing ? e.to : e.from;
              return React.createElement(
                'div',
                { key: i, className: 'mg-assoc-row' },
                React.createElement('span', {
                  className: 'mg-assoc-dot ' + (MACRO_CLASS[e.macro] || '')
                }),
                React.createElement('span', { className: 'mg-assoc-macro' }, e.macro),
                React.createElement('span', { className: 'mg-assoc-name' }, ':' + e.name),
                React.createElement('span', { className: 'mg-assoc-dir' },
                  (a.outgoing ? '→ ' : '← ') + other),
                e.through && React.createElement('span', { className: 'mg-assoc-through' },
                  'through :' + e.through)
              );
            }),
            list.length > MAX_ASSOC_LISTED && React.createElement('div', { className: 'mg-assoc-more' },
              '+' + (list.length - MAX_ASSOC_LISTED) + ' more')
          );
        })()
      ),
      hovered && React.createElement(
        'div',
        {
          className: 'mg-tooltip',
          // Offset from the cursor, and flipped left near the right edge so
          // the tooltip never runs off the pane.
          style: {
            left: pointer.x + (svgRef.current && pointer.x > svgRef.current.clientWidth - 260 ? -240 : 14) + 'px',
            top: (pointer.y + 14) + 'px'
          }
        },
        React.createElement('div', { className: 'mg-tooltip-title' },
          hovered.edge.from + ' → ' + hovered.edge.to),
        React.createElement('div', { className: 'mg-tooltip-macro' },
          hovered.edge.macro + ' :' + hovered.edge.name),
        React.createElement('div', { className: 'mg-tooltip-meta' },
          MACRO_CARDINALITY[hovered.edge.macro] || hovered.edge.macro),
        hovered.edge.through && React.createElement('div', { className: 'mg-tooltip-meta' },
          'through :' + hovered.edge.through)
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
          {
            // No transform prop: applyView writes it directly, so panning and
            // zooming never touch React.
            ref: function (el) {
              sceneRef.current = el;
              if (!el) return;
              applyView();
              // Fit here rather than only from an effect. The effect fires
              // before the tab has been given its size, so it measured a
              // zero-width pane and bailed, leaving a 300-model graph opening at
              // 1:1 showing one corner. This runs once per layout, on the frame
              // after the scene actually exists.
              if (fittedForRef.current !== placed) {
                fittedForRef.current = placed;
                window.requestAnimationFrame(function () { fitRef.current(); });
              }
            }
          },
          sceneChildren
        )
      )
    );
  };
})();

window.ModelGraph = ModelGraph;
