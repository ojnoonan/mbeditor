'use strict';

// Outline entries for JS/JSX/TS from TypeScript's own navigation tree.
//
// Monaco's TypeScript worker already parses these files for diagnostics and
// completion, and `getNavigationTree` hands back the symbol tree it built —
// so unlike the Ruby outline there is no lexer here, only a translation of
// that tree into the entry shape the dropdown renders.
//
// The raw tree needs three fixes before it is useful as an outline:
//   • children arrive alphabetised, not in source order
//   • it includes every local, object-literal key and anonymous callback
//   • an arrow function assigned to a variable is labelled 'const', exactly
//     like `const total = 5`
var JsOutline = (function () {
  var MAX_ENTRIES = 5000;

  var CONTAINER_KINDS = {
    'class': true, 'local class': true, 'interface': true,
    'enum': true, 'module': true, 'type': true
  };
  var CALLABLE_KINDS = {
    'function': true, 'local function': true, 'method': true,
    'constructor': true, 'getter': true, 'setter': true
  };
  var VARIABLE_KINDS = { 'const': true, 'let': true, 'var': true };

  // `= function`, `= async () =>`, `= x =>`, `= async function*`. Anchored on
  // the assignment so a call like `const rows = build(() => 1)` stays out.
  var FUNCTION_INITIALIZER =
    /=\s*(?:async\s+)?(?:function\b|\(\s*[^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)/;

  // TypeScript names anonymous callbacks after their caller: "then() callback",
  // "React.useEffect() callback". They have no nameSpan, and neither does
  // `export default Foo`. A constructor has no nameSpan either but is worth
  // listing, so it is admitted by kind rather than by name.
  function isAnonymous(item) {
    return !item.nameSpan && item.kind !== 'constructor';
  }

  // 'constructor' is a TypeScript kind and also an Object.prototype key, so a
  // bare `MAP[kind]` lookup answers truthy for it against every map.
  function listed(map, kind) {
    return Object.prototype.hasOwnProperty.call(map, kind);
  }

  function entryKind(item, declarationText) {
    if (listed(CONTAINER_KINDS, item.kind)) return 'suite';
    if (listed(CALLABLE_KINDS, item.kind)) return 'method';
    if (listed(VARIABLE_KINDS, item.kind) && FUNCTION_INITIALIZER.test(declarationText)) return 'method';
    return null;
  }

  function spanStart(item) {
    var span = item && item.spans && item.spans[0];
    return span ? span.start : 0;
  }

  function inSourceOrder(items) {
    return items.slice().sort(function (a, b) { return spanStart(a) - spanStart(b); });
  }

  // ctx.lineAt(offset) -> 1-based line number
  // ctx.textAt(offset, length) -> source text for a span
  function collect(items, depth, ctx, entries) {
    var ordered = inSourceOrder(items || []);

    for (var i = 0; i < ordered.length; i++) {
      var item = ordered[i];
      var span = item.spans && item.spans[0];
      if (!span) continue;

      // Only the declaration's own head is needed to spot an initializer, and
      // a multi-line arrow body can be arbitrarily long.
      var kind = isAnonymous(item) ? null : entryKind(item, ctx.textAt(span.start, Math.min(span.length, 200)));

      // A skipped node still contributes its children — a component assigned
      // to an unrecognised wrapper shouldn't take its methods down with it.
      if (!kind) {
        if (!collect(item.childItems, depth, ctx, entries)) return false;
        continue;
      }

      if (entries.length >= MAX_ENTRIES) return false;
      entries.push({
        line: ctx.lineAt(span.start),
        name: item.text,
        kind: kind,
        depth: depth,
        visibility: null
      });

      if (!collect(item.childItems, depth + 1, ctx, entries)) return false;
    }

    return true;
  }

  // The root is the file itself ('<global>' for a script, the module name for
  // a module), so only its children are outlined.
  function fromNavigationTree(root, ctx) {
    var entries = [];
    var completed = root ? collect(root.childItems, 0, ctx, entries) : true;
    return { entries: entries, truncated: !completed };
  }

  return { fromNavigationTree: fromNavigationTree, MAX_ENTRIES: MAX_ENTRIES };
})();

window.JsOutline = JsOutline;
