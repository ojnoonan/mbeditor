'use strict';

// Shown when an external import lands on paths that already exist. Offers
// batch-level resolutions only — per-file toggles were left out deliberately
// so the three-way choice stays legible. Escape and click-outside both mean
// skip, which is the non-destructive option.
//
// Errors from the same pass render here too, so a drop that both conflicts
// and fails needs one dialog rather than two.
var ImportConflictModal = function ImportConflictModal(_ref) {
  var conflicts = _ref.conflicts || [];
  var errors = _ref.errors || [];
  var onResolve = _ref.onResolve;
  var modalRef = React.useRef(null);

  React.useEffect(function () {
    var previouslyFocused = document.activeElement;
    var modal = modalRef.current;
    var focusableSelector = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    var initialFocusable = modal && modal.querySelector(focusableSelector);
    if (initialFocusable) initialFocusable.focus();
    else if (modal) modal.focus();

    var onKey = function (e) {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        onResolve('skip');
        return;
      }
      if (e.key !== 'Tab' || !modal) return;

      var focusable = modal.querySelectorAll(focusableSelector);
      if (focusable.length === 0) {
        e.preventDefault();
        modal.focus();
        return;
      }

      var first = focusable[0];
      var last = focusable[focusable.length - 1];
      if (!modal.contains(document.activeElement)) {
        e.preventDefault();
        first.focus();
      } else if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', onKey, true);
    return function () {
      document.removeEventListener('keydown', onKey, true);
      if (previouslyFocused && previouslyFocused.focus && document.contains(previouslyFocused)) {
        previouslyFocused.focus();
      }
    };
  }, [onResolve]);

  var button = function (label, mode, className) {
    return React.createElement(
      'button',
      { className: className, onClick: function () { onResolve(mode); } },
      label
    );
  };

  return React.createElement(
    'div',
    {
      className: 'schema-modal-overlay',
      onClick: function () { onResolve('skip'); }
    },
    React.createElement(
      'div',
      {
        ref: modalRef,
        className: 'schema-modal import-conflict-modal',
        role: 'dialog',
        'aria-modal': 'true',
        'aria-label': 'Resolve import conflicts',
        tabIndex: -1,
        onClick: function (e) { e.stopPropagation(); }
      },
      React.createElement(
        'div', { className: 'schema-modal-header' },
        React.createElement(
          'div', { className: 'schema-modal-title' },
          conflicts.length + ' file' + (conflicts.length === 1 ? '' : 's') + ' already exist' +
            (conflicts.length === 1 ? 's' : '')
        )
      ),
      React.createElement(
        'div', { className: 'schema-modal-body' },
        React.createElement(
          'ul', { className: 'import-conflict-list' },
          conflicts.map(function (c) {
            return React.createElement('li', { key: c.path, title: c.path }, c.path);
          })
        ),
        errors.length > 0 && React.createElement(
          'div', { className: 'import-conflict-errors' },
          React.createElement('div', { className: 'import-conflict-errors-title' },
            errors.length + ' file' + (errors.length === 1 ? '' : 's') + ' could not be imported'),
          React.createElement(
            'ul', { className: 'import-conflict-list' },
            errors.map(function (e) {
              return React.createElement('li', { key: e.path, title: e.path },
                e.path + ' — ' + e.error);
            })
          )
        )
      ),
      React.createElement(
        'div', { className: 'import-conflict-actions' },
        button('Skip', 'skip', 'import-conflict-btn'),
        button('Keep both', 'rename', 'import-conflict-btn'),
        button('Overwrite all', 'overwrite', 'import-conflict-btn import-conflict-btn-danger')
      )
    )
  );
};

// Expose globally for sprockets require
window.ImportConflictModal = ImportConflictModal;
