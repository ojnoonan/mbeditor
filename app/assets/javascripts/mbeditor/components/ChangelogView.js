"use strict";

// ChangelogView — renders the gem's CHANGELOG.md inside a styled editor tab.
// Receives `changelogState` ({ loading, content, error }) from MbeditorApp and
// calls `onLoad` when first mounted so the parent can trigger a fetch.

(function() {
  var _React = React;
  var useEffect = _React.useEffect;

  // ---------------------------------------------------------------------------
  // Lightweight markdown → React elements renderer, tuned for CHANGELOG format.
  // Handles: h1/h2/h3, bullet lists, blank lines, horizontal rules, inline **bold**.
  // ---------------------------------------------------------------------------
  function parseInline(text) {
    // Split on **bold** markers and return a mixed array of strings + bold spans.
    var parts = text.split(/\*\*([^*]+)\*\*/g);
    return parts.map(function(part, i) {
      return i % 2 === 1
        ? React.createElement('strong', { key: i }, part)
        : part;
    });
  }

  function renderMarkdown(markdown) {
    var lines = markdown.split('\n');
    var elements = [];
    var listBuffer = [];
    var key = 0;

    function flushList() {
      if (!listBuffer.length) return;
      elements.push(React.createElement(
        'ul', { key: 'ul' + key++, className: 'changelog-list' },
        listBuffer.slice()
      ));
      listBuffer = [];
    }

    lines.forEach(function(line) {
      // H1
      if (/^# /.test(line)) {
        flushList();
        elements.push(React.createElement('h1', { key: key++, className: 'changelog-h1' }, line.slice(2).trim()));
        return;
      }
      // H2 — version line, e.g. "## [0.7.0] - 2026-05-21"
      if (/^## /.test(line)) {
        flushList();
        var raw = line.slice(3).trim();
        // Parse "[X.Y.Z] - DATE" or "[Unreleased]..." patterns
        var vMatch = raw.match(/^\[([^\]]+)\](?:\s*-\s*(.+))?/);
        if (vMatch) {
          elements.push(React.createElement(
            'div', { key: key++, className: 'changelog-version-row' },
            React.createElement('span', { className: 'changelog-version-badge' }, vMatch[1]),
            vMatch[2] && React.createElement('span', { className: 'changelog-version-date' }, vMatch[2].trim())
          ));
        } else {
          elements.push(React.createElement('div', { key: key++, className: 'changelog-version-row' },
            React.createElement('span', { className: 'changelog-version-badge' }, raw)
          ));
        }
        return;
      }
      // H3 — section name, e.g. "### Added"
      if (/^### /.test(line)) {
        flushList();
        var section = line.slice(4).trim();
        var iconMap = { Added: 'fas fa-plus-circle', Fixed: 'fas fa-wrench', Changed: 'fas fa-exchange-alt', Removed: 'fas fa-minus-circle', Performance: 'fas fa-bolt', Tests: 'fas fa-vial', Security: 'fas fa-shield-alt' };
        var iconClass = iconMap[section] || 'fas fa-tag';
        elements.push(React.createElement(
          'div', { key: key++, className: 'changelog-section changelog-section-' + section.toLowerCase() },
          React.createElement('i', { className: iconClass }),
          ' ',
          section
        ));
        return;
      }
      // Horizontal rule
      if (/^---+$/.test(line.trim())) {
        flushList();
        elements.push(React.createElement('hr', { key: key++, className: 'changelog-rule' }));
        return;
      }
      // Bullet list item
      if (/^- /.test(line)) {
        listBuffer.push(React.createElement('li', { key: key++ }, parseInline(line.slice(2).trim())));
        return;
      }
      // Blank line
      if (line.trim() === '') {
        flushList();
        return;
      }
      // Plain paragraph (links, prose)
      flushList();
      if (/^\[.+\]: /.test(line)) return; // skip reference-style link defs
      elements.push(React.createElement('p', { key: key++, className: 'changelog-p' }, parseInline(line.trim())));
    });

    flushList();
    return elements;
  }

  // ---------------------------------------------------------------------------
  // Component
  // ---------------------------------------------------------------------------
  var ChangelogView = function ChangelogView(props) {
    var changelogState = props.changelogState;
    var onLoad = props.onLoad;

    useEffect(function() {
      if (onLoad) onLoad();
    }, []);

    if (!changelogState || changelogState.loading) {
      return React.createElement(
        'div', { className: 'changelog-loading' },
        React.createElement('i', { className: 'fas fa-spinner fa-spin', style: { marginRight: '8px' } }),
        'Loading changelog…'
      );
    }

    if (changelogState.error) {
      return React.createElement(
        'div', { className: 'changelog-error' },
        React.createElement('i', { className: 'fas fa-exclamation-circle', style: { marginRight: '8px' } }),
        changelogState.error
      );
    }

    var content = changelogState.content || '';

    return React.createElement(
      'div', { className: 'changelog-view' },
      React.createElement(
        'div', { className: 'changelog-body' },
        renderMarkdown(content)
      )
    );
  };

  window.ChangelogView = ChangelogView;
})();
