var ConflictParser = (function () {
  function hasConflicts(content) {
    return /^<<<<<<< /m.test(content);
  }

  function parse(content) {
    var blocks = [];
    var lines = content.split('\n');
    var state = null;
    var headStart = -1, headEnd = -1, dividerLine = -1;
    var headLines = [], incomingLines = [];
    var marker = null;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (/^<<<<<<< /.test(line) && state === null) {
        state = 'head';
        headStart = i;
        headLines = [];
        marker = line;
      } else if (/^=======\s*$/.test(line) && state === 'head') {
        state = 'incoming';
        headEnd = i;
        dividerLine = i;
        incomingLines = [];
      } else if (/^>>>>>>> /.test(line) && state === 'incoming') {
        blocks.push({
          startLine: headStart,
          headEnd: headEnd,
          dividerLine: dividerLine,
          endLine: i,
          headContent: headLines.join('\n'),
          incomingContent: incomingLines.join('\n'),
          marker: marker,
          endMarker: line
        });
        state = null;
      } else if (state === 'head') {
        headLines.push(line);
      } else if (state === 'incoming') {
        incomingLines.push(line);
      }
    }
    return blocks;
  }

  return { hasConflicts: hasConflicts, parse: parse };
})();
