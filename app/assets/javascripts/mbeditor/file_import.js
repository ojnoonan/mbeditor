'use strict';

// Turns a drop's DataTransfer into a flat list of { file, relativePath }
// entries and packs them into the multipart body the /import endpoint wants.
//
// Directory drops are walked with webkitGetAsEntry — non-standard, but the
// only way any browser exposes a dropped folder. Where it is missing we fall
// back to dataTransfer.files, which is flat: files import, folders vanish.
var FileImport = (function () {
  // Mirrors EditorsController::IMPORT_MAX_FILES. Trimming client-side means a
  // stray node_modules drop reports a clear message instead of a 422 — and
  // keeps the batch under Rack's 128-file-part multipart limit, which would
  // otherwise reject the request as a 500 before the server guard can run.
  var MAX_ENTRIES = 100;

  function hasExternalFiles(dataTransfer) {
    if (!dataTransfer || !dataTransfer.types) return false;
    return Array.prototype.indexOf.call(dataTransfer.types, 'Files') !== -1;
  }

  // MUST be called synchronously from the drop handler: DataTransferItem
  // objects are neutered the moment the handler returns, so every entry is
  // pulled off the item list up front and only then walked asynchronously.
  function collectEntries(dataTransfer) {
    var items = dataTransfer.items;
    var roots = [];
    var supportsEntries = typeof DataTransferItem !== 'undefined' &&
      DataTransferItem.prototype.webkitGetAsEntry;

    if (items && items.length && supportsEntries) {
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind !== 'file') continue;
        var entry = items[i].webkitGetAsEntry();
        if (entry) roots.push(entry);
      }
    }

    if (roots.length === 0) {
      var flat = [];
      var files = dataTransfer.files || [];
      for (var j = 0; j < files.length; j++) {
        flat.push({ file: files[j], relativePath: files[j].name });
      }
      return Promise.resolve({
        entries: flat.slice(0, MAX_ENTRIES),
        truncated: flat.length > MAX_ENTRIES,
        foldersSkipped: !!(items && items.length > flat.length)
      });
    }

    var collected = [];
    return walkAll(roots, collected).then(function () {
      return {
        entries: collected.slice(0, MAX_ENTRIES),
        truncated: collected.length > MAX_ENTRIES,
        foldersSkipped: false
      };
    });
  }

  function walkAll(entries, out) {
    return entries.reduce(function (chain, entry) {
      return chain.then(function () { return walk(entry, out); });
    }, Promise.resolve());
  }

  function walk(entry, out) {
    if (entry.isFile) {
      return new Promise(function (resolve) {
        entry.file(function (file) {
          out.push({ file: file, relativePath: stripLeadingSlash(entry.fullPath) });
          resolve();
        }, function () { resolve(); });
      });
    }
    if (!entry.isDirectory) return Promise.resolve();

    var reader = entry.createReader();
    // readEntries hands back at most ~100 children per call and signals the
    // end of the directory with an empty batch, so it has to be called until
    // it runs dry rather than once.
    var readBatch = function () {
      return new Promise(function (resolve) {
        reader.readEntries(function (batch) { resolve(batch); }, function () { resolve([]); });
      }).then(function (batch) {
        if (!batch || batch.length === 0) return null;
        return walkAll(batch, out).then(readBatch);
      });
    };
    return readBatch();
  }

  function stripLeadingSlash(p) {
    return String(p || '').replace(/^\/+/, '');
  }

  // '' as the folder means the workspace root.
  function joinPath(folder, relativePath) {
    var rel = stripLeadingSlash(relativePath);
    if (!folder) return rel;
    return folder.replace(/\/+$/, '') + '/' + rel;
  }

  function buildFormData(entries, targetFolderPath, onConflict) {
    var fd = new FormData();
    fd.append('on_conflict', onConflict);
    entries.forEach(function (e) {
      fd.append('files[]', e.file, e.file.name);
      fd.append('paths[]', joinPath(targetFolderPath, e.relativePath));
    });
    return fd;
  }

  // Match conflict occurrences from the end of the original entry list. If
  // two dropped files map to one previously-free path, pass one imports the
  // first and reports only the later occurrence as conflicting; retrying every
  // entry with that path would duplicate the already-imported file.
  function conflictedEntries(entries, targetFolderPath, conflicts) {
    var remaining = {};
    (conflicts || []).forEach(function(c) {
      var key = '$' + c.path;
      remaining[key] = (remaining[key] || 0) + 1;
    });

    var retry = [];
    for (var i = entries.length - 1; i >= 0; i--) {
      var targetKey = '$' + joinPath(targetFolderPath, entries[i].relativePath);
      if (!remaining[targetKey]) continue;
      retry.unshift(entries[i]);
      remaining[targetKey] -= 1;
    }
    return retry;
  }

  return {
    MAX_ENTRIES: MAX_ENTRIES,
    hasExternalFiles: hasExternalFiles,
    collectEntries: collectEntries,
    joinPath: joinPath,
    buildFormData: buildFormData,
    conflictedEntries: conflictedEntries
  };
})();

// Expose globally for sprockets require
window.FileImport = FileImport;
