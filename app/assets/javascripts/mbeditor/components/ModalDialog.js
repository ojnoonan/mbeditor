'use strict';

// ModalDialog — the one modal shell. Renders a native <dialog> opened with
// showModal(), so the browser supplies what each overlay used to rebuild by
// hand, and rebuilt inconsistently: the page behind is inert (Tab cannot
// wander back into Monaco), the dialog paints in the top layer (no z-index
// ladder to keep ahead of), Esc is a close request, and ::backdrop replaces
// the full-screen overlay div.
//
// Mount = open, unmount = close. The parent owns visibility exactly as it did
// with the overlay divs, so React state stays the single source of truth:
// every native close request is cancelled and routed to onDismiss, and the
// parent decides whether that unmounts the dialog (ImportConflictModal uses
// the first Esc to leave its compare view instead). Without onDismiss, Esc
// does nothing — for dialogs that demand an explicit choice.
//
// className styles the panel *inside* the dialog. The <dialog> itself is an
// unstyled shell (.mb-dialog, editor.css) the size of that panel, so existing
// panel CSS carries over unchanged and "outside the dialog box" means
// "outside the panel" for the backdrop click.
//
// Props: className, dialogClassName (backdrop variants), label | labelledBy,
// onDismiss, onBackdrop (defaults to onDismiss; pass null to ignore backdrop
// clicks), panelProps (extra attributes for the panel), children.
//
// Initial focus: put data-autofocus on the control that should get it. React's
// autoFocus runs at commit, before showModal(), while the dialog is still
// closed and unfocusable, so it is silently lost. Without a marker,
// showModal()'s own focusing step picks the first focusable descendant.
var ModalDialog = function ModalDialog(props) {
  var dialogRef = React.useRef(null);
  var dismissRef = React.useRef(null);
  dismissRef.current = props.onDismiss || null;
  var backdropRef = React.useRef(null);
  backdropRef.current = props.onBackdrop !== undefined ? props.onBackdrop : (props.onDismiss || null);

  React.useLayoutEffect(function () {
    var dialog = dialogRef.current;
    if (!dialog) return undefined;
    var previouslyFocused = document.activeElement;
    var unmounting = false;

    if (!dialog.open) dialog.showModal();
    var marked = dialog.querySelector('[data-autofocus]');
    if (marked && marked.focus) marked.focus();

    var dismiss = function () { if (dismissRef.current) dismissRef.current(); };

    var onCancel = function (e) {
      e.preventDefault();
      dismiss();
    };

    // A browser may refuse the cancel (Chrome stops honouring preventDefault
    // on repeated Esc without user activation) and close the dialog itself.
    // If the parent still has it mounted after handling the dismiss, reopen:
    // a closed-but-mounted dialog is an invisible, unreachable modal.
    var onClose = function () {
      if (unmounting) return;
      setTimeout(function () {
        if (!unmounting && dialog.isConnected && !dialog.open) dialog.showModal();
      }, 0);
    };

    // Backdrop click. Tested by pointer position, not event.target: the
    // <dialog> is also the target for gaps between its children. Requiring
    // both press and release outside keeps a text-selection drag that ends on
    // the backdrop from dismissing. (closedby="any" would do this natively,
    // but Safari lacks it and it closes the dialog behind React's back.)
    var outside = function (e) {
      var r = dialog.getBoundingClientRect();
      return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
    };
    var pressedOutside = false;
    var onPointerDown = function (e) { pressedOutside = outside(e); };
    var onPointerUp = function (e) {
      if (pressedOutside && outside(e) && backdropRef.current) backdropRef.current();
      pressedOutside = false;
    };

    dialog.addEventListener('cancel', onCancel);
    dialog.addEventListener('close', onClose);
    dialog.addEventListener('pointerdown', onPointerDown);
    dialog.addEventListener('pointerup', onPointerUp);
    return function () {
      unmounting = true;
      dialog.removeEventListener('cancel', onCancel);
      dialog.removeEventListener('close', onClose);
      dialog.removeEventListener('pointerdown', onPointerDown);
      dialog.removeEventListener('pointerup', onPointerUp);
      // Runs before React removes the node, so close() still gets to return
      // focus to the opener. The fallback covers browsers that don't, and
      // focus left on <body> because the opener has since gone.
      if (dialog.open) dialog.close();
      var active = document.activeElement;
      if ((!active || active === document.body) && previouslyFocused &&
          previouslyFocused.focus && document.contains(previouslyFocused)) {
        previouslyFocused.focus();
      }
    };
  }, []);

  var panelProps = Object.assign({}, props.panelProps || {}, { className: props.className });

  return React.createElement(
    'dialog',
    {
      ref: dialogRef,
      className: 'mb-dialog' + (props.dialogClassName ? ' ' + props.dialogClassName : ''),
      'aria-label': props.labelledBy ? undefined : props.label,
      'aria-labelledby': props.labelledBy
    },
    React.createElement('div', panelProps, props.children)
  );
};

window.ModalDialog = ModalDialog;

// ── MbeditorDialogs: promise-returning confirm()/prompt() ─────────────────
// Replacements for window.confirm/window.prompt, which block the whole page
// (cable heartbeats and polls included), ignore the theme, and cannot put
// focus on the safe button of a destructive question.
//
//   MbeditorDialogs.confirm({ title, message, confirmLabel, danger }) → Promise<boolean>
//   MbeditorDialogs.prompt({ title, message, value, confirmLabel })   → Promise<string|null>
//
// A plain string is accepted as the message. Esc and the backdrop mean
// cancel (false / null). Each call renders into its own React root inside
// #mbeditor-root (so the editor's scoped CSS applies), which is what lets
// non-component modules such as collaboration_identity.js use it.
var ConfirmDialog = function ConfirmDialog(props) {
  var h = React.createElement;
  var _v = React.useState(props.value != null ? String(props.value) : '');
  var value = _v[0];
  var setValue = _v[1];
  var isPrompt = props.kind === 'prompt';
  var cancel = function () { props.onResult(isPrompt ? null : false); };
  var accept = function () { props.onResult(isPrompt ? value : true); };
  var selectedRef = React.useRef(false);

  return h(window.ModalDialog,
    { className: 'schema-modal mb-confirm', label: props.title || props.message, onDismiss: cancel },
    h('form', {
      method: 'dialog',
      onSubmit: function (e) { e.preventDefault(); accept(); }
    },
      props.title && h('div', { className: 'schema-modal-header' },
        h('div', { className: 'schema-modal-title' }, props.title)),
      h('div', { className: 'schema-modal-body' },
        props.message && h('p', { className: 'mb-confirm-message' }, props.message),
        isPrompt && h('input', {
          className: 'import-dest-input', type: 'text', value: value,
          spellCheck: false, autoComplete: 'off', 'data-autofocus': true,
          'aria-label': props.title || props.message,
          onChange: function (e) { setValue(e.target.value); },
          // Select the default once, as window.prompt did, so typing replaces it.
          onFocus: function (e) { if (!selectedRef.current) { selectedRef.current = true; e.target.select(); } }
        })
      ),
      h('div', { className: 'import-conflict-actions' },
        h('button', {
          type: 'button', className: 'import-conflict-btn', onClick: cancel,
          // A destructive question starts on the safe answer.
          'data-autofocus': (!isPrompt && props.danger) || undefined
        }, props.cancelLabel || 'Cancel'),
        h('button', {
          type: 'submit',
          className: 'import-conflict-btn ' + (props.danger ? 'import-conflict-btn-danger' : 'import-conflict-btn-primary'),
          'data-autofocus': (!isPrompt && !props.danger) || undefined
        }, props.confirmLabel || 'OK')
      )
    )
  );
};

window.MbeditorDialogs = (function () {
  function open(kind, opts) {
    if (typeof opts === 'string') opts = { message: opts };
    opts = opts || {};
    return new Promise(function (resolve) {
      var host = document.createElement('div');
      (document.getElementById('mbeditor-root') || document.body).appendChild(host);
      var settled = false;
      var onResult = function (result) {
        if (settled) return;
        settled = true;
        // Unmount before resolving: the dialog's close() hands focus back to
        // the opener, and a caller that moves focus on resolve (opening a
        // tab, say) must get the last word.
        setTimeout(function () {
          ReactDOM.unmountComponentAtNode(host);
          host.remove();
          resolve(result);
        }, 0);
      };
      ReactDOM.render(React.createElement(ConfirmDialog, Object.assign({}, opts, { kind: kind, onResult: onResult })), host);
    });
  }
  return {
    confirm: function (opts) { return open('confirm', opts); },
    prompt: function (opts) { return open('prompt', opts); }
  };
})();
