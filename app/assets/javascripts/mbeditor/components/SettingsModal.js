'use strict';

// SettingsModal — the editor preferences screen, as a VS Code-style modal.
// Owns the row catalogue (SETTINGS_ROWS) and the row renderer; MbeditorApp only
// mounts it and hands over the prefs pair. Dismissable with ×, the backdrop, or
// Escape.

// Settings rows, in the order they render. `{ header: ... }` entries start a
// section; everything else is a row descriptor consumed by renderSettingsRow.
// Checkbox default: plain `!!value` unless `def: true` (default checked,
// `value !== false`) or `strict: true` (`value === true`, used only where the
// on-state must be exact). Number default: `value || def` unless `nullish: true`
// (`value != null ? value : def`, needed so 0 is a valid stored value).
var SETTINGS_ROWS = [
  { header: 'Appearance' },
  { key: 'theme', type: 'select', label: 'Theme', title: 'Color theme for the editor', def: 'vs-dark', options: [
    ['vs-dark', 'Dark'], ['vs', 'Light'], ['hc-black', 'HC Dark'], ['hc-light', 'HC Light'],
    ['dracula', 'Dracula'], ['night-owl', 'Night Owl'], ['monokai', 'Monokai'], ['nord', 'Nord'],
    ['github-dark', 'GitHub Dark'], ['tomorrow-night', 'Tomorrow Night'], ['github-light', 'GitHub Light']
  ] },
  { key: 'glass', type: 'checkbox', label: 'Liquid Glass chrome', title: 'Translucent, blurred panels layered over the current theme. Monaco stays solid' },
  { key: 'fontSize', type: 'number', label: 'Font size', title: 'Editor font size in pixels (8–32)', min: 8, max: 32, step: 1, def: 13 },
  { key: 'fontFamily', type: 'text', label: 'Font family', title: 'Font stack used in the editor — the first font available on your system is used', def: "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace" },
  { key: 'lineHeight', type: 'number', label: 'Line height (0=auto)', title: 'Row height in pixels. 0 = auto (roughly font size × 1.5)', min: 0, max: 100, step: 1, def: 0, nullish: true },
  { key: 'letterSpacing', type: 'number', label: 'Letter spacing (px)', title: 'Extra space between characters in pixels. 0 = default', min: -5, max: 20, step: 0.5, parse: 'float', def: 0, nullish: true },

  { header: 'Indentation' },
  { key: 'tabSize', type: 'number', label: 'Tab size', title: 'Number of spaces per indentation level (also sets Prettier tab width)', min: 1, max: 8, step: 1, def: 4 },
  { key: 'insertSpaces', type: 'checkbox', label: 'Use spaces', title: 'Insert spaces instead of tab characters when pressing Tab' },

  { header: 'Editor' },
  { key: 'wordWrap', type: 'select', label: 'Word wrap', title: 'How long lines are handled — Off: scroll horizontally, On: wrap at viewport width, Column: wrap at a fixed column', def: 'off', options: [
    ['off', 'Off'], ['on', 'On'], ['wordWrapColumn', 'Column']
  ] },
  { key: 'lineNumbers', type: 'select', label: 'Line numbers', title: 'Show line numbers in the gutter — On, Off, or Relative (useful with Vim mode)', def: 'on', options: [
    ['on', 'On'], ['off', 'Off'], ['relative', 'Relative']
  ] },
  { key: 'renderWhitespace', type: 'select', label: 'Whitespace', title: 'Render whitespace characters visually — None, Selection only, Boundary (leading/trailing), or All', def: 'none', options: [
    ['none', 'None'], ['selection', 'Selection'], ['boundary', 'Boundary'], ['all', 'All']
  ] },
  { key: 'minimap', type: 'checkbox', label: 'Minimap', title: 'Show a scaled-down overview of the file on the right edge of the editor' },
  { key: 'scrollBeyondLastLine', type: 'checkbox', label: 'Scroll past end', title: 'Allow scrolling past the last line so it can be positioned at the top of the viewport' },
  { key: 'bracketPairColorization', type: 'checkbox', label: 'Bracket colors', title: 'Colorize matching bracket pairs with distinct colors to make nesting easier to read' },
  { key: 'vimMode', type: 'checkbox', label: 'Vim mode', title: 'Enable Vim keybindings (Normal/Insert/Visual modes). Press Escape to return to Normal mode.' },
  { key: 'autoClosingBrackets', type: 'select', label: 'Auto-close brackets', title: 'When to insert a matching closing bracket automatically', def: 'always', options: [
    ['always', 'Always'], ['languageDefined', 'Per language rules'], ['beforeWhitespace', 'Only before whitespace'], ['never', 'Never']
  ] },
  { key: 'autoClosingQuotes', type: 'select', label: 'Auto-close quotes', title: 'When to insert a matching closing quote automatically', def: 'always', options: [
    ['always', 'Always'], ['languageDefined', 'Per language rules'], ['beforeWhitespace', 'Only before whitespace'], ['never', 'Never']
  ] },
  { key: 'renderLineHighlight', type: 'select', label: 'Line highlight', title: 'What to highlight on the current editor line', def: 'none', options: [
    ['none', 'None'], ['gutter', 'Line number only'], ['line', 'Current line background'], ['all', 'Line number + background']
  ] },
  { key: 'cursorStyle', type: 'select', label: 'Cursor style', title: 'Shape of the text cursor in the editor', def: 'line', options: [
    ['line', 'Line (|)'], ['block', 'Block (filled)'], ['underline', 'Underline (_)'],
    ['line-thin', 'Line thin'], ['block-outline', 'Block outline'], ['underline-thin', 'Underline thin']
  ] },
  { key: 'cursorBlinking', type: 'select', label: 'Cursor blinking', title: 'Cursor animation style — Blink (on/off), Smooth (fade), Phase (offset fade), Expand (grow), or Solid (no animation)', def: 'blink', options: [
    ['blink', 'Blink (on/off)'], ['smooth', 'Smooth (fade)'], ['phase', 'Phase (offset fade)'],
    ['expand', 'Expand (grow/shrink)'], ['solid', 'Solid (no blink)']
  ] },
  { key: 'folding', type: 'checkbox', label: 'Code folding', title: 'Show collapse arrows next to foldable regions (functions, classes, blocks)', def: true },
  { key: 'smoothScrolling', type: 'checkbox', label: 'Smooth scrolling', title: 'Animate scrolling instead of jumping instantly' },
  { key: 'mouseWheelZoom', type: 'checkbox', label: 'Ctrl+scroll to zoom', title: 'Hold Ctrl (or Cmd) and scroll the mouse wheel to zoom the font size' },

  { header: 'Behaviour' },
  { key: 'autoIndent', type: 'select', label: 'Auto indent', title: 'How aggressively the editor re-indents lines as you type', def: 'full', options: [
    ['none', 'None (disabled)'], ['keep', 'Keep current level'], ['brackets', 'Indent on { and ['],
    ['advanced', 'Language indent rules'], ['full', 'Full (language grammar)']
  ] },
  { key: 'acceptSuggestionOnEnter', type: 'select', label: 'Accept suggestion on Enter', title: 'Whether pressing Enter accepts the highlighted autocomplete suggestion', def: 'on', options: [
    ['on', 'Always'], ['smart', 'Only when navigated (↑↓)'], ['off', 'Never (Tab only)']
  ] },
  { key: 'wordBasedSuggestions', type: 'select', label: 'Word-based suggestions', title: 'Suggest completions based on words already present in open files', def: 'matchingDocuments', options: [
    ['off', 'Off'], ['currentDocument', 'Current file only'], ['matchingDocuments', 'Same language files'], ['allDocuments', 'All open files']
  ] },
  { key: 'formatOnType', type: 'checkbox', label: 'Format on type', title: 'Re-indent and auto-close blocks as you type (e.g. after pressing Enter inside {})', strict: true },
  { key: 'formatOnSave', type: 'checkbox', label: 'Format on save', title: 'Format the file before every save — RuboCop -A for Ruby, Prettier for JS/JSX/CSS/HTML/Markdown', strict: true },
  { key: 'quickSuggestions', type: 'checkbox', label: 'Quick suggestions', title: 'Show autocomplete suggestions while typing (not just on trigger characters like .)', def: true },

  { header: 'Formatting' },
  { key: 'prettierPrintWidth', type: 'number', label: 'Print width', title: 'Prettier: maximum line length before wrapping (40–200)', min: 40, max: 200, step: 1, def: 80, nullish: true },
  { key: 'prettierTrailingComma', type: 'select', label: 'Trailing commas', title: 'Prettier: add trailing commas in multi-line expressions — All (ES2017+), ES5 (objects/arrays only), or None', def: 'all', options: [
    ['all', 'All'], ['es5', 'ES5'], ['none', 'None']
  ] },
  { key: 'prettierSemi', type: 'checkbox', label: 'Semicolons', title: 'Prettier: add semicolons at the end of statements', def: true },
  { key: 'prettierSingleQuote', type: 'checkbox', label: 'Single quotes', title: 'Prettier: use single quotes instead of double quotes for strings' },
  { key: 'prettierBracketSpacing', type: 'checkbox', label: 'Bracket spacing', title: 'Prettier: add spaces inside object literal braces, e.g. { a: 1 } vs {a: 1}', def: true },

  { header: 'Interface' },
  { key: 'autoRevealInExplorer', type: 'checkbox', label: 'Explorer follows active file', title: 'Automatically scroll the file explorer to reveal and highlight the file you are editing' },
  { key: 'fileTreeTypeahead', type: 'checkbox', label: 'Explorer type-ahead', title: 'Jump to a file in the explorer by typing its name when the sidebar is focused', def: true },
  { key: 'showDotFiles', type: 'checkbox', label: 'Show dotfiles', title: 'Show hidden files and directories (those starting with a dot, e.g. .env, .gitignore) in the file explorer' },
  { key: 'tabDisplayMode', type: 'select', label: 'Tab bar layout', title: 'Scroll: tabs overflow horizontally with a scrollbar; Wrap: tabs flow onto multiple rows', def: 'scroll', options: [
    ['scroll', 'Scroll'], ['wrap', 'Wrap (multi-row)']
  ] },
  { key: 'quickOpenShowFolders', type: 'checkbox', label: 'Quick Open: show folders', title: 'Include folder names in the Quick Open picker (Ctrl+P / Cmd+P) results, not just files' },
  // The stored preference, not the derived value: at a narrow width labels are
  // dropped regardless, and the box must not appear to do nothing.
  { key: 'toolbarLabels', type: 'checkbox', label: 'Toolbar: show labels', title: 'Show a text label beside each toolbar icon. Every button already names itself on hover' },
  { key: 'persistFindState', type: 'checkbox', label: 'Persist find state across files', title: 'Keep the search/replace text when switching between files in the editor', def: true },
  { key: 'branchStateRestore', type: 'checkbox', label: 'Restore tabs on branch switch', title: 'Save which files are open per branch and restore them when switching branches. Disable to always start with a clean slate when switching.', def: true },
  { key: 'routeHints', type: 'checkbox', label: 'Controller route hints', title: 'Show the verb and path that route to each controller action after its def line, and mark public actions nothing routes to', def: true },

  { header: 'RuboCop' },
  { key: 'rubocopLintEnabled', type: 'checkbox', label: 'Enable RuboCop linting', title: 'Run RuboCop in the background and show lint warnings/errors as markers in the editor gutter', def: true }
];

function setEditorPref(setEditorPrefs, key, value) {
  setEditorPrefs(function(p) {
    var next = Object.assign({}, p);
    next[key] = value;
    return next;
  });
}

// Label + description line, then the control. The checkbox is the exception:
// it sits inline before the label, with the description under both.
function settingsRowText(desc) {
  return [
    React.createElement('span', { className: 'ide-settings-label', key: 'l' }, desc.label),
    desc.title ? React.createElement('span', { className: 'ide-settings-desc', key: 'd' }, desc.title) : null
  ];
}

function renderSettingsRow(desc, editorPrefs, setEditorPrefs) {
  var raw = editorPrefs[desc.key];
  function set(v) { setEditorPref(setEditorPrefs, desc.key, v); }

  if (desc.type === 'checkbox') {
    var checked = desc.strict ? raw === true : (desc.def === true ? raw !== false : !!raw);
    return React.createElement(
      'label', { className: 'ide-settings-row ide-settings-row-check', key: desc.key },
      React.createElement('input', {
        type: 'checkbox',
        className: 'ide-settings-checkbox',
        checked: checked,
        onChange: function(e) { set(e.target.checked); }
      }),
      settingsRowText(desc)
    );
  }

  var control = null;
  if (desc.type === 'select') {
    control = React.createElement(
      'select', {
        className: 'ide-settings-input',
        value: raw || desc.def,
        onChange: function(e) { set(e.target.value); }
      },
      desc.options.map(function(opt) {
        return React.createElement('option', { value: opt[0], key: opt[0] }, opt[1]);
      })
    );
  } else if (desc.type === 'number') {
    var val = desc.nullish ? (raw != null ? raw : desc.def) : (raw || desc.def);
    var parse = function(e) { return desc.parse === 'float' ? parseFloat(e.target.value) : parseInt(e.target.value, 10); };
    control = React.createElement('input', {
      key: String(val),
      type: 'number', min: String(desc.min), max: String(desc.max), step: String(desc.step),
      className: 'ide-settings-input ide-settings-input-number',
      defaultValue: val,
      onChange: function(e) {
        var v = parse(e);
        if (!isNaN(v) && v >= desc.min && v <= desc.max) set(v);
      },
      onBlur: function(e) {
        var v = parse(e);
        if (isNaN(v) || v < desc.min || v > desc.max) e.target.value = String(val);
      }
    });
  } else if (desc.type === 'text') {
    control = React.createElement('input', {
      type: 'text',
      className: 'ide-settings-input ide-settings-input-wide',
      value: raw || desc.def,
      onChange: function(e) { set(e.target.value); }
    });
  } else {
    return null;
  }

  return React.createElement(
    'label', { className: 'ide-settings-row', key: desc.key },
    settingsRowText(desc), control
  );
}

// Flat SETTINGS_ROWS → [{ name, rows }], split on the `{ header }` entries.
function settingsSections(rows) {
  var out = [];
  var cur = null;
  rows.forEach(function(d) {
    if (d.header) { cur = { name: d.header, rows: [] }; out.push(cur); }
    else if (cur) cur.rows.push(d);
  });
  return out;
}

var SETTINGS_SECTIONS = settingsSections(SETTINGS_ROWS);

var SettingsModal = function SettingsModal(props) {
  var _React = React;
  var useState = _React.useState;
  var useEffect = _React.useEffect;
  var useRef = _React.useRef;

  var onClose = props.onClose;
  var editorPrefs = props.editorPrefs;
  var setEditorPrefs = props.setEditorPrefs;

  var _q = useState('');
  var query = _q[0];
  var setQuery = _q[1];

  var sections = SETTINGS_SECTIONS;
  var _as = useState(sections[0] ? sections[0].name : null);
  var activeSection = _as[0];
  var setActiveSection = _as[1];

  var sectionRefs = useRef({});

  useEffect(function() {
    function onKeyDown(e) { if (e.key === 'Escape') onClose(); }
    window.addEventListener('keydown', onKeyDown);
    return function() { window.removeEventListener('keydown', onKeyDown); };
  }, [onClose]);

  var q = query.trim().toLowerCase();
  var visible = sections.map(function(s) {
    if (!q) return s;
    return {
      name: s.name,
      rows: s.rows.filter(function(d) {
        return (d.label || '').toLowerCase().indexOf(q) !== -1 ||
               (d.title || '').toLowerCase().indexOf(q) !== -1;
      })
    };
  }).filter(function(s) { return s.rows.length > 0; });

  return React.createElement(
    'div',
    { className: 'ide-settings-overlay', onClick: onClose },
    React.createElement(
      'div',
      { className: 'ide-settings-modal', onClick: function(e) { e.stopPropagation(); } },
      React.createElement(
        'div', { className: 'ide-settings-modal-header' },
        React.createElement('span', { className: 'ide-settings-modal-title' }, 'Settings'),
        React.createElement('input', {
          type: 'search',
          className: 'ide-settings-search',
          placeholder: 'Search settings',
          autoFocus: true,
          value: query,
          onChange: function(e) { setQuery(e.target.value); }
        }),
        React.createElement('button', {
          type: 'button', className: 'ide-settings-modal-close', title: 'Close', onClick: onClose
        }, '×')
      ),
      React.createElement(
        'div', { className: 'ide-settings-modal-body' },
        React.createElement(
          'nav', { className: 'ide-settings-nav' },
          visible.map(function(s) {
            return React.createElement('button', {
              type: 'button',
              key: s.name,
              className: 'ide-settings-nav-item' + (s.name === activeSection ? ' active' : ''),
              onClick: function() {
                setActiveSection(s.name);
                var el = sectionRefs.current[s.name];
                if (el && el.scrollIntoView) el.scrollIntoView({ block: 'start' });
              }
            }, s.name);
          })
        ),
        React.createElement(
          'div', { className: 'ide-settings-body' },
          visible.map(function(s) {
            return React.createElement(
              'section', { className: 'ide-settings-section', key: s.name,
                ref: function(el) { sectionRefs.current[s.name] = el; } },
              React.createElement('h3', { className: 'ide-settings-section-header' }, s.name),
              s.rows.map(function(d) { return renderSettingsRow(d, editorPrefs, setEditorPrefs); }),
              s.name === 'RuboCop' && props.rubocopAvailable && props.rubocopConfigPath
                ? React.createElement(
                    'div', { className: 'ide-settings-row' },
                    React.createElement('span', { className: 'ide-settings-label' }, 'Config file'),
                    React.createElement(
                      'button', {
                        type: 'button',
                        className: 'ide-settings-config-link',
                        title: 'Open ' + props.rubocopConfigPath,
                        onClick: function() { props.onOpenRubocopConfig(); onClose(); }
                      },
                      React.createElement('i', { className: 'fas fa-file-alt', style: { marginRight: 5 } }),
                      props.rubocopConfigPath
                    )
                  )
                : null
            );
          }),
          visible.length === 0
            ? React.createElement('div', { className: 'ide-settings-empty' }, 'No settings match "' + query + '".')
            : null,
          React.createElement(
            'button', {
              className: 'ide-settings-reset-btn',
              type: 'button',
              title: 'Restore every editor preference on this page to its default',
              onClick: props.onReset
            },
            React.createElement('i', { className: 'fas fa-undo', style: { marginRight: 6 } }),
            'Reset to defaults'
          )
        )
      )
    )
  );
};

window.SettingsModal = SettingsModal;
