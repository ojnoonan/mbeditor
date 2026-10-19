'use strict';

// Shown when an external import lands on paths that already exist. Offers
// batch-level resolutions only — per-file toggles were left out deliberately
// so the three-way choice stays legible. Escape and click-outside both mean
// skip, which is the non-destructive option.
//
// Errors from the same pass render here too, so a drop that both conflicts
// and fails needs one dialog rather than two.
// Focus containment for a modal: initial focus in, Tab cycles inside, Escape
// dismisses, focus restored on unmount. Shared with ImportDialog — both are
// overlays over an editor that will happily steal focus back otherwise.
window.useModalFocusTrap = function useModalFocusTrap(modalRef, onDismiss) {
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
        onDismiss();
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
  }, [onDismiss]);
};

// Compare is offered only for files that look like text and are small enough
// to diff in a modal. file.type is '' for most source files, so this rules
// out the known-binary families rather than requiring a text/* type.
var COMPARE_MAX_BYTES = 512 * 1024;
function canCompare(file) {
  if (!file || file.size > COMPARE_MAX_BYTES) return false;
  return !/^(image|audio|video|font)\/|^application\/(octet-stream|zip|pdf|gzip|x-)/.test(file.type || '');
}

var ImportConflictModal = function ImportConflictModal(_ref) {
  var conflicts = _ref.conflicts || [];
  var errors = _ref.errors || [];
  var onResolve = _ref.onResolve;
  var modalRef = React.useRef(null);
  var _cmp = React.useState(null);
  var compare = _cmp[0];
  var setCompare = _cmp[1];

  // Incoming file per conflicting target path.
  var incoming = React.useMemo(function () {
    var byPath = {};
    FileImport.conflictedEntries(_ref.entries || [], _ref.targetFolderPath, conflicts).forEach(function (e) {
      byPath[FileImport.joinPath(_ref.targetFolderPath, e.relativePath)] = e.file;
    });
    return byPath;
  }, [_ref.entries, _ref.targetFolderPath, conflicts]);

  // Escape closes an open comparison first; only then does it mean skip.
  var dismiss = React.useCallback(function () {
    if (compare) setCompare(null); else onResolve('skip');
  }, [onResolve, compare]);
  window.useModalFocusTrap(modalRef, dismiss);

  var openCompare = function (path) {
    var file = incoming[path];
    setCompare({ path: path, loading: true });
    Promise.all([FileService.getFile(path), file.text()]).then(function (r) {
      var current = r[0] && r[0].content;
      if (typeof current !== 'string' || r[1].indexOf('\u0000') !== -1) {
        setCompare({ path: path, note: 'Binary or unreadable file, cannot compare.' });
      } else {
        setCompare({ path: path, original: current, modified: r[1] });
      }
    }, function () { setCompare({ path: path, note: 'Could not load the current file.' }); });
  };

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
        className: 'schema-modal import-conflict-modal' + (compare ? ' import-conflict-wide' : ''),
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
          compare ? 'Current (left) vs incoming (right)' : conflicts.length + ' file' + (conflicts.length === 1 ? '' : 's') + ' already exist' +
            (conflicts.length === 1 ? 's' : '')
        )
      ),
      compare && React.createElement(
        'div', { className: 'schema-modal-body import-conflict-compare-body' },
        React.createElement('button', { type: 'button', className: 'import-conflict-btn', onClick: function () { setCompare(null); } }, 'Back'),
        compare.original != null
          ? React.createElement('div', { className: 'import-conflict-diff' },
              React.createElement(window.DiffViewer, {
                path: compare.path, original: compare.original, modified: compare.modified,
                isDark: _ref.isDark, editorPrefs: _ref.editorPrefs
              }))
          : React.createElement('div', { className: 'combined-note' }, compare.note || 'Loading...')
      ),
      !compare && React.createElement(
        'div', { className: 'schema-modal-body' },
        React.createElement(
          'ul', { className: 'import-conflict-list' },
          conflicts.map(function (c) {
            return React.createElement('li', { key: c.path, title: c.path },
              c.path,
              canCompare(incoming[c.path]) && React.createElement('button', {
                type: 'button', className: 'import-conflict-compare',
                onClick: function () { openCompare(c.path); }
              }, 'Compare')
            );
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
