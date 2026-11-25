'use strict';

// PopupMenu — a context menu users can drive from the keyboard. A Popover
// (top layer, light dismiss, Esc) holding a focusgroup of <button> items.
//
//   <PopupMenu label="File actions" onDismiss={close} keyboard={openedByKey}
//              style={{left, top}} className="context-menu">
//     <MenuItem icon="far fa-file" label="New File" onClick={...} />
//     <MenuSeparator />
//   </PopupMenu>
//
// Keys: Up/Down move (wrapping), Home/End jump, Enter/Space activate (native
// button behaviour), Esc closes (the popover), Tab closes. Opened from the
// keyboard (`keyboard`), focus starts on the first item; opened by a pointer,
// focus goes to the menu itself without a ring, so the first ArrowDown enters
// it. Hovering an item focuses it, so hover and focus are one item.
//
// On close, focus returns to whatever had it when the menu opened, unless it
// has already moved somewhere else on purpose (a dialog, an inline rename).
//
// Roles: the browser's focusgroup="menu" infers role=menu/menuitem and does
// the arrow keys. Where it is missing (everything but Chromium 150+), the
// roles are set explicitly and the arrow keys come from onKeyDown below.
// Explicit roles would block the native inference, so they are never set on
// both paths.
var NATIVE_FOCUSGROUP = typeof HTMLElement !== 'undefined' && 'focusGroup' in HTMLElement.prototype;

var enabledMenuItems = function (group) {
  return Array.prototype.filter.call(group.querySelectorAll('button'), function (b) {
    return !b.disabled && b.getAttribute('aria-disabled') !== 'true';
  });
};

var focusQuietly = function (el, visible) {
  try {
    el.focus({ preventScroll: true, focusVisible: !!visible });
  } catch (e) {
    el.focus();
  }
};

var PopupMenu = function PopupMenu(props) {
  var groupRef = React.useRef(null);
  var dismissRef = React.useRef(null);
  dismissRef.current = props.onDismiss || null;
  // Whether the last interaction was a key: decides if restored focus shows a
  // ring. A pointer activation must not leave the opener outlined.
  var keyedRef = React.useRef(!!props.keyboard);

  var dismiss = function () { if (dismissRef.current) dismissRef.current(); };

  // Runs after Popover's own layout effect (children first), so the popover
  // is already showing and its items are focusable.
  React.useLayoutEffect(function () {
    var group = groupRef.current;
    if (!group) return undefined;
    var previous = document.activeElement;

    var first = props.keyboard ? enabledMenuItems(group)[0] : null;
    focusQuietly(first || group, !!first);

    return function () {
      // Cleanup runs before React removes the node. Only take focus back
      // while it is still ours (inside the menu, or dropped on <body>).
      var active = document.activeElement;
      var ours = !active || active === document.body || group.contains(active);
      if (ours && previous && previous !== document.body && previous.isConnected &&
          typeof previous.focus === 'function') {
        focusQuietly(previous, keyedRef.current);
      }
    };
  }, []);

  var onKeyDown = function (e) {
    keyedRef.current = true;
    var key = e.key;
    if (key === 'Tab') {
      e.preventDefault();
      dismiss();
      return;
    }
    var group = groupRef.current;
    var vertical = key === 'ArrowDown' || key === 'ArrowUp';
    // Native focusgroup moves between items; from the menu itself (the
    // pointer-open state) there is no item yet, so the first arrow is ours.
    if (!(key === 'Home' || key === 'End' || (vertical && (!NATIVE_FOCUSGROUP || e.target === group)))) return;
    var items = enabledMenuItems(group);
    if (!items.length) return;
    var n = items.length;
    var cur = items.indexOf(document.activeElement);
    var next;
    if (key === 'Home') next = 0;
    else if (key === 'End') next = n - 1;
    else if (cur < 0) next = key === 'ArrowUp' ? n - 1 : 0;
    else next = (cur + (key === 'ArrowUp' ? -1 : 1) + n) % n;
    e.preventDefault();
    e.stopPropagation();
    focusQuietly(items[next], true);
  };

  var onPointerMove = function (e) {
    if (e.pointerType !== 'mouse') return;
    var item = e.target.closest && e.target.closest('button');
    if (item && item !== document.activeElement && groupRef.current.contains(item) && !item.disabled) {
      focusQuietly(item, false);
    }
  };

  // Focus moved out on its own (a click on something focusable, a script):
  // the menu goes with it rather than staying open behind.
  var onBlur = function (e) {
    var to = e.relatedTarget;
    if (to && groupRef.current && !groupRef.current.contains(to)) dismiss();
  };

  var popoverProps = {};
  Object.keys(props).forEach(function (k) {
    if (k !== 'label' && k !== 'keyboard' && k !== 'children') popoverProps[k] = props[k];
  });

  return React.createElement(
    window.Popover,
    popoverProps,
    React.createElement(
      'div',
      {
        ref: groupRef,
        // Nested inside the popover, not on it: Chromium drops focusgroup's
        // keyboard behaviour on the popover element itself.
        focusgroup: 'menu nomemory',
        role: NATIVE_FOCUSGROUP ? undefined : 'menu',
        'aria-label': props.label,
        tabIndex: -1,
        className: 'context-menu-group',
        onKeyDown: onKeyDown,
        onPointerDown: function () { keyedRef.current = false; },
        onPointerMove: onPointerMove,
        onBlur: onBlur
      },
      props.children
    )
  );
};

var MenuItem = function MenuItem(props) {
  return React.createElement(
    'button',
    {
      type: 'button',
      className: 'context-menu-item' + (props.danger ? ' context-menu-item-danger' : ''),
      role: NATIVE_FOCUSGROUP ? undefined : 'menuitem',
      onClick: props.onClick
    },
    props.icon && React.createElement('i', { className: props.icon + ' context-menu-icon', 'aria-hidden': 'true' }),
    props.label
  );
};

// A real <hr>: a separator to assistive tech, skipped by focusgroup.
var MenuSeparator = function MenuSeparator() {
  return React.createElement('hr', { className: 'context-menu-divider' });
};

window.PopupMenu = PopupMenu;
window.MenuItem = MenuItem;
window.MenuSeparator = MenuSeparator;
