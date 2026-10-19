'use strict';

// Paste & Place (Ruby). The user pastes one or more methods (optionally inside
// their `class Foo ... end`); each is matched to the method it should replace,
// or offered as a new method. Nothing is written to disk: Apply pushes undoable
// edits into the live Monaco buffer, which marks the tab dirty.
//
// Line ranges come from POST /ruby_methods (Ripper), computed on the *buffer*
// text, so they match what the editor holds rather than what is on disk.

var PastePlaceModal = (function () {
  var useState = React.useState;
  var useRef = React.useRef;
  var useMemo = React.useMemo;

  var MAX_CANDIDATE_FILES = 10;

  function indentOf(line) { return /^[ \t]*/.exec(line || '')[0]; }

  function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  function activeRubyPath() {
    var st = EditorStore.getState();
    var pane = st.panes.find(function (p) { return p.id === st.focusedPaneId; }) || st.panes[0];
    var tab = pane && pane.tabs.find(function (t) { return t.id === pane.activeTabId; });
    return tab && tab.path && /\.rb$/.test(tab.path) && !/^[a-z-]+:\/\//.test(tab.path) ? tab.path : null;
  }

  // Live buffer when the file is open, disk otherwise.
  function bufferText(path) {
    var entry = window.__mbeditorModels && window.__mbeditorModels[path];
    if (entry && entry.model && !entry.model.isDisposed()) return Promise.resolve(entry.model.getValue());
    return FileService.getFile(path).then(function (d) {
      if (!d || typeof d.content !== 'string') throw new Error('unreadable');
      return d.content;
    });
  }

  function ownerPath(owners, o) {
    return owners.filter(function (x) {
      return x.kind !== 'sclass' && x.start_line <= o.start_line && x.end_line >= o.end_line;
    }).map(function (x) { return x.name; }).join('::');
  }

  function sameMethod(tm, m) {
    return tm.name === m.name && tm.singleton === m.singleton &&
      (!m.owner || tm.owner === m.owner || tm.owner.slice(-(m.owner.length + 2)) === '::' + m.owner);
  }

  // The class/module whose closing `end` receives a new method.
  function insertionOwner(info, snippetOwner) {
    var real = info.owners.filter(function (o) { return o.kind !== 'sclass'; });
    if (snippetOwner) {
      return real.filter(function (o) {
        var full = ownerPath(info.owners, o);
        return full === snippetOwner || full.slice(-(snippetOwner.length + 2)) === '::' + snippetOwner;
      })[0] || null;
    }
    // ponytail: first top-level class/module; an owner-less snippet in a file with none is left unplaced.
    return real.filter(function (o) { return o.kind === 'class'; })[0] || real[0] || null;
  }

  function reindent(snippetLines, base, target) {
    return snippetLines.map(function (l) {
      if (l.trim() === '') return '';
      return target + (l.indexOf(base) === 0 ? l.slice(base.length) : l.replace(/^[ \t]+/, ''));
    });
  }

  // Everything async: parse the snippet, then find targets for every method.
  function findPlacement(code) {
    var cache = {};
    function rangesFor(path) {
      if (!cache[path]) {
        cache[path] = bufferText(path).then(function (text) {
          return FileService.getRubyMethods(text).then(function (info) {
            if (info.error) throw new Error(info.error);
            return { text: text, info: info };
          });
        });
      }
      return cache[path];
    }

    return FileService.getRubyMethods(code).then(function (snip) {
      if (snip.error) throw new Error('Snippet is not valid Ruby: ' + snip.error);
      if (!snip.methods.length) throw new Error('No methods found in the pasted code.');
      var lines = code.split('\n');
      var active = activeRubyPath();

      // One method at a time: /search supersedes (kills) a search still in flight.
      var items = [];
      return snip.methods.reduce(function (chain, m) { return chain.then(function () { return placeOne(m).then(function (item) { items.push(item); }); }); }, Promise.resolve())
        .then(function () { return { items: items, texts: cache }; });

      function placeOne(m) {
        var item = {
          m: m,
          hasDoc: m.doc_start_line < m.start_line,
          lines: lines.slice(m.doc_start_line - 1, m.end_line),
          base: indentOf(lines[m.start_line - 1]),
          options: []
        };
        var existing = [];
        var step = Promise.resolve();
        if (active) {
          step = rangesFor(active).then(function (r) {
            var t = r.info.methods.filter(function (tm) { return sameMethod(tm, m); })[0];
            if (t) existing.push({ path: active, target: t });
          }, function () {});
        }
        return step.then(function () {
          if (existing.length || !m.name) return;
          var q = 'def[[:space:]]+' + (m.singleton ? 'self\\.' : '') + escapeRegex(m.name);
          return axios.get(window.mbeditorBasePath() + '/search', { params: { q: q, regex: 'true', limit: 50 } })
            .then(function (res) {
              var seen = {};
              var files = ((res.data && res.data.results) || []).map(function (r) { return r.file; })
                .filter(function (f) {
                  if (!/\.rb$/.test(f) || f === active || seen[f]) return false;
                  return (seen[f] = true);
                }).slice(0, MAX_CANDIDATE_FILES);
              return Promise.all(files.map(function (f) {
                return rangesFor(f).then(function (r) {
                  var t = r.info.methods.filter(function (tm) { return sameMethod(tm, m); })[0];
                  if (t) existing.push({ path: f, target: t });
                }, function () {});
              }));
            }, function () {});
        }).then(function () {
          item.options = existing.map(function (c) {
            return { kind: 'replace', path: c.path, target: c.target, label: c.path + ':' + c.target.start_line };
          });
          var offerInsert = function (path) {
            return rangesFor(path).then(function (r) {
              var owner = insertionOwner(r.info, m.owner);
              if (owner) item.options.push({ kind: 'insert', path: path, owner: owner, label: 'Insert as new method in ' + path });
              return !!owner;
            }, function () { return false; });
          };
          return (active ? offerInsert(active) : Promise.resolve(false)).then(function (placed) {
            if (placed || !m.owner) return;
            // A new method for a class that lives in another file goes into that file.
            var q = '(class|module)[[:space:]]+' + escapeRegex(m.owner.split('::').pop()) + '([^A-Za-z0-9_]|$)';
            return axios.get(window.mbeditorBasePath() + '/search', { params: { q: q, regex: 'true', limit: 20 } })
              .then(function (res) {
                var files = ((res.data && res.data.results) || []).map(function (r) { return r.file; })
                  .filter(function (f, i, all) { return /\.rb$/.test(f) && f !== active && all.indexOf(f) === i; })
                  .slice(0, MAX_CANDIDATE_FILES);
                return Promise.all(files.map(offerInsert));
              }, function () {});
          });
        }).then(function () {
          item.options.push({ kind: 'skip', label: 'Skip' });
          return item;
        });
      }
    });
  }

  // Edits are expressed in 1-based line numbers against the text they were
  // planned on: replace = lines start..end inclusive, insert = before line `at`.
  function buildEdits(items, choices, texts) {
    var byFile = {};
    items.forEach(function (item, i) {
      var opt = item.options[choices[i] == null ? 0 : choices[i]];
      if (!opt || opt.kind === 'skip') return;
      var entry = texts[opt.path];
      var lines = entry.text.split('\n');
      var f = byFile[opt.path] || (byFile[opt.path] = { text: entry.text, edits: [] });
      if (opt.kind === 'replace') {
        var t = opt.target;
        f.edits.push({
          start: item.hasDoc ? t.doc_start_line : t.start_line, end: t.end_line,
          lines: reindent(item.lines, item.base, indentOf(lines[t.start_line - 1]))
        });
      } else {
        var unit = /^\t/m.test(entry.text) ? '\t' : '  ';
        var at = opt.owner.end_line;
        var indent = indentOf(lines[at - 1]) + unit;
        // Pasted methods are public: landing after `private` would hide a controller action.
        for (var v = opt.owner.start_line; v < opt.owner.end_line - 1; v++) {
          if (/^\s*(private|protected)\s*(#.*)?$/.test(lines[v])) { at = v + 1; indent = indentOf(lines[v]); break; }
        }
        var prev = lines[at - 2];
        var body = reindent(item.lines, item.base, indent);
        if (at !== opt.owner.end_line) body.push('');
        if (at - 1 !== opt.owner.start_line && prev && prev.trim() !== '') body.unshift('');
        f.edits.push({ start: at, end: at - 1, lines: body });
      }
    });
    return byFile;
  }

  function applyToText(text, edits) {
    var lines = text.split('\n');
    edits.slice().sort(function (a, b) { return b.start - a.start; }).forEach(function (e) {
      lines.splice.apply(lines, [e.start - 1, e.end - e.start + 1].concat(e.lines));
    });
    return lines.join('\n');
  }

  function waitForModel(path) {
    var tries = 0;
    return new Promise(function (resolve, reject) {
      (function poll() {
        var e = window.__mbeditorModels && window.__mbeditorModels[path];
        if (e && e.model && !e.model.isDisposed() && e.cleanVersionId != null) return resolve(e.model);
        if (++tries > 100) return reject(new Error('Could not open ' + path));
        setTimeout(poll, 50);
      })();
    });
  }

  function applyEdits(byFile) {
    var paths = Object.keys(byFile);
    paths.forEach(function (p) { TabManager.openTab(p, p.split('/').pop()); });
    return Promise.all(paths.map(waitForModel)).then(function (models) {
      models.forEach(function (model, i) {
        if (model.getValue().replace(/\r\n/g, '\n') !== byFile[paths[i]].text.replace(/\r\n/g, '\n')) {
          throw new Error(paths[i] + ' changed since the preview. Run Find placement again.');
        }
      });
      models.forEach(function (model, i) {
        var eol = model.getEOL();
        var ops = byFile[paths[i]].edits.map(function (e) {
          var range = e.end < e.start
            ? new window.monaco.Range(e.start, 1, e.start, 1)
            : new window.monaco.Range(e.start, 1, e.end, model.getLineMaxColumn(e.end));
          return { range: range, text: e.end < e.start ? e.lines.join(eol) + eol : e.lines.join(eol) };
        });
        model.pushStackElement();
        model.pushEditOperations([], ops, function () { return null; });
        model.pushStackElement();
      });
    });
  }

  var Modal = function PastePlaceModal(props) {
    var modalRef = useRef(null);
    var _c = useState('');
    var code = _c[0]; var setCode = _c[1];
    var _p = useState(null);
    var plan = _p[0]; var setPlan = _p[1];
    var _ch = useState({});
    var choices = _ch[0]; var setChoices = _ch[1];
    var _b = useState(false);
    var busy = _b[0]; var setBusy = _b[1];
    var _e = useState(null);
    var error = _e[0]; var setError = _e[1];

    window.useModalFocusTrap(modalRef, props.onClose);

    var byFile = useMemo(function () {
      return plan ? buildEdits(plan.items, choices, plan.texts) : {};
    }, [plan, choices]);
    var files = Object.keys(byFile);

    var find = function () {
      setBusy(true); setError(null);
      findPlacement(code).then(function (p) {
        // texts holds promises; settle them into { text, info } for synchronous use.
        var paths = Object.keys(p.texts);
        return Promise.all(paths.map(function (k) { return p.texts[k]; })).then(function (vals) {
          var settled = {};
          paths.forEach(function (k, i) { settled[k] = vals[i]; });
          setPlan({ items: p.items, texts: settled });
          setChoices({});
        });
      }).then(function () { setBusy(false); }, function (err) { setBusy(false); setError(err.message || 'Failed'); });
    };

    var apply = function () {
      setBusy(true); setError(null);
      applyEdits(Object.keys(byFile).reduce(function (acc, p) {
        acc[p] = { text: byFile[p].text, edits: byFile[p].edits };
        return acc;
      }, {})).then(function () {
        EditorStore.setStatus('Pasted into ' + files.length + ' file' + (files.length === 1 ? '' : 's') + ' (unsaved)', 'info');
        props.onClose();
      }, function (err) { setBusy(false); setError(err.message || 'Failed'); });
    };

    var h = React.createElement;
    return h('div', { className: 'schema-modal-overlay', onClick: props.onClose },
      h('div', {
        ref: modalRef, className: 'schema-modal paste-place-modal', role: 'dialog', 'aria-modal': 'true',
        'aria-label': 'Paste and place', tabIndex: -1, onClick: function (e) { e.stopPropagation(); }
      },
        h('div', { className: 'schema-modal-header' }, h('div', { className: 'schema-modal-title' }, 'Paste & Place')),
        h('div', { className: 'schema-modal-body paste-place-body' },
          !plan && h('textarea', {
            className: 'paste-place-input', value: code, spellCheck: false, rows: 14,
            placeholder: 'Paste Ruby methods here, or a class/module that wraps them.',
            onChange: function (e) { setCode(e.target.value); }
          }),
          error && h('div', { className: 'paste-place-error' }, error),
          plan && plan.items.map(function (item, i) {
            return h('div', { key: i, className: 'paste-place-row' },
              h('span', { className: 'paste-place-name' }, (item.m.owner ? item.m.owner : '') + (item.m.singleton ? '.' : '#') + item.m.name),
              h('select', {
                value: choices[i] == null ? 0 : choices[i],
                onChange: function (e) { var v = +e.target.value; setChoices(function (prev) { var o = Object.assign({}, prev); o[i] = v; return o; }); }
              }, item.options.map(function (o, k) { return h('option', { key: k, value: k }, o.label); }))
            );
          }),
          plan && files.map(function (p) {
            return h('div', { key: p, className: 'paste-place-diff' },
              h(window.DiffViewer, {
                path: p, original: byFile[p].text, modified: applyToText(byFile[p].text, byFile[p].edits),
                isDark: props.isDark, editorPrefs: props.editorPrefs
              }));
          }),
          plan && files.length === 0 && h('div', { className: 'combined-note' }, 'Nothing to apply.')
        ),
        h('div', { className: 'import-conflict-actions' },
          h('button', { type: 'button', className: 'import-conflict-btn', onClick: plan ? function () { setPlan(null); setError(null); } : props.onClose }, plan ? 'Back' : 'Cancel'),
          plan
            ? h('button', { type: 'button', className: 'import-conflict-btn import-conflict-btn-primary', disabled: busy || files.length === 0, onClick: apply }, 'Apply to editor')
            : h('button', { type: 'button', className: 'import-conflict-btn import-conflict-btn-primary', disabled: busy || !code.trim(), onClick: find }, busy ? 'Searching...' : 'Find placement')
        )
      )
    );
  };

  return Modal;
})();

window.PastePlaceModal = PastePlaceModal;
