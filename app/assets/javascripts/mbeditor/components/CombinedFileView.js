"use strict";

// CombinedFileView — read-only stack of several files on one scrolling page.
// `paths` are workspace-relative file paths (already capped by the caller);
// `total` is the pre-cap count so truncation is shown, never silent.

(function() {
  var useEffect = React.useEffect;
  var useState = React.useState;
  var CONCURRENCY = 6;

  function languageFor(path) {
    if (!(window.monaco && monaco.editor && monaco.editor.colorize)) return null;
    var m = /\.[^./]+$/.exec(path);
    if (!m) return null;
    var ext = m[0].toLowerCase();
    var lang = monaco.languages.getLanguages().find(function (l) { return (l.extensions || []).indexOf(ext) !== -1; });
    return lang ? lang.id : null;
  }

  function download(path) {
    var link = document.createElement('a');
    link.href = window.mbeditorBasePath() + '/raw?download=1&path=' + encodeURIComponent(path);
    link.download = path.split('/').pop();
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    EditorStore.setStatus('Downloading ' + link.download + '...', 'info');
  }

  function copy(path, entry) {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(entry.content).then(
      function () { EditorStore.setStatus('Copied ' + path, 'info'); },
      function () { EditorStore.setStatus('Could not copy ' + path, 'error'); }
    );
  }

  var CombinedFileView = function CombinedFileView(props) {
    var paths = props.paths;
    var _s = useState({});
    var files = _s[0];
    var setFiles = _s[1];

    useEffect(function () {
      var cancelled = false;
      var next = 0;
      function put(path, entry) {
        if (!cancelled) setFiles(function (prev) { var o = Object.assign({}, prev); o[path] = entry; return o; });
      }
      function worker() {
        if (cancelled || next >= paths.length) return Promise.resolve();
        var path = paths[next++];
        return FileService.getFile(path).then(function (data) {
          if (data && data.image) { put(path, { note: 'Image file, not shown' }); return; }
          if (!data || typeof data.content !== 'string') { put(path, { note: 'Binary or unreadable file, not shown' }); return; }
          var lang = languageFor(path);
          if (!lang) { put(path, { content: data.content }); return; }
          return monaco.editor.colorize(data.content, lang, { tabSize: 2 }).then(
            function (html) { put(path, { content: data.content, html: html }); },
            function () { put(path, { content: data.content }); }
          );
        })['catch'](function () { put(path, { note: 'Could not load file' }); }).then(worker);
      }
      for (var i = 0; i < CONCURRENCY; i++) worker();
      return function () { cancelled = true; };
    }, [paths]);

    return React.createElement('div', { className: 'combined-view' },
      props.total > paths.length && React.createElement('div', { className: 'combined-note' },
        'Showing the first ' + paths.length + ' of ' + props.total + ' files.'),
      paths.map(function (path) {
        var e = files[path];
        return React.createElement('section', { key: path, className: 'combined-file' },
          React.createElement('div', { className: 'combined-file-header' },
            React.createElement('span', { className: 'combined-file-path' }, path),
            React.createElement('button', { type: 'button', className: 'combined-file-btn', disabled: !e || e.content == null, onClick: function () { copy(path, e); } }, 'Copy'),
            React.createElement('button', { type: 'button', className: 'combined-file-btn', onClick: function () { download(path); } }, 'Download')
          ),
          !e ? React.createElement('div', { className: 'combined-note' }, 'Loading...') :
            e.note ? React.createElement('div', { className: 'combined-note' }, e.note) :
            e.html ? React.createElement('pre', { className: 'combined-file-body', dangerouslySetInnerHTML: { __html: e.html } }) :
            React.createElement('pre', { className: 'combined-file-body' }, e.content)
        );
      })
    );
  };

  window.CombinedFileView = CombinedFileView;
})();
