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

  // git quotes a path with non-ASCII or special characters ("caf\303\251.txt").
  // Escapes become %XX so decodeURIComponent reads the octal bytes as UTF-8.
  var QUOTED_ESCAPES = { n: '%0A', t: '%09', r: '%0D', a: '%07', b: '%08', f: '%0C', v: '%0B', '"': '%22', '\\': '%5C' };
  function unquote(p) {
    if (p.length < 2 || p.charAt(0) !== '"' || p.charAt(p.length - 1) !== '"') return p;
    var out = p.slice(1, -1).replace(/\\([0-7]{3}|[\s\S])|%/g, function (m, esc) {
      if (m === '%') return '%25';
      if (/^[0-7]{3}$/.test(esc)) return '%' + ('0' + parseInt(esc, 8).toString(16)).slice(-2).toUpperCase();
      return QUOTED_ESCAPES[esc] || esc;
    });
    try { return decodeURIComponent(out); } catch (e) { return p; }
  }

  // Where the hunk whose "@@" header is lines[i] ends, by its own counts, or -1
  // when the body does not match them (hand-edited or miscounted).
  function hunkEnd(lines, i) {
    var m = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(lines[i]);
    if (!m) return -1;
    var oldLeft = m[1] === undefined ? 1 : +m[1];
    var newLeft = m[2] === undefined ? 1 : +m[2];
    var j = i + 1;
    while (oldLeft > 0 || newLeft > 0) {
      var c = (lines[j] || '').charAt(0);
      if (c === ' ') { oldLeft--; newLeft--; }
      else if (c === '-') oldLeft--;
      else if (c === '+') newLeft--;
      else if (c !== '\\') return -1;
      if (oldLeft < 0 || newLeft < 0) return -1;
      j++;
    }
    while ((lines[j] || '').charAt(0) === '\\') j++;
    return j;
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
      f.from = (m = /^rename from (.+)$/m.exec(h)) ? unquote(bare(m[1])) : null;
      f.path = (m = /^rename to (.+)$/m.exec(h)) ? unquote(bare(m[1])) : '';
    } else if ((m = /^\+\+\+ (?!\/dev\/null)(.+)$/m.exec(h)) || (m = /^--- (?!\/dev\/null)(.+)$/m.exec(h))) {
      f.path = unquote(bare(m[1]).replace(/\t.*$/, '')).replace(/^[ab]\//, '');
    } else if ((m = /^diff --git (?:"a\/.*"|a\/.+) ("b\/.*"|b\/.+)$/m.exec(h))) {
      f.path = unquote(bare(m[1])).replace(/^b\//, '');
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
    var hunkUntil = 0;
    lines.forEach(function (l, i) {
      var startsFile = l.indexOf('diff --git ') === 0 ||
        !file ||
        // A plain (non-git) patch has no per-file marker. Three lines together
        // are unambiguous where a removed "-- x" line alone is not.
        (inHunk && i >= hunkUntil && l.indexOf('--- ') === 0 && (lines[i + 1] || '').indexOf('+++ ') === 0 && (lines[i + 2] || '').indexOf('@@') === 0);
      if (startsFile) {
        file = { header: '', hunks: [] };
        files.push(file);
        inHunk = false;
      }
      if (l.indexOf('@@') === 0) {
        file.hunks.push('');
        inHunk = true;
        hunkUntil = Math.max(hunkEnd(lines, i), 0);
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
  // +serverFiles+ (the check response's files, in patch order) is authoritative
  // when it lines up with the parse, since git decodes quoted names itself.
  function touchedPaths(files, selection, serverFiles) {
    var out = [];
    var useServer = serverFiles && serverFiles.length === files.length;
    files.forEach(function (f, i) {
      var s = selection[i] || [];
      var on = f.atomic ? !!s[0] : s.some(Boolean);
      if (!on) return;
      var src = useServer ? serverFiles[i] : f;
      out.push(src.path);
      if (src.from) out.push(src.from);
    });
    return out;
  }

  window.MbeditorPatchSelect = {
    parse: parse, build: build, count: count, defaultSelection: defaultSelection, touchedPaths: touchedPaths
  };
})();
