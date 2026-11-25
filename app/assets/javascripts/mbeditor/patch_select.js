'use strict';

// Hunk-level selection over a unified diff, for the AI modal's Apply tab.
// Pure text in, text out: parse() splits a patch into files and hunks without
// altering a byte, and build() joins the chosen ones back. Header lines are
// kept verbatim and unselected hunks are dropped; the stale counts and start
// lines that leaves are handled by the server's `git apply --recount`.
//
// Created, deleted, renamed and binary files, and any file with no hunks, are
// atomic: all or nothing.
(function () {
  function splitLines(text) {
    return text.match(/[^\n]*\n|[^\n]+$/g) || [];
  }

  function bare(line) {
    return line.replace(/\r?\n$/, '');
  }

  function describe(f) {
    var h = f.header;
    var m;
    f.from = null;
    if (/^(GIT binary patch|Binary files )/m.test(h)) f.status = 'binary';
    else if (/^rename from /m.test(h)) f.status = 'renamed';
    else if (/^new file mode /m.test(h) || /^--- \/dev\/null\r?$/m.test(h)) f.status = 'created';
    else if (/^deleted file mode /m.test(h) || /^\+\+\+ \/dev\/null\r?$/m.test(h)) f.status = 'deleted';
    else f.status = 'modified';

    if (f.status === 'renamed') {
      f.from = (m = /^rename from (.+)$/m.exec(h)) ? bare(m[1]) : null;
      f.path = (m = /^rename to (.+)$/m.exec(h)) ? bare(m[1]) : '';
    } else if ((m = /^\+\+\+ (?!\/dev\/null)(.+)$/m.exec(h)) || (m = /^--- (?!\/dev\/null)(.+)$/m.exec(h))) {
      f.path = bare(m[1]).replace(/\t.*$/, '').replace(/^[ab]\//, '');
    } else if ((m = /^diff --git a\/.+ b\/(.+)$/m.exec(h))) {
      f.path = bare(m[1]);
    } else {
      f.path = '';
    }
    f.atomic = f.status !== 'modified' || f.hunks.length === 0;
  }

  function parse(text) {
    var lines = splitLines(text);
    var files = [];
    var file = null;
    var inHunk = false;
    lines.forEach(function (l, i) {
      var startsFile = l.indexOf('diff --git ') === 0 ||
        !file ||
        // A plain (non-git) patch has no per-file marker. Three lines together
        // are unambiguous where a removed "-- x" line alone is not.
        (inHunk && l.indexOf('--- ') === 0 && (lines[i + 1] || '').indexOf('+++ ') === 0 && (lines[i + 2] || '').indexOf('@@') === 0);
      if (startsFile) {
        file = { header: '', hunks: [] };
        files.push(file);
        inHunk = false;
      }
      if (l.indexOf('@@') === 0) {
        file.hunks.push('');
        inHunk = true;
      }
      if (inHunk) file.hunks[file.hunks.length - 1] += l;
      else file.header += l;
    });
    files.forEach(describe);
    return files;
  }

  // selection[i] is a boolean per hunk of files[i]; an atomic file reads only
  // selection[i][0].
  function defaultSelection(files) {
    return files.map(function (f) {
      return f.atomic ? [true] : f.hunks.map(function () { return true; });
    });
  }

  function build(files, selection) {
    return files.map(function (f, i) {
      var s = selection[i] || [];
      if (f.atomic) return s[0] ? f.header + f.hunks.join('') : '';
      var keep = f.hunks.filter(function (_h, j) { return s[j]; });
      return keep.length ? f.header + keep.join('') : '';
    }).join('');
  }

  // Units the user chooses between: one per atomic file, one per hunk otherwise.
  function count(files, selection) {
    var selected = 0;
    var total = 0;
    files.forEach(function (f, i) {
      var s = selection[i] || [];
      if (f.atomic) { total += 1; if (s[0]) selected += 1; return; }
      total += f.hunks.length;
      f.hunks.forEach(function (_h, j) { if (s[j]) selected += 1; });
    });
    return { selected: selected, total: total };
  }

  // Paths of the files that would be written, old name of a rename included.
  function touchedPaths(files, selection) {
    var out = [];
    files.forEach(function (f, i) {
      var s = selection[i] || [];
      var on = f.atomic ? !!s[0] : s.some(Boolean);
      if (!on) return;
      out.push(f.path);
      if (f.from) out.push(f.from);
    });
    return out;
  }

  window.MbeditorPatchSelect = {
    parse: parse, build: build, count: count, defaultSelection: defaultSelection, touchedPaths: touchedPaths
  };
})();
