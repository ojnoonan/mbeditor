'use strict';

// Round trip with a web chat: "Export" downloads the chosen directories as one
// markdown bundle to upload; "Apply diff" checks and applies the unified diff
// the chat replies with. Reuses the schema-modal shell and the import-conflict
// buttons; refreshing open tabs after an apply is left to the files_changed
// broadcast the server sends for the write.
var AI_SELECTION_KEY = 'mbeditor.aiBundle.selection';

// Folders and files: a selection holds folders, plus single files added from
// the related-files search.
function aiKnownPaths(nodes, into) {
  nodes.forEach(function (n) {
    into[n.path] = n.type;
    aiKnownPaths(n.children || [], into);
  });
  return into;
}

// A saved path that has since been deleted would 404 the whole export, so
// saved dirs are checked against the tree (when it has loaded).
function aiLoadSelection(treeData) {
  try {
    var saved = JSON.parse(localStorage.getItem(AI_SELECTION_KEY) || '{}');
    var dirs = Array.isArray(saved.dirs) ? saved.dirs : [];
    if (treeData.length) {
      var known = aiKnownPaths(treeData, {});
      dirs = dirs.filter(function (d) { return known[d]; });
    }
    return { dirs: dirs, topFiles: saved.topFiles === true };
  } catch (e) {
    return { dirs: [], topFiles: false };
  }
}

function aiHumanSize(bytes) {
  return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
}

// A pasted bundle lands entirely in the chat's context; no sandbox sees it.
var AI_PASTE_TOKEN_WARN = 100000;

var AI_COLORIZE_MAX_LINES = 2000;

function aiHeaderClass(text) {
  return /^(---|\+\+\+) /.test(text) ? 'file' : 'meta';
}

function aiBodyClass(c) {
  return c === '+' ? 'add' : c === '-' ? 'del' : c === '\\' ? 'meta' : 'ctx';
}

// One hunk. Plain text nodes first; when Monaco can tokenise the file's
// language the code is swapped for its markup, keeping the +/- line colours.
var AiDiffHunk = function AiDiffHunk(_ref) {
  var h = React.createElement;
  var lines = _ref.text.replace(/\n$/, '').split('\n');
  var body = lines.slice(1);
  var _html = React.useState(null);
  var html = _html[0];
  var setHtml = _html[1];

  React.useEffect(function () {
    setHtml(null);
    var lang = window.MbeditorLanguageForPath && window.MbeditorLanguageForPath(_ref.path);
    if (!lang || body.length > AI_COLORIZE_MAX_LINES) return undefined;
    var cancelled = false;
    var code = body.filter(function (l) { return l[0] !== '\\'; }).map(function (l) { return l.slice(1); });
    try {
      window.monaco.editor.colorize(code.join('\n'), lang, {}).then(function (out) {
        // Non-breaking spaces would leave a wrapped line no break point but before the code.
        var parts = out.replace(/&nbsp;|\u00a0/g, ' ').split('<br/>');
        if (parts.length === code.length + 1 && parts[parts.length - 1] === '') parts.pop();
        if (!cancelled && parts.length === code.length) setHtml(parts);
      }, function () { /* plain text stays */ });
    } catch (e) { /* plain text stays */ }
    return function () { cancelled = true; };
  }, [_ref.text, _ref.path]);

  var n = 0;
  return h('div', { className: _ref.on ? '' : 'ai-diff-off' },
    h('div', { className: 'ai-diff-line ai-diff-hunk ai-hunk-row' }, _ref.checkbox, lines[0]),
    body.map(function (l, i) {
      var colored = html && l[0] !== '\\' ? html[n++] : null;
      return h('div', { key: i, className: 'ai-diff-line ai-diff-' + aiBodyClass(l[0]) },
        h('span', { className: 'ai-diff-prefix' }, l[0] || ' '),
        // colorize returns Monaco's own escaped token markup, built from the
        // diff text but never containing it raw; this is the one place HTML
        // is injected, and nothing else from the patch goes through it.
        colored !== null
          ? h('span', { dangerouslySetInnerHTML: { __html: colored } })
          : l.slice(1));
    }));
};

// Model constants from the tree: app/models/**/*.rb minus concerns, path
// camelized the way the server camelizes the query (admin/user_role.rb ->
// Admin::UserRole).
function aiModelNames(nodes, into) {
  nodes.forEach(function (n) {
    if (n.type === 'file') {
      var m = /^app\/models\/(.+)\.rb$/.exec(n.path || '');
      if (m && m[1].indexOf('concerns/') !== 0) {
        into.push(m[1].split('/').map(function (seg) {
          return seg.split('_').map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1); }).join('');
        }).join('::'));
      }
    } else {
      aiModelNames(n.children || [], into);
    }
  });
  return into;
}

// "Related to...": pick a model from the datalist, get its files as a checklist.
// Direct hits start ticked, one-step-out hits unticked; nothing joins the export
// until "Add selected" hands the ticked paths to onAdd. The fetch fires on its
// own, debounced, only when the text equals a known model (case-insensitive),
// so half-typed names never hit the server's "Enter a model name" error.
var AiRelatedPicker = function AiRelatedPicker(_ref) {
  var h = React.createElement;
  var _q = React.useState('');
  var q = _q[0];
  var setQ = _q[1];
  var _st = React.useState({ busy: false, error: null, result: null, ticks: {}, added: null });
  var st = _st[0];
  var setSt = _st[1];

  var models = React.useMemo(function () { return aiModelNames(_ref.treeData, []).sort(); }, [_ref.treeData]);

  React.useEffect(function () {
    var typed = q.trim().toLowerCase();
    var model = typed && models.filter(function (m) { return m.toLowerCase() === typed; })[0];
    if (!model) {
      if (q) setSt({ busy: false, error: null, result: null, ticks: {}, added: null });
      return undefined;
    }
    var cancelled = false;
    var timer = setTimeout(function () {
      setSt({ busy: true, error: null, result: null, ticks: {}, added: null });
      fetch(window.mbeditorBasePath() + '/related_files?q=' + encodeURIComponent(model)).then(function (r) {
        return r.json().then(function (body) {
          if (!r.ok) throw new Error(body.error || ('HTTP ' + r.status));
          return body;
        });
      }).then(function (body) {
        if (cancelled) return;
        var ticks = {};
        body.files.forEach(function (f) { ticks[f.path] = f.direct; });
        setSt({ busy: false, error: null, result: body, ticks: ticks, added: null });
      }, function (err) {
        if (!cancelled) setSt({ busy: false, error: err.message || 'Request failed', result: null, ticks: {}, added: null });
      });
    }, 300);
    return function () { cancelled = true; clearTimeout(timer); };
  }, [q, models]);

  var ticked = st.result ? st.result.files.filter(function (f) { return st.ticks[f.path]; }) : [];
  var add = function () {
    _ref.onAdd(ticked.map(function (f) { return f.path; }));
    setQ('');
    setSt({ busy: false, error: null, result: null, ticks: {}, added: ticked.length });
  };

  return h('div', { className: 'ai-related' },
    h('div', { className: 'ai-dir-row' },
      h('input', {
        type: 'text', value: q, list: 'ai-related-models', placeholder: 'Related to... (e.g. User)', 'aria-label': 'Related to',
        onChange: function (e) { setQ(e.target.value); }
      }),
      h('datalist', { id: 'ai-related-models' }, models.map(function (m) { return h('option', { key: m, value: m }); }))),
    st.busy && h('div', { className: 'ai-hint' }, 'Finding...'),
    st.error && h('div', { className: 'ai-error' }, st.error),
    st.added !== null && h('div', { className: 'ai-result' }, 'Added ' + st.added + ' file' + (st.added === 1 ? '' : 's') + ' to the export.'),
    st.result && h('div', null,
      h('p', { className: 'ai-hint' }, st.result.files.length ? 'Suggested' : 'Nothing found.'),
      st.result.capped && h('div', { className: 'ai-error' }, 'Many files mention it, so the list of references is cut short.'),
      h('ul', { className: 'ai-dir-list' },
        st.result.files.map(function (f) {
          return h('li', { key: f.path },
            h('label', { title: f.path },
              h('input', {
                type: 'checkbox', checked: !!st.ticks[f.path],
                onChange: function () {
                  var ticks = Object.assign({}, st.ticks);
                  ticks[f.path] = !ticks[f.path];
                  setSt(Object.assign({}, st, { ticks: ticks }));
                }
              }),
              ' ' + f.path + ' ', h('span', { className: 'ai-hint' }, f.reason)));
        })),
      st.result.files.length > 0 && h('button', {
        type: 'button', className: 'import-conflict-btn', disabled: ticked.length === 0, onClick: add
      }, 'Add selected (' + ticked.length + ')')));
};

var AiRoundTripModal = function AiRoundTripModal(_ref) {
  var h = React.createElement;
  var treeData = _ref.treeData || [];
  var onClose = _ref.onClose;

  var _tab = React.useState('export');
  var tab = _tab[0];
  var setTab = _tab[1];

  var initial = React.useMemo(function () { return aiLoadSelection(treeData); }, []);
  var _dirs = React.useState(initial.dirs);
  var dirs = _dirs[0];
  var setDirs = _dirs[1];
  var _top = React.useState(initial.topFiles);
  var topFiles = _top[0];
  var setTopFiles = _top[1];
  var _open = React.useState({});
  var open = _open[0];
  var setOpen = _open[1];
  var _exp = React.useState({ busy: false, error: null, stats: null, pendingCopy: null, notice: null });
  var exp = _exp[0];
  var setExp = _exp[1];

  // The prompt for what Download would produce right now, plus the part count
  // and size the server computed for it. Fetched ahead of the click so
  // writeText can run synchronously and keep the user gesture in Safari.
  var _split = React.useState(false);
  var split = _split[0];
  var setSplit = _split[1];
  var _prompt = React.useState(null);
  var promptInfo = _prompt[0];
  var setPromptInfo = _prompt[1];

  var _patch = React.useState('');
  var patch = _patch[0];
  var setPatch = _patch[1];
  var _apply = React.useState({ busy: false, error: null, files: null, checkedPatch: null, applied: false });
  var apply = _apply[0];
  var setApply = _apply[1];

  var rootFiles = treeData.filter(function (n) { return n.type === 'file'; });
  var knownPaths = React.useMemo(function () { return aiKnownPaths(treeData, {}); }, [treeData]);

  var persist = function (nextDirs, nextTop) {
    try { localStorage.setItem(AI_SELECTION_KEY, JSON.stringify({ dirs: nextDirs, topFiles: nextTop })); } catch (e) { /* storage unavailable */ }
  };
  var toggleDir = function (path) {
    var next = dirs.indexOf(path) === -1 ? dirs.concat(path) : dirs.filter(function (p) { return p !== path; });
    setDirs(next);
    persist(next, topFiles);
  };
  var toggleTop = function () {
    setTopFiles(!topFiles);
    persist(dirs, !topFiles);
  };
  var coveredBy = function (path) {
    return dirs.some(function (d) { return path.indexOf(d + '/') === 0; });
  };

  var addPaths = function (paths) {
    var next = dirs.concat(paths.filter(function (p) { return dirs.indexOf(p) === -1 && !coveredBy(p); }));
    setDirs(next);
    persist(next, topFiles);
  };

  var selectedPaths = dirs.filter(function (d) { return !coveredBy(d); })
    .concat(topFiles ? rootFiles.map(function (f) { return f.path; }) : []);

  var selectionKey = selectedPaths.join('\n') + (split ? '\nsplit' : '');
  var pathsQuery = selectedPaths.map(function (p) { return 'paths[]=' + encodeURIComponent(p); }).join('&') + (split ? '&split=1' : '');

  // Debounced; a response for an older selection is dropped.
  React.useEffect(function () {
    setPromptInfo(null);
    var cancelled = false;
    var timer = setTimeout(function () {
      fetch(window.mbeditorBasePath() + '/ai_bundle?prompt=1&' + pathsQuery).then(function (r) {
        if (r.ok) {
          return r.text().then(function (text) {
            return { text: text, parts: parseInt(r.headers.get('X-Mbeditor-Bundle-Parts'), 10) || 1, bytes: parseInt(r.headers.get('X-Mbeditor-Bundle-Bytes'), 10) || 0 };
          });
        }
        return r.json().catch(function () { return {}; }).then(function (body) {
          return { error: (body && body.error) || ('HTTP ' + r.status) };
        });
      }).then(function (info) {
        if (!cancelled) setPromptInfo(info);
      }, function () {
        if (!cancelled) setPromptInfo({ error: 'Could not check the selection' });
      });
    }, 300);
    return function () { cancelled = true; clearTimeout(timer); };
  }, [selectionKey]);

  var errorMessage = function (err) {
    return (err && err.response && err.response.data && err.response.data.error) || (err && err.message) || 'Request failed';
  };

  var fetchBundle = function () {
    return fetch(window.mbeditorBasePath() + '/ai_bundle?' + pathsQuery).then(function (resp) {
      if (!resp.ok) {
        return resp.json().catch(function () { return {}; }).then(function (body) {
          throw new Error((body && body.error) || ('HTTP ' + resp.status));
        });
      }
      var disposition = resp.headers.get('Content-Disposition');
      var match = disposition && disposition.match(/filename="([^"]+)"/);
      var num = function (name) { return parseInt(resp.headers.get(name), 10) || 0; };
      return resp.blob().then(function (blob) {
        return {
          blob: blob, filename: (match && match[1]) || 'bundle.md',
          stats: {
            files: num('X-Mbeditor-Bundle-Files'), bytes: num('X-Mbeditor-Bundle-Bytes')
          }
        };
      });
    });
  };

  var idle = { busy: false, error: null, stats: null, pendingCopy: null, notice: null };

  var download = function () {
    setExp(Object.assign({}, idle, { busy: true }));
    fetchBundle().then(function (r) {
      var objectUrl = URL.createObjectURL(r.blob);
      var link = document.createElement('a');
      link.href = objectUrl;
      link.download = r.filename;
      link.rel = 'noopener';
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      setTimeout(function () { URL.revokeObjectURL(objectUrl); }, 60000);
      setExp(Object.assign({}, idle, { stats: Object.assign({ filename: r.filename }, r.stats) }));
    }).catch(function (err) {
      setExp(Object.assign({}, idle, { error: err.message || 'network error' }));
    });
  };

  var copied = function (stats) {
    setExp(Object.assign({}, idle, { stats: Object.assign({ filename: 'Copied' }, stats), notice: 'Copied to clipboard.' }));
  };

  var copyFailed = function (err) {
    setExp(Object.assign({}, idle, { error: 'Could not copy: ' + (err && err.message || 'clipboard unavailable') }));
  };

  var writeClipboard = function (text, stats) {
    return navigator.clipboard.writeText(text).then(function () { copied(stats); }, copyFailed);
  };

  // Safari drops the user gesture across an async fetch, so where ClipboardItem
  // exists the write starts synchronously inside the click and is handed a
  // promise for the text. An oversized bundle rejects that promise, so nothing
  // is copied, and the text kept in `big` goes to "Copy anyway", which writes
  // inside its own click.
  var copyBundle = function () {
    setExp(Object.assign({}, idle, { busy: true }));
    var big = null;
    var stats = null;
    var buildError = null;
    var load = fetchBundle().then(function (r) {
      stats = r.stats;
      return r.blob.text().then(function (text) {
        if (r.stats.bytes / 4 > AI_PASTE_TOKEN_WARN) {
          big = text;
          throw new Error('Over ' + AI_PASTE_TOKEN_WARN.toLocaleString() + ' tokens, not copied');
        }
        return text;
      });
    }, function (err) {
      buildError = err;
      throw err;
    });
    var fail = function (err) {
      if (big !== null) setExp(Object.assign({}, idle, { pendingCopy: { text: big, stats: stats } }));
      else if (buildError) setExp(Object.assign({}, idle, { error: 'Could not build bundle: ' + (buildError.message || 'request failed') }));
      else copyFailed(err);
    };
    if (window.ClipboardItem && navigator.clipboard && navigator.clipboard.write) {
      var item = new ClipboardItem({
        'text/plain': load.then(function (text) { return new Blob([text], { type: 'text/plain' }); })
      });
      navigator.clipboard.write([item]).then(function () { copied(stats); }, fail);
    } else {
      load.then(function (text) { return writeClipboard(text, stats); }, fail);
    }
  };

  var copyPrompt = function () {
    navigator.clipboard.writeText(promptInfo.text).then(function () {
      setExp(Object.assign({}, idle, { notice: 'Prompt copied. Fill in the TASK line after pasting.' }));
    }, copyFailed);
  };

  var loadPatchFile = function (e) {
    var file = e.target.files && e.target.files[0];
    e.target.value = '';
    if (!file) return;
    file.text().then(function (text) {
      setPatch(text);
      setApply({ busy: false, error: null, files: null, checkedPatch: null, applied: false });
    });
  };

  var postPatch = function (text, check) {
    return axios.post(window.mbeditorBasePath() + '/apply_patch', { patch: text, check: check });
  };

  var check = function () {
    var text = patch;
    setApply({ busy: true, error: null, files: null, checkedPatch: null, applied: false });
    postPatch(text, true).then(function (resp) {
      var parsed = window.MbeditorPatchSelect.parse(resp.data.patch);
      setApply({
        busy: false, error: null, files: resp.data.files, checkedPatch: text, applied: false,
        diff: resp.data.patch, parsed: parsed, sel: window.MbeditorPatchSelect.defaultSelection(parsed)
      });
    }, function (err) {
      setApply({ busy: false, error: errorMessage(err), files: null, checkedPatch: null, applied: false });
    });
  };

  var dirtyTouched = function () {
    var touched = {};
    window.MbeditorPatchSelect.touchedPaths(apply.parsed, apply.sel, apply.files).forEach(function (p) { touched[p] = true; });
    var names = [];
    EditorStore.getState().panes.forEach(function (p) {
      p.tabs.forEach(function (t) { if (t.dirty && touched[t.path]) names.push(t.path); });
    });
    return names;
  };

  var applyPatch = function () {
    var dirty = dirtyTouched();
    if (dirty.length) {
      setApply(Object.assign({}, apply, { error: 'Save or close these files first, they have unsaved changes: ' + dirty.join(', ') }));
      return;
    }
    setApply(Object.assign({}, apply, { busy: true, error: null }));
    postPatch(window.MbeditorPatchSelect.build(apply.parsed, apply.sel), false).then(function (resp) {
      setApply({ busy: false, error: null, files: resp.data.files, checkedPatch: null, applied: true });
    }, function (err) {
      setApply(Object.assign({}, apply, { busy: false, error: errorMessage(err) }));
    });
  };

  var setSel = function (i, next) {
    var sel = apply.sel.slice();
    sel[i] = next;
    setApply(Object.assign({}, apply, { sel: sel }));
  };

  var renderDir = function (node, covered) {
    var folders = (node.children || []).filter(function (c) { return c.type === 'folder'; });
    var isOpen = open[node.path];
    return h('li', { key: node.path },
      h('div', { className: 'ai-dir-row' },
        h('button', {
          type: 'button', className: 'ai-dir-toggle', disabled: folders.length === 0,
          'aria-label': (isOpen ? 'Collapse ' : 'Expand ') + node.name,
          onClick: function () { var o = Object.assign({}, open); o[node.path] = !isOpen; setOpen(o); }
        }, h('i', { className: 'fas fa-chevron-' + (isOpen ? 'down' : 'right'), style: { opacity: folders.length ? 1 : 0 } })),
        h('label', null,
          h('input', {
            type: 'checkbox', checked: covered || dirs.indexOf(node.path) !== -1, disabled: covered,
            onChange: function () { toggleDir(node.path); }
          }),
          ' ' + node.name)),
      isOpen && folders.length > 0 && h('ul', { className: 'ai-dir-list' },
        folders.map(function (c) { return renderDir(c, covered || dirs.indexOf(node.path) !== -1); })));
  };

  var splits = !!promptInfo && promptInfo.parts > 1;
  var summary = selectedPaths.length === 0 ? 'Nothing selected'
    : !promptInfo ? 'Checking size...'
    : promptInfo.error ? promptInfo.error
    : split && splits ? 'Too big for one file: splits into ' + promptInfo.parts + ' parts, downloaded as one .zip (' + aiHumanSize(promptInfo.bytes) + ')'
    : 'One file, ' + aiHumanSize(promptInfo.bytes);

  var exportPane = h('div', { className: 'ai-pane' },
    h('p', { className: 'ai-hint' }, 'Pick what the assistant should see. Upload the file to the chat, then paste the prompt with it.'),
    h('details', { className: 'ai-prompt' },
      h('summary', null, 'Prompt to paste'),
      h('pre', { className: 'ai-prompt-text' }, promptInfo && promptInfo.text || ''),
      h('button', {
        type: 'button', className: 'import-conflict-btn', disabled: !promptInfo || !promptInfo.text, onClick: copyPrompt
      }, 'Copy')),
    h(AiRelatedPicker, { onAdd: addPaths, treeData: treeData }),
    h('ul', { className: 'ai-dir-list' },
      treeData.filter(function (n) { return n.type === 'folder' && n.name !== '.git'; }).map(function (n) { return renderDir(n, false); }),
      dirs.filter(function (p) { return knownPaths[p] === 'file' && !coveredBy(p); }).map(function (p) {
        return h('li', { key: 'file:' + p },
          h('div', { className: 'ai-dir-row' },
            h('span', { className: 'ai-dir-toggle' }),
            h('label', null,
              h('input', { type: 'checkbox', checked: true, onChange: function () { toggleDir(p); } }),
              ' ' + p)));
      }),
      h('li', { key: '__top_files' },
        h('div', { className: 'ai-dir-row' },
          h('span', { className: 'ai-dir-toggle' }),
          h('label', null,
            h('input', { type: 'checkbox', checked: topFiles, onChange: toggleTop }),
            ' Top-level files (' + rootFiles.length + ')')))),
    h('label', { className: 'ai-hint' },
      h('input', { type: 'checkbox', checked: split, onChange: function () { setSplit(!split); } }),
      ' Split into up to 3 files (.zip)'),
    exp.error && h('div', { className: 'ai-error' }, exp.error),
    exp.pendingCopy && h('div', { className: 'ai-error' },
      'About ' + Math.round(exp.pendingCopy.stats.bytes / 4).toLocaleString() + ' tokens. Pasted text goes entirely into the chat context and no sandbox sees it. Prefer Download .md. ',
      h('button', {
        type: 'button', className: 'import-conflict-btn',
        onClick: function () { writeClipboard(exp.pendingCopy.text, exp.pendingCopy.stats); }
      }, 'Copy anyway')),
    exp.stats && h('div', { className: 'ai-result' },
      exp.stats.filename + ': ' + exp.stats.files + ' files, ' + aiHumanSize(exp.stats.bytes) +
      ', about ' + Math.round(exp.stats.bytes / 4).toLocaleString() + ' tokens'),
    exp.notice && h('div', { className: 'ai-result' }, exp.notice),
    h('div', { className: 'ai-hint' }, summary)
  );

  var filesList = apply.files && h('ul', { className: 'import-conflict-list ai-files' },
    apply.files.map(function (f) {
      return h('li', { key: f.path, title: f.path },
        h('span', { className: 'ai-status ai-status-' + f.status }, f.status),
        ' ' + (f.from ? f.from + ' -> ' : '') + f.path + '  +' + f.added + ' -' + f.removed);
    }));

  var previewing = !apply.applied && !!apply.diff && apply.checkedPatch === patch;

  var applyPane = h('div', { className: 'ai-pane' },
    !previewing && h('p', { className: 'ai-hint' }, 'Paste the assistant\'s reply. Surrounding text and the code fence are ignored.'),
    !previewing && h('label', { className: 'ai-file' }, 'Load .patch file: ',
      h('input', { type: 'file', accept: '.patch,.diff,.txt', onChange: loadPatchFile })),
    !previewing && h('textarea', {
      className: 'ai-patch', value: patch, spellCheck: false, placeholder: 'diff --git a/... b/...',
      onChange: function (e) { setPatch(e.target.value); }
    }),
    apply.error && h('pre', { className: 'ai-error' }, apply.error),
    apply.applied && h('div', { className: 'ai-result' }, 'Applied ' + apply.files.length + ' file' + (apply.files.length === 1 ? '' : 's') + '.'),
    previewing && h('div', { className: 'ai-result' }, 'Check passed. Will change:',
      h('button', { type: 'button', className: 'ai-edit-diff', onClick: function () {
        setApply({ busy: false, error: null, files: null, checkedPatch: null, applied: false });
      } }, 'Edit diff')),
    apply.applied && filesList,
    previewing && h('div', { className: 'ai-diff' + (_ref.wrap ? ' ai-diff-wrap' : ''), tabIndex: 0, 'aria-label': 'Diff preview' },
      apply.parsed.map(function (f, i) {
        var s = apply.sel[i];
        var all = s.every(Boolean);
        var some = s.some(Boolean);
        return h('div', { key: i },
          h('label', { className: 'ai-file-row' },
            h('input', {
              type: 'checkbox', checked: all,
              ref: function (el) { if (el) el.indeterminate = some && !all; },
              onChange: function () { setSel(i, s.map(function () { return !all; })); }
            }),
            h('span', { className: 'ai-status ai-status-' + f.status }, f.status),
            (f.from ? f.from + ' -> ' : '') + f.path),
          h('div', { className: some ? '' : 'ai-diff-off' },
            f.header.replace(/\n$/, '').split('\n').map(function (l, k) {
              return h('div', { key: k, className: 'ai-diff-line ai-diff-' + aiHeaderClass(l) }, l);
            })),
          f.hunks.map(function (text, j) {
            return h(AiDiffHunk, {
              key: j, text: text, path: f.path, on: f.atomic ? s[0] : s[j],
              checkbox: f.atomic ? null : h('input', {
                type: 'checkbox', checked: !!s[j], 'aria-label': 'Include hunk',
                onChange: function () { var next = s.slice(); next[j] = !s[j]; setSel(i, next); }
              })
            });
          }));
      }))
  );

  var counts = previewing ? window.MbeditorPatchSelect.count(apply.parsed, apply.sel) : null;
  var canApply = previewing && counts.selected > 0 && !apply.busy;
  var exportDisabled = exp.busy || selectedPaths.length === 0;
  var footer = tab === 'export'
    ? [
        h('button', {
          key: 'copy', type: 'button', className: 'import-conflict-btn', disabled: exportDisabled || splits,
          title: splits ? 'Split bundles download as a zip' : undefined, onClick: copyBundle
        }, 'Copy to clipboard'),
        h('button', {
          key: 'download', type: 'button', className: 'import-conflict-btn import-conflict-btn-primary', disabled: exportDisabled, onClick: download
        }, exp.busy ? 'Building...' : 'Download ' + (splits ? '.zip' : '.md'))
      ]
    : [
        h('button', {
          key: 'check', type: 'button', className: 'import-conflict-btn',
          disabled: apply.busy || !patch.trim(), onClick: check
        }, 'Check'),
        h('button', {
          key: 'apply', type: 'button', className: 'import-conflict-btn import-conflict-btn-primary',
          disabled: !canApply, onClick: applyPatch
        }, counts ? 'Apply ' + counts.selected + ' of ' + counts.total + ' changes' : 'Apply')
      ];

  var tabButton = function (id, label) {
    return h('button', {
      type: 'button', role: 'tab', 'aria-selected': tab === id,
      className: 'ai-tab' + (tab === id ? ' active' : ''), onClick: function () { setTab(id); }
    }, label);
  };

  return h(window.ModalDialog, { className: 'schema-modal ai-modal', label: 'AI export and apply', onDismiss: onClose },
    h('div', { className: 'schema-modal-header' },
      h('div', { className: 'ai-tabs', role: 'tablist' }, tabButton('export', 'Export'), tabButton('apply', 'Apply diff'))),
    h('div', { className: 'schema-modal-body' }, tab === 'export' ? exportPane : applyPane),
    h('div', { className: 'import-conflict-actions' },
      previewing && tab === 'apply' && h('label', { className: 'ai-wrap-toggle' },
        h('input', { type: 'checkbox', checked: !!_ref.wrap, onChange: function (e) { _ref.onWrapChange(e.target.checked); } }),
        'Wrap lines'),
      h('button', { type: 'button', className: 'import-conflict-btn', onClick: onClose }, 'Close'),
      footer)
  );
};

window.AiRoundTripModal = AiRoundTripModal;
