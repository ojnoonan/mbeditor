"use strict";

// ChangelogView — renders the gem's CHANGELOG.md inside a styled editor tab.
// Receives `changelogState` ({ loading, content, error }) from MbeditorApp and
// calls `onLoad` when first mounted so the parent can trigger a fetch.

(function() {
  var _React = React;
  var useEffect = _React.useEffect;
  var useState = _React.useState;

  var SECTION_ICONS = { Added: 'fas fa-plus-circle', Fixed: 'fas fa-wrench', Changed: 'fas fa-exchange-alt', Removed: 'fas fa-minus-circle', Performance: 'fas fa-bolt', Tests: 'fas fa-vial', Security: 'fas fa-shield-alt' };
  // Shared with EditorPanel.js's markdown preview, which renders untrusted
  // workspace files through the same marked renderer. One definition on
  // purpose: this is the allow-list that keeps `javascript:` out of an href,
  // and a second copy is how one of them silently stops matching the other.
  var SAFE_HREF_SCHEME = /^(https?:|mailto:|#|\/)/i;

  window.mbeditorEscapeHtml = function escapeHtml(str) {
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  };

  window.mbeditorSafeHref = function safeHref(href) {
    if (!href) return href;
    return SAFE_HREF_SCHEME.test(href.trim()) ? href : '#';
  };

  var escapeHtml = window.mbeditorEscapeHtml;
  var safeHref = window.mbeditorSafeHref;

  // Custom marked.Renderer() that layers the changelog's bespoke presentation
  // (version badges on H2, section icons on H3) over marked's own HTML, plus
  // the same link/image href scheme allow-list EditorPanel.js uses. marked's
  // Renderer methods here take positional args (href, title, text) — not the
  // token objects EditorPanel.js's override checks for — so that override is
  // effectively a no-op against the vendored marked build; this one uses the
  // signature marked actually calls.
  function buildRenderer() {
    var renderer = new window.marked.Renderer();

    renderer.heading = function(text, level) {
      if (level === 2) {
        var vMatch = text.match(/^\[([^\]]+)\](?:\s*-\s*(.+))?/);
        var badge = vMatch ? vMatch[1] : text;
        var date = vMatch && vMatch[2] ? vMatch[2].trim() : '';
        return '<div class="changelog-version-row"><span class="changelog-version-badge">' + badge + '</span>' +
          (date ? '<span class="changelog-version-date">' + date + '</span>' : '') + '</div>\n';
      }
      if (level === 3) {
        var iconClass = SECTION_ICONS[text] || 'fas fa-tag';
        return '<div class="changelog-section changelog-section-' + text.toLowerCase() + '"><i class="' + iconClass + '"></i> ' + text + '</div>\n';
      }
      return '<h1 class="changelog-h1">' + text + '</h1>\n';
    };

    renderer.list = function(body, ordered, start) {
      var tag = ordered ? 'ol' : 'ul';
      var cls = ordered ? '' : ' class="changelog-list"';
      return '<' + tag + cls + '>\n' + body + '</' + tag + '>\n';
    };

    renderer.paragraph = function(text) {
      return '<p class="changelog-p">' + text + '</p>\n';
    };

    renderer.hr = function() {
      return '<hr class="changelog-rule">\n';
    };

    renderer.html = function(html) {
      return '<pre>' + escapeHtml(html) + '</pre>';
    };

    var _origLink = renderer.link.bind(renderer);
    var _origImage = renderer.image.bind(renderer);
    renderer.link = function(href, title, text) {
      return _origLink(safeHref(href), title, text);
    };
    renderer.image = function(href, title, text) {
      return _origImage(safeHref(href), title, text);
    };

    return renderer;
  }

  // ---------------------------------------------------------------------------
  // Component
  // ---------------------------------------------------------------------------
  var ChangelogView = function ChangelogView(props) {
    var changelogState = props.changelogState;
    var onLoad = props.onLoad;
    var content = (changelogState && changelogState.content) || '';

    var _markupState = useState('');
    var markup = _markupState[0];
    var setMarkup = _markupState[1];

    useEffect(function() {
      if (onLoad) onLoad();
    }, []);

    useEffect(function() {
      if (!window.marked || !content) {
        setMarkup('');
        return;
      }
      setMarkup(window.marked.parse(content, { renderer: buildRenderer() }));
    }, [content]);

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

    if (!window.marked) {
      return React.createElement(
        'div', { className: 'changelog-view' },
        React.createElement('div', { className: 'changelog-body', style: { whiteSpace: 'pre-wrap' } }, content)
      );
    }

    return React.createElement(
      'div', { className: 'changelog-view' },
      React.createElement('div', { className: 'changelog-body', dangerouslySetInnerHTML: { __html: markup } })
    );
  };

  window.ChangelogView = ChangelogView;
})();
