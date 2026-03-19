'use strict';

// ShortcutHelp — isolated module.
// Renders a centred overlay listing all keyboard shortcuts and usage tips.
// Dismissable with the × button, clicking the backdrop, or Escape.
// Mount/unmount is controlled entirely by the parent (showHelp state).

var ShortcutHelp = function ShortcutHelp(_ref) {
  var onClose = _ref.onClose;

  var _React = React;
  var useEffect = _React.useEffect;

  useEffect(function () {
    function onKeyDown(e) {
      if (e.key === 'Escape') onClose();
    }
    window.addEventListener('keydown', onKeyDown);
    return function () { window.removeEventListener('keydown', onKeyDown); };
  }, [onClose]);

  function Section(props) {
    return React.createElement(
      'div',
      { className: 'shelp-section' },
      React.createElement('h3', { className: 'shelp-section-title' }, props.title),
      props.children
    );
  }

  function Row(props) {
    return React.createElement(
      'tr',
      null,
      React.createElement(
        'td',
        { className: 'shelp-key' },
        React.createElement('kbd', null, props.keys)
      ),
      React.createElement('td', { className: 'shelp-desc' }, props.desc)
    );
  }

  function Tips(props) {
    return React.createElement(
      'ul',
      { className: 'shelp-tips' },
      props.items.map(function (item, i) {
        return React.createElement('li', { key: i }, item);
      })
    );
  }

  return React.createElement(
    'div',
    { className: 'shelp-backdrop', onClick: onClose },
    React.createElement(
      'div',
      {
        className: 'shelp-panel',
        onClick: function (e) { e.stopPropagation(); },
        role: 'dialog',
        'aria-modal': 'true',
        'aria-label': 'Keyboard shortcuts and help'
      },
      React.createElement(
        'div',
        { className: 'shelp-header' },
        React.createElement(
          'span',
          { className: 'shelp-title' },
          React.createElement('i', { className: 'fas fa-keyboard', style: { marginRight: '8px' } }),
          'Keyboard Shortcuts & Help'
        ),
        React.createElement(
          'button',
          { className: 'shelp-close', onClick: onClose, 'aria-label': 'Close help' },
          React.createElement('i', { className: 'fas fa-times' })
        )
      ),

      React.createElement(
        'div',
        { className: 'shelp-body' },

        React.createElement(
          'div',
          { className: 'shelp-columns' },

          // Left column
          React.createElement(
            'div',
            { className: 'shelp-col' },

            React.createElement(
              Section,
              { title: 'File navigation' },
              React.createElement(
                'table',
                { className: 'shelp-table' },
                React.createElement(
                  'tbody',
                  null,
                  React.createElement(Row, { keys: 'Ctrl+P', desc: 'Quick-open any file by name' }),
                  React.createElement(Row, { keys: 'Ctrl+S', desc: 'Save the active file' }),
                  React.createElement(Row, { keys: 'Escape', desc: 'Close quick-open / context menus' })
                )
              )
            ),

            React.createElement(
              Section,
              { title: 'Editor actions' },
              React.createElement(
                'table',
                { className: 'shelp-table' },
                React.createElement(
                  'tbody',
                  null,
                  React.createElement(Row, { keys: 'Ctrl+Z', desc: 'Undo' }),
                  React.createElement(Row, { keys: 'Ctrl+Y', desc: 'Redo' }),
                  React.createElement(Row, { keys: 'Ctrl+/', desc: 'Toggle line comment' }),
                  React.createElement(Row, { keys: 'Ctrl+D', desc: 'Select next occurrence' }),
                  React.createElement(Row, { keys: 'Alt+↑/↓', desc: 'Move line up / down' }),
                  React.createElement(Row, { keys: 'Ctrl+Space', desc: 'Trigger autocomplete' })
                )
              )
            )
          ),

          // Right column
          React.createElement(
            'div',
            { className: 'shelp-col' },

            React.createElement(
              Section,
              { title: 'Tabs & panes' },
              React.createElement(
                Tips,
                {
                  items: [
                    'Click a file to open a preview tab',
                    'Double-click to pin the tab permanently',
                    'Drag a tab to the right half to create a split pane',
                    'Use × to close a tab, or middle-click'
                  ]
                }
              )
            ),

            React.createElement(
              Section,
              { title: 'Sidebar panels' },
              React.createElement(
                Tips,
                {
                  items: [
                    'Explorer — browse files; click to open',
                    'Search — full-text search across all project files',
                    'Git (top-right) — branch info, changed and unpushed files'
                  ]
                }
              )
            ),

            React.createElement(
              Section,
              { title: 'File tree' },
              React.createElement(
                Tips,
                {
                  items: [
                    'Right-click a file or folder for rename / delete / new file',
                    'Click a folder to expand or collapse it',
                    'Coloured badges show git status (M modified, A added, D deleted)'
                  ]
                }
              )
            )
          )
        )
      )
    )
  );
};
