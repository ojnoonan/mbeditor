'use strict';

// Popover — the one shell for menus, dropdowns and hovercards. Renders an
// element with the popover attribute and shows it on mount, so it paints in
// the top layer: above Monaco's widgets and every z-index, and positioned
// against the viewport even inside an ancestor with backdrop-filter or a
// transform (the glass chrome's centre column is one; it used to shove a
// position:fixed menu ~130px off its button).
//
// Mount = open, unmount = close, as with ModalDialog: the parent's state is
// the source of truth and the browser's own closes are routed to onDismiss.
//
//   mode 'auto'   (default) — light dismiss: an outside click or Esc closes
//                 it, and opening one auto popover closes the others. For
//                 menus. Replaces full-screen click-catcher divs and document
//                 mousedown listeners.
//   mode 'manual' — no light dismiss; the parent closes it. For hover-driven
//                 surfaces that only need the top layer.
//
// Positioning stays with the caller (style.top/left/right, fixed to the
// viewport). Props: mode, className, style, onDismiss, source (the element
// that opened it: becomes its invoker, so clicking it does not light-dismiss
// and its own click handler can toggle), popoverRef (object ref to the
// element), and any other DOM props (onMouseEnter, role, ...), passed through.
var POPOVER_OWN_PROPS = { mode: 1, onDismiss: 1, source: 1, popoverRef: 1, children: 1 };

var Popover = function Popover(props) {
  var elRef = React.useRef(null);
  var dismissRef = React.useRef(null);
  dismissRef.current = props.onDismiss || null;
  var sourceRef = React.useRef(null);
  sourceRef.current = props.source || null;

  var setRef = function (el) {
    elRef.current = el;
    if (props.popoverRef) props.popoverRef.current = el;
  };

  React.useLayoutEffect(function () {
    var el = elRef.current;
    if (!el || typeof el.showPopover !== 'function') return undefined; // no API: renders as a plain fixed element
    var unmounting = false;
    var lastDown = null;

    try {
      el.showPopover(sourceRef.current ? { source: sourceRef.current } : undefined);
    } catch (e) {
      return undefined; // already open, or detached — nothing to manage
    }

    // Where `source` is unsupported, pressing the invoker light-dismisses the
    // popover before the invoker's own click handler runs, and that handler
    // would read "closed" and reopen it. Leave that close to the handler: it
    // toggles state off, which unmounts this. The deferred check below covers
    // a handler that does not.
    var onPointerDown = function (e) { lastDown = { target: e.target, at: Date.now() }; };
    var onBeforeToggle = function (e) {
      if (unmounting || e.newState !== 'closed') return;
      var src = sourceRef.current;
      if (src && lastDown && Date.now() - lastDown.at < 500 && src.contains(lastDown.target)) {
        setTimeout(function () {
          if (!unmounting && !el.matches(':popover-open') && dismissRef.current) dismissRef.current();
        }, 250);
        return;
      }
      if (dismissRef.current) dismissRef.current();
    };

    document.addEventListener('pointerdown', onPointerDown, true);
    el.addEventListener('beforetoggle', onBeforeToggle);
    return function () {
      unmounting = true;
      document.removeEventListener('pointerdown', onPointerDown, true);
      el.removeEventListener('beforetoggle', onBeforeToggle);
      // React removes the node next; removing a showing popover hides it
      // without firing toggle events, so nothing else is needed here.
    };
  }, []);

  var domProps = { ref: setRef, popover: props.mode || 'auto' };
  Object.keys(props).forEach(function (k) {
    if (!POPOVER_OWN_PROPS[k]) domProps[k] = props[k];
  });
  domProps.className = 'mb-popover' + (props.className ? ' ' + props.className : '');
  return React.createElement('div', domProps, props.children);
};

window.Popover = Popover;
