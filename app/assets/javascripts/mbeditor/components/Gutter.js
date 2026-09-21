'use strict';

// Gutter — the one draggable strip between two cards.
//
// It lives in the gap, never inside the panel it resizes: a grip rendered
// inside a card sits on the card's own background and reads as decoration
// rather than as the seam you can pull. Every gutter in the app is this
// component; the panel next to it owns the resize maths and gets a bare
// mousedown through `onDragStart`.
//
// `onSnap` is the one behaviour Gutter owns itself, because it is the same
// three lines wherever it appears: a gutter with nothing to resize yet (a
// collapsed explorer, a closed drawer) tracks its own drag and fires once on
// mouseup if the pointer travelled far enough in the opening direction —
// right for a vertical gutter, up for a horizontal one, or the reverse with
// `snapDirection: -1` (a panel that opens from the right edge). It is handed the
// distance so a caller can open to the dragged size. In that mode
// `onDragStart` is not called.
var Gutter = function Gutter(props) {
  var vertical = props.orientation === 'vertical';
  var onSnap = props.onSnap;

  var onMouseDown = onSnap ? function (e) {
    e.preventDefault();
    var start = vertical ? e.clientX : e.clientY;
    var threshold = props.snapThreshold == null ? 24 : props.snapThreshold;
    var onMove = function (ev) { ev.preventDefault(); };
    var onUp = function (ev) {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      var dir = props.snapDirection == null ? 1 : props.snapDirection;
      var moved = (vertical ? ev.clientX - start : start - ev.clientY) * dir;
      if (moved >= threshold) onSnap(moved);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  } : props.onDragStart;

  return React.createElement('div', {
    className: 'ide-gutter ide-gutter-' + (vertical ? 'v' : 'h') +
      (props.active ? ' active' : '') +
      (props.className ? ' ' + props.className : ''),
    role: 'separator',
    'aria-orientation': vertical ? 'vertical' : 'horizontal',
    'aria-label': props.label,
    title: props.label,
    onMouseDown: onMouseDown
  });
};

window.Gutter = Gutter;
