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

  function copyText(text, okMsg, failMsg) {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).then(
      function () { EditorStore.setStatus(okMsg, 'info'); },
      function () { EditorStore.setStatus(failMsg, 'error'); }
    );
  }

  function indentOf(line) { return /^\s*/.exec(line || '')[0]; }

  // The selected methods (indexes into info.methods) with the class/module
  // skeleton that holds them, in source order. Pieces that are not adjacent
  // inside the same owner are separated by a `# ...` line.
  function methodSlice(content, info, picked) {
    var lines = content.split('\n');
    var out = [];
    var open = [];
    var prev = null;
    function contains(o, m) { return o.start_line <= m.start_line && o.end_line >= m.end_line; }
    function close(n) {
      while (open.length > n) { var o = open.pop(); out.push(indentOf(lines[o.start_line - 1]) + 'end'); }
    }
    info.methods.filter(function (m, i) { return picked[i]; })
      .sort(function (a, b) { return a.start_line - b.start_line; })
      .forEach(function (m) {
        var chain = info.owners.filter(function (o) { return contains(o, m); });
        var keep = 0;
        while (keep < open.length && keep < chain.length && open[keep] === chain[keep]) keep++;
        close(keep);
        var reopened = open.length < chain.length;
        for (var k = open.length; k < chain.length; k++) { out.push(lines[chain[k].start_line - 1]); open.push(chain[k]); }
        if (prev && !reopened && m.doc_start_line > prev.end_line + 1) out.push(indentOf(lines[m.start_line - 1]) + '# ...');
        else if (prev && !reopened) out.push('');
        out.push.apply(out, lines.slice(m.doc_start_line - 1, m.end_line));
        prev = m;
      });
    close(0);
    return out.join('\n');
  }

  function fenceFor(text) {
    var f = '```';
    while (text.indexOf(f) !== -1) f += '`';
    return f;
  }

  // paths: ordered file paths; files: path -> loaded entry; info: path -> {methods, owners};
  // picked: path -> {methodIndex: true}; excluded: path -> true. A file with any picked
  // method exports only those. Returns '' when no loaded file is included.
  function buildMarkdown(paths, files, info, picked, excluded) {
    var index = [];
    var parts = [];
    paths.forEach(function (path) {
      var e = files[path];
      if (excluded[path] || !e || e.content == null) return;
      var sel = picked[path] || {};
      var body = e.content;
      var line = '- ' + path;
      if (info[path] && info[path].methods && Object.keys(sel).some(function (k) { return sel[k]; })) {
        body = methodSlice(e.content, info[path], sel);
        line += ' (methods: ' + info[path].methods.filter(function (m, i) { return sel[i]; }).map(function (m) { return m.name; }).join(', ') + ')';
      }
      index.push(line);
      var fence = fenceFor(body);
      var ext = (/\.([^./]+)$/.exec(path) || [])[1] || '';
      var lang = { rb: 'ruby', js: 'javascript', jsx: 'jsx', ts: 'typescript', tsx: 'tsx', yml: 'yaml', md: 'markdown', sh: 'bash' }[ext] || ext;
      parts.push('## ' + path + '\n\n' + fence + lang + '\n' + body.replace(/\n$/, '') + '\n' + fence + '\n');
    });
    return index.length ? '# Files\n' + index.join('\n') + '\n\n' + parts.join('\n') : '';
  }

  function bundleName() {
    return 'mbeditor-bundle-' + new Date().toISOString().replace(/[-:]/g, '').replace(/\..*$/, '').replace('T', '-') + '.md';
  }

  function downloadText(text, filename) {
    var objectUrl = URL.createObjectURL(new Blob([text], { type: 'text/markdown' }));
    var link = document.createElement('a');
    link.href = objectUrl;
    link.download = filename;
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    // Revoking in the same tick can free the blob before the browser has
    // started reading it, which cancels the download instead of saving it.
    setTimeout(function () { URL.revokeObjectURL(objectUrl); }, 60000);
    EditorStore.setStatus('Downloading ' + filename + '...', 'info');
  }

  var CombinedFileView = function CombinedFileView(props) {
    var paths = props.paths;
    var _s = useState({});
    var files = _s[0];
    var setFiles = _s[1];
    var _m = useState({});
    var info = _m[0];
    var setInfo = _m[1];
    var asked = React.useRef({});
    var _p = useState({});
    var picked = _p[0];
    var setPicked = _p[1];

    // Method ranges for Ruby files, fetched once each file has loaded. No
    // cancel-on-rerun: every file load re-runs this, and cancelling would drop
    // the requests still in flight. The view is keyed per tab, so paths never
    // change underneath it.
    useEffect(function () {
      paths.forEach(function (path) {
        if (!/\.rb$/.test(path) || !files[path] || files[path].content == null || asked.current[path]) return;
        asked.current[path] = true;
        FileService.getRubyMethods(files[path].content).then(function (r) {
          setInfo(function (prev) { var o = Object.assign({}, prev); o[path] = r.error ? { error: r.error } : r; return o; });
        }, function () {
          setInfo(function (prev) { var o = Object.assign({}, prev); o[path] = { error: 'Could not read methods' }; return o; });
        });
      });
    }, [paths, files]);

    var _x = useState({});
    var excluded = _x[0];
    var setExcluded = _x[1];

    var toggle = function (path, i) {
      setPicked(function (prev) {
        var o = Object.assign({}, prev);
        var sel = Object.assign({}, o[path] || {});
        if (sel[i]) delete sel[i]; else sel[i] = true;
        o[path] = sel;
        return o;
      });
      setExcluded(function (prev) { var o = Object.assign({}, prev); delete o[path]; return o; });
    };

    var toggleFile = function (path) {
      setExcluded(function (prev) { var o = Object.assign({}, prev); if (o[path]) delete o[path]; else o[path] = true; return o; });
    };

    var exportMd = function (action) {
      var md = buildMarkdown(paths, files, info, picked, excluded);
      if (!md) { EditorStore.setStatus('No files selected', 'info'); return; }
      action(md);
    };

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
      React.createElement('div', { className: 'combined-toolbar' },
        React.createElement('button', { type: 'button', className: 'combined-file-btn', onClick: function () { exportMd(function (md) { copyText(md, 'Copied Markdown bundle', 'Could not copy Markdown bundle'); }); } }, 'Copy .md'),
        React.createElement('button', { type: 'button', className: 'combined-file-btn', onClick: function () { exportMd(function (md) { downloadText(md, bundleName()); }); } }, 'Download .md')
      ),
      React.createElement('div', { className: 'combined-picker' },
        paths.map(function (path) {
          var methods = info[path] && info[path].methods;
          return React.createElement('div', { key: path },
            React.createElement('label', { className: 'combined-pick-file' },
              React.createElement('input', { type: 'checkbox', checked: !excluded[path], onChange: function () { toggleFile(path); } }),
              path),
            methods && methods.map(function (m, i) {
              var label = (m.owner ? m.owner + (m.singleton ? '.' : '#') : (m.singleton ? '.' : '#')) + m.name;
              return React.createElement('label', { key: i, className: 'combined-pick-method', title: 'lines ' + m.start_line + '-' + m.end_line },
                React.createElement('input', { type: 'checkbox', checked: !!(picked[path] && picked[path][i]), onChange: function () { toggle(path, i); } }),
                label);
            })
          );
        })
      ),
      props.total > paths.length && React.createElement('div', { className: 'combined-note' },
        'Showing the first ' + paths.length + ' of ' + props.total + ' files.'),
      paths.map(function (path) {
        var e = files[path];
        return React.createElement('section', { key: path, className: 'combined-file' },
          React.createElement('div', { className: 'combined-file-header' },
            React.createElement('span', { className: 'combined-file-path' }, path)
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
