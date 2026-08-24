'use strict';

// Monaco DocumentColorProvider for color literals in ALL languages except the
// CSS family (css/scss/less) — Monaco's own language services already provide
// color decorators + picker for those, so registering again would duplicate swatches.
(function () {
  var _registered = false;

  var HEX_RE = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/g;
  // rgb(), rgba(), hsl(), hsla() — bounded, no nested parens.
  var FUNC_RE = /\b(rgba?|hsla?)\(\s*[^()]{0,80}?\)/gi;

  function clamp01(n) { return n < 0 ? 0 : n > 1 ? 1 : n; }

  // Parse a hex literal into {red,green,blue,alpha} in 0..1, or null.
  function parseHex(text) {
    var h = text.slice(1);
    if (h.length === 3 || h.length === 4) {
      h = h.split('').map(function (c) { return c + c; }).join('');
    }
    if (h.length !== 6 && h.length !== 8) return null;
    var r = parseInt(h.slice(0, 2), 16);
    var g = parseInt(h.slice(2, 4), 16);
    var b = parseInt(h.slice(4, 6), 16);
    var a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    if (isNaN(r) || isNaN(g) || isNaN(b)) return null;
    return { red: r / 255, green: g / 255, blue: b / 255, alpha: a };
  }

  function parseFunc(text) {
    var fn = text.slice(0, text.indexOf('(')).toLowerCase();
    var inner = text.slice(text.indexOf('(') + 1, text.lastIndexOf(')'));
    var parts = inner.split(/[,\/\s]+/).filter(function (s) { return s.length; });
    if (parts.length < 3) return null;
    function num(p, max) {
      if (p == null) return null;
      if (p.charAt(p.length - 1) === '%') return clamp01(parseFloat(p) / 100) * max;
      return parseFloat(p);
    }
    if (fn === 'rgb' || fn === 'rgba') {
      var r = num(parts[0], 255), g = num(parts[1], 255), b = num(parts[2], 255);
      var a = parts[3] != null ? num(parts[3], 1) : 1;
      if (r == null || g == null || b == null) return null;
      return { red: clamp01(r / 255), green: clamp01(g / 255), blue: clamp01(b / 255), alpha: clamp01(a == null ? 1 : a) };
    }
    // hsl / hsla
    var h = parseFloat(parts[0]);
    var s = parseFloat(parts[1]) / 100;
    var l = parseFloat(parts[2]) / 100;
    var ha = parts[3] != null ? num(parts[3], 1) : 1;
    if (isNaN(h) || isNaN(s) || isNaN(l)) return null;
    var rgb = hslToRgb(((h % 360) + 360) % 360, clamp01(s), clamp01(l));
    return { red: rgb[0], green: rgb[1], blue: rgb[2], alpha: clamp01(ha == null ? 1 : ha) };
  }

  function hslToRgb(h, s, l) {
    var c = (1 - Math.abs(2 * l - 1)) * s;
    var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    var m = l - c / 2;
    var r = 0, g = 0, b = 0;
    if (h < 60)       { r = c; g = x; }
    else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; }
    else              { r = c; b = x; }
    return [r + m, g + m, b + m];
  }

  function to255(n) { return Math.round(clamp01(n) * 255); }

  function toHex(color) {
    function h2(n) { var s = to255(n).toString(16); return s.length === 1 ? '0' + s : s; }
    var base = '#' + h2(color.red) + h2(color.green) + h2(color.blue);
    if (color.alpha != null && color.alpha < 1) base += h2(color.alpha);
    return base;
  }

  function toRgb(color) {
    var r = to255(color.red), g = to255(color.green), b = to255(color.blue);
    if (color.alpha != null && color.alpha < 1) {
      return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + Math.round(color.alpha * 100) / 100 + ')';
    }
    return 'rgb(' + r + ', ' + g + ', ' + b + ')';
  }

  function provideDocumentColors(model) {
    var colors = [];
    var lineCount = model.getLineCount();
    // Registered for every language and re-run on every change, so a big file
    // pays two regex passes per line for every keystroke. Same threshold
    // EditorPanel's applyLargeFileTuning uses to switch off the other
    // whole-document decorations.
    if (lineCount > 2500) return [];
    for (var ln = 1; ln <= lineCount; ln++) {
      var line = model.getLineContent(ln);
      if (line.length > 2000) continue; // skip pathological lines
      collect(line, ln, HEX_RE, parseHex, colors);
      collect(line, ln, FUNC_RE, parseFunc, colors);
    }
    return colors;
  }

  function collect(line, ln, re, parse, out) {
    re.lastIndex = 0;
    var m;
    while ((m = re.exec(line)) !== null) {
      var color = parse(m[0]);
      if (!color) continue;
      var startCol = m.index + 1;
      var endCol = m.index + m[0].length + 1;
      out.push({
        range: { startLineNumber: ln, startColumn: startCol, endLineNumber: ln, endColumn: endCol },
        color: color
      });
    }
  }

  function provideColorPresentations(model, colorInfo) {
    var color = colorInfo.color;
    var original = model.getValueInRange(colorInfo.range);
    var isFunc = /^(rgb|hsl)/i.test(original);
    var primary = isFunc ? toRgb(color) : toHex(color);
    return [{ label: primary }];
  }

  function register(monaco) {
    if (_registered || !monaco || !monaco.languages) return;
    _registered = true;
    var provider = {
      provideDocumentColors: provideDocumentColors,
      provideColorPresentations: provideColorPresentations
    };
    var skip = { css: true, scss: true, less: true };
    (monaco.languages.getLanguages() || []).forEach(function (lang) {
      if (skip[lang.id]) return;
      try { monaco.languages.registerColorProvider(lang.id, provider); } catch (e) {}
    });
  }

  window.MbeditorColorProvider = { register: register };
})();
