'use strict';

// Upload dialog: the pointed-at half of the drag-and-drop import.
//
// Everything past "pick files" is the existing import pipeline — the same
// entries shape, the same /import call, the same ImportConflictModal for
// replace/keep-both/skip. The only thing this adds is *where* the files land,
// which drag-and-drop answers by what you dropped onto and a file picker
// cannot answer at all.
//
// Destination suggestions come from the file tree already in memory
// (SearchService's index), so picking a folder that lives at
// app/assets/javascripts/ux/component offers that prefix rather than dumping
// `ux/component/` at the workspace root. The root stays on offer as the
// "create the structure from scratch" option.
var ImportDialog = function ImportDialog(_ref) {
  var initialFolder = _ref.initialFolder || '';
  var docs = _ref.docs || [];
  var onCancel = _ref.onCancel;
  var onImport = _ref.onImport;

  var modalRef = React.useRef(null);
  var filesInputRef = React.useRef(null);
  var folderInputRef = React.useRef(null);

  var _picked = React.useState(null);
  var picked = _picked[0];
  var setPicked = _picked[1];

  var _dest = React.useState(initialFolder);
  var dest = _dest[0];
  var setDest = _dest[1];

  window.useModalFocusTrap(modalRef, onCancel);

  // webkitdirectory has no JSX/React prop, and React strips unknown lowercase
  // attributes on <input>, so it is set on the DOM node directly.
  React.useEffect(function () {
    var el = folderInputRef.current;
    if (!el) return;
    el.setAttribute('webkitdirectory', '');
    el.setAttribute('directory', '');
  }, []);

  var entries = (picked && picked.entries) || [];

  var suggestions = React.useMemo(function () {
    if (entries.length === 0) return [];
    return FileImport.suggestDestinations(entries, docs);
  }, [picked, docs]);

  var existingFiles = React.useMemo(function () {
    var set = new Set();
    docs.forEach(function (d) { if (d.type === 'file') set.add(d.path); });
    return set;
  }, [docs]);

  var onPick = function (e) {
    var result = FileImport.entriesFromFileList(e.target.files);
    e.target.value = ''; // so picking the same folder twice still fires change
    if (result.entries.length === 0) return;
    setPicked(result);
  };

  var normalisedDest = String(dest || '').trim().replace(/^\/+|\/+$/g, '');

  var destOption = function (prefix, label, hint) {
    var active = normalisedDest === prefix;
    return React.createElement(
      'button',
      {
        key: '$' + prefix,
        type: 'button',
        className: 'import-dest-option' + (active ? ' active' : ''),
        onClick: function () { setDest(prefix); }
      },
      React.createElement('i', { className: (active ? 'fas fa-dot-circle' : 'far fa-circle') + ' import-dest-radio' }),
      React.createElement('span', { className: 'import-dest-label' }, label),
      hint && React.createElement('span', { className: 'import-dest-hint' }, hint)
    );
  };

  var offered = {};
  var options = [];
  var offer = function (prefix, label, hint) {
    if (offered['$' + prefix]) return;
    offered['$' + prefix] = true;
    options.push(destOption(prefix, label, hint));
  };

  if (initialFolder) offer(initialFolder, initialFolder, 'selected folder');
  suggestions.forEach(function (s) {
    var bits = [];
    if (s.files) bits.push(s.files + ' matching file' + (s.files === 1 ? '' : 's'));
    if (s.dirs) bits.push(s.dirs + ' matching folder' + (s.dirs === 1 ? '' : 's'));
    offer(s.prefix, s.prefix, bits.join(', '));
  });
  offer('', 'Workspace root', 'create the folders from the root');

  var targets = entries.map(function (e) {
    return FileImport.joinPath(normalisedDest, e.relativePath);
  });
  var replacing = targets.filter(function (t) { return existingFiles.has(t); }).length;

  return React.createElement(
    'div',
    { className: 'schema-modal-overlay', onClick: onCancel },
    React.createElement(
      'div',
      {
        ref: modalRef,
        className: 'schema-modal import-dialog',
        role: 'dialog',
        'aria-modal': 'true',
        'aria-label': 'Upload files',
        tabIndex: -1,
        onClick: function (e) { e.stopPropagation(); }
      },
      React.createElement(
        'div', { className: 'schema-modal-header' },
        React.createElement('div', { className: 'schema-modal-title' },
          React.createElement('i', { className: 'fas fa-upload', style: { marginRight: '8px', opacity: 0.7 } }),
          'Upload files'),
        React.createElement(
          'button',
          { className: 'schema-modal-close', onClick: onCancel, title: 'Close' },
          React.createElement('i', { className: 'fas fa-times' })
        )
      ),
      React.createElement(
        'div', { className: 'schema-modal-body' },

        React.createElement(
          'div', { className: 'import-pick-row' },
          React.createElement(
            'button',
            { type: 'button', className: 'import-pick-btn',
              onClick: function () { filesInputRef.current && filesInputRef.current.click(); } },
            React.createElement('i', { className: 'far fa-file' }), ' Choose files…'
          ),
          React.createElement(
            'button',
            { type: 'button', className: 'import-pick-btn',
              onClick: function () { folderInputRef.current && folderInputRef.current.click(); } },
            React.createElement('i', { className: 'far fa-folder' }), ' Choose folder…'
          ),
          React.createElement('input', {
            ref: filesInputRef, type: 'file', multiple: true,
            style: { display: 'none' }, onChange: onPick
          }),
          React.createElement('input', {
            ref: folderInputRef, type: 'file', multiple: true,
            style: { display: 'none' }, onChange: onPick
          })
        ),

        entries.length === 0 && React.createElement(
          'div', { className: 'import-dialog-empty' },
          'Pick files or a folder to upload. You can also drag them onto the explorer.'
        ),

        picked && picked.truncated && React.createElement(
          'div', { className: 'import-dialog-warning' },
          'Only the first ' + FileImport.MAX_ENTRIES + ' files will be uploaded.'
        ),

        entries.length > 0 && React.createElement(
          React.Fragment, null,
          React.createElement('div', { className: 'import-dialog-section-title' }, 'Destination'),
          React.createElement('div', { className: 'import-dest-options' }, options),
          React.createElement('input', {
            className: 'import-dest-input',
            type: 'text',
            value: dest,
            placeholder: 'workspace root',
            spellCheck: false,
            autoComplete: 'off',
            'aria-label': 'Destination folder',
            onChange: function (e) { setDest(e.target.value); }
          }),

          React.createElement('div', { className: 'import-dialog-section-title' },
            entries.length + ' file' + (entries.length === 1 ? '' : 's') +
            (replacing > 0 ? ' — ' + replacing + ' will replace an existing file' : '')),
          React.createElement(
            'ul', { className: 'import-conflict-list' },
            targets.map(function (t, i) {
              return React.createElement(
                'li', { key: t + '#' + i, title: t },
                t,
                existingFiles.has(t) && React.createElement(
                  'span', { className: 'import-target-replaces' }, 'replaces')
              );
            })
          )
        )
      ),
      React.createElement(
        'div', { className: 'import-conflict-actions' },
        React.createElement('button', { className: 'import-conflict-btn', onClick: onCancel }, 'Cancel'),
        React.createElement(
          'button',
          {
            className: 'import-conflict-btn import-conflict-btn-primary',
            disabled: entries.length === 0,
            onClick: function () { onImport(entries, normalisedDest, picked); }
          },
          entries.length === 0 ? 'Upload' : 'Upload ' + entries.length + ' file' + (entries.length === 1 ? '' : 's')
        )
      )
    )
  );
};

// Expose globally for sprockets require
window.ImportDialog = ImportDialog;
