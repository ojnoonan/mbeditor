'use strict';

// A deliberately small Ruby lexer for editor outlines. It recognizes only
// declarations and never evaluates source; masking literals avoids false
// matches without needing a full Ruby parser.
var RubyOutline = (function () {
  var MAX_ENTRIES = 5000;
  var DEF_RE = /^\s*def\s+(self\.)?([a-zA-Z_][a-zA-Z0-9_?!=]*)/;
  var VISIBILITY_RE = /^\s*(public|protected|private)\s*(?:#.*)?$/;
  var SCOPE_RE = /^\s*(class|module)\b/;
  var DECLARATION_RE = /^\s*((?:RSpec\.)?(?:describe|context|feature)|test|it|specify|example|scenario)\b/;
  var SUITE_NAMES = {
    'describe': true, 'RSpec.describe': true,
    'context': true, 'RSpec.context': true,
    'feature': true, 'RSpec.feature': true
  };
  var TEST_NAMES = { 'test': true, 'it': true, 'specify': true, 'example': true, 'scenario': true };

  function indentation(line) {
    var leading = (/^[ \t]*/.exec(line) || [''])[0];
    return leading.replace(/\t/g, '  ').length;
  }

  function popScopesAtOrInside(scopes, indent) {
    while (scopes.length > 1 && scopes[scopes.length - 1].indent >= indent) {
      scopes.pop();
    }
  }

  function percentLiteralAt(line, index) {
    if (line.charAt(index) !== '%') return null;

    var type = line.charAt(index + 1);
    var delimiterIndex = index + 1;
    if (/[qQwWrixsI]/.test(type)) delimiterIndex++;

    var open = line.charAt(delimiterIndex);
    if (!open || /[a-zA-Z0-9_\s]/.test(open)) return null;

    var pairs = { '(': ')', '[': ']', '{': '}', '<': '>' };
    return {
      length: delimiterIndex - index + 1,
      open: open,
      close: pairs[open] || open,
      paired: !!pairs[open]
    };
  }

  function heredocAt(line, index) {
    if (line.slice(index, index + 2) !== '<<') return null;
    if (index > 0 && !/[\s(,=\[{]/.test(line.charAt(index - 1))) return null;

    var match = /^<<([-~])?(?:'([^'\r\n]+)'|"([^"\r\n]+)"|`([^`\r\n]+)`|([a-zA-Z_][a-zA-Z0-9_]*))/.exec(line.slice(index));
    if (!match) return null;

    return {
      length: match[0].length,
      terminator: match[2] || match[3] || match[4] || match[5],
      allowIndent: !!match[1]
    };
  }

  function startsSlashRegex(line, index, code) {
    if (/\s/.test(line.charAt(index + 1))) return false;

    var prefix = code.replace(/\s+$/, '');
    if (prefix.length === 0) return true;
    if (/[=(:,\[!&|?{};+\-*%<>~^]$/.test(prefix)) return true;
    if (/\b(?:return|yield|when|if|unless|while|until|and|or|not)$/.test(prefix)) return true;

    return /\s$/.test(line.slice(0, index)) &&
      /[a-zA-Z_][a-zA-Z0-9_!?=]*$/.test(prefix);
  }

  function maskRubyLine(line, state) {
    var code = '';
    var heredocs = [];
    var i = 0;

    while (i < line.length) {
      var ch = line.charAt(i);

      if (state) {
        var maskedCharacter = ' ';

        if (state.escaped) {
          state.escaped = false;
        } else if (ch === '\\') {
          state.escaped = true;
        } else if (state.regex && ch === '[') {
          state.inCharacterClass = true;
        } else if (state.regex && ch === ']') {
          state.inCharacterClass = false;
        } else if (state.regex && ch === '/' && !state.inCharacterClass) {
          state = null;
        } else if (state.paired && ch === state.open) {
          state.depth++;
        } else if (!state.regex && ch === state.close) {
          if (state.paired) state.depth--;
          if (!state.paired || state.depth === 0) state = null;
        }

        if (!state) maskedCharacter = 'x';
        code += maskedCharacter;
        i++;
        continue;
      }

      if (ch === '#') break;

      if (ch === "'" || ch === '"' || ch === '`') {
        state = { open: ch, close: ch, paired: false, depth: 1, escaped: false };
        code += ' ';
        i++;
        continue;
      }

      if (ch === '/' && startsSlashRegex(line, i, code)) {
        state = {
          open: '/', close: '/', paired: false, depth: 1, escaped: false,
          regex: true, inCharacterClass: false
        };
        code += ' ';
        i++;
        continue;
      }

      var percentLiteral = percentLiteralAt(line, i);
      if (percentLiteral) {
        state = {
          open: percentLiteral.open, close: percentLiteral.close,
          paired: percentLiteral.paired, depth: 1, escaped: false
        };
        code += new Array(percentLiteral.length + 1).join(' ');
        i += percentLiteral.length;
        continue;
      }

      var heredoc = heredocAt(line, i);
      if (heredoc) {
        heredocs.push({ terminator: heredoc.terminator, allowIndent: heredoc.allowIndent });
        code += new Array(heredoc.length + 1).join(' ');
        i += heredoc.length;
        continue;
      }

      code += ch;
      i++;
    }

    if (state) state.escaped = false;
    return { code: code, state: state, heredocs: heredocs };
  }

  function addEntry(entries, entry) {
    if (entries.length >= MAX_ENTRIES) return false;
    entries.push(entry);
    return true;
  }

  function cloneLexicalState(state) {
    if (!state) return null;
    return {
      open: state.open,
      close: state.close,
      paired: state.paired,
      depth: state.depth,
      escaped: state.escaped,
      regex: state.regex,
      inCharacterClass: state.inCharacterClass
    };
  }

  function cloneHeredocs(heredocs) {
    return heredocs.map(function (heredoc) {
      return { terminator: heredoc.terminator, allowIndent: heredoc.allowIndent };
    });
  }

  function testPath(path) {
    return /(^|\/)test\/.*_test\.rb$/.test(path) ||
      /(^|\/)spec\/.*_spec\.rb$/.test(path) ||
      /_test\.rb$/.test(path) ||
      /_spec\.rb$/.test(path);
  }

  function declarationDescription(raw, code, declaration, kind, lineNumber) {
    var rest = raw.slice(raw.indexOf(declaration) + declaration.length);
    var codeRest = code.slice(code.indexOf(declaration) + declaration.length);
    var quoted = /^\s*\(?\s*(['"])((?:\\.|[^\\])*?)\1/.exec(rest);
    var constant = /^\s*\(?\s*([A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*)(?=\s*(?:,|\)|\bdo\b|\{))/.exec(rest);
    var descriptor = codeRest.replace(/(?:\bdo\b|\{)[\s\S]*$/, '').replace(/[(){}\s]/g, '');

    if (quoted && quoted[2].indexOf('\n') === -1 &&
        (quoted[1] === "'" || quoted[2].indexOf('#{') === -1)) return quoted[2];
    if (constant) return constant[1];
    if (quoted || /[a-zA-Z_:]/.test(descriptor) || /<</.test(rest)) {
      return kind === 'suite' ? 'suite at line ' + lineNumber : 'test at line ' + lineNumber;
    }
    return null;
  }

  function declarationStatus(code) {
    var parenDepth = 0;
    var bracketDepth = 0;
    var hashDepth = 0;
    var i = 0;

    while (i < code.length) {
      var ch = code.charAt(i);

      if (ch === '(') {
        parenDepth++;
      } else if (ch === ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (ch === '[') {
        bracketDepth++;
      } else if (ch === ']') {
        if (bracketDepth > 0) bracketDepth--;
      } else if (ch === '{') {
        if (parenDepth === 0 && bracketDepth === 0 && hashDepth === 0) {
          var beforeBrace = code.slice(0, i).replace(/\s+$/, '');
          if (!/(?:[:,=]|\*\*|=>)$/.test(beforeBrace)) {
            return { complete: true, canContinue: false };
          }
        }
        hashDepth++;
      } else if (ch === '}') {
        if (hashDepth > 0) hashDepth--;
      } else if (parenDepth === 0 && bracketDepth === 0 && hashDepth === 0 &&
          code.slice(i, i + 2) === 'do' &&
          (i === 0 || !/[a-zA-Z0-9_!:]/.test(code.charAt(i - 1))) &&
          !/[a-zA-Z0-9_!?=]/.test(code.charAt(i + 2)) &&
          !/^\s*:/.test(code.slice(i + 2))) {
        return { complete: true, canContinue: false };
      }
      i++;
    }

    var trimmed = code.replace(/\s+$/, '');
    return {
      complete: false,
      canContinue: parenDepth > 0 || bracketDepth > 0 || hashDepth > 0 ||
        /(?:[,\\]|[+\-*\/%&|.=<>?:])$/.test(trimmed)
    };
  }

  function scanDeclarationHeader(lines, startIndex, rawHeader, codeHeader, state, heredocs, inBlockComment) {
    var headerEnd = startIndex;
    var localState = cloneLexicalState(state);
    var localHeredocs = cloneHeredocs(heredocs);
    var localBlockComment = inBlockComment;
    var status = declarationStatus(codeHeader);
    if (!status.complete && (localState || localHeredocs.length > 0 || localBlockComment)) {
      status.canContinue = true;
    }

    while (!status.complete && status.canContinue &&
        headerEnd + 1 < lines.length && headerEnd - startIndex < 7) {
      headerEnd++;
      var nextLine = String(lines[headerEnd] || '').replace(/\r?\n$/, '');
      var nextCode = '';

      if (localBlockComment) {
        if (/^=end\b/.test(nextLine)) localBlockComment = false;
      } else if (localHeredocs.length > 0) {
        var pendingHeredoc = localHeredocs[0];
        var candidateTerminator = pendingHeredoc.allowIndent ?
          nextLine.replace(/^\s+/, '') : nextLine;
        if (candidateTerminator === pendingHeredoc.terminator) localHeredocs.shift();
      } else {
        var nextMasked = maskRubyLine(nextLine, localState);
        localState = nextMasked.state;
        nextCode = nextMasked.code;

        if (/^=begin\b/.test(nextCode)) {
          localBlockComment = true;
          nextCode = '';
        } else {
          for (var h = 0; h < nextMasked.heredocs.length; h++) {
            localHeredocs.push(nextMasked.heredocs[h]);
          }
        }
      }

      rawHeader += '\n' + nextLine;
      codeHeader += '\n' + nextCode;
      status = declarationStatus(codeHeader);
      if (!status.complete && (localState || localHeredocs.length > 0 || localBlockComment)) {
        status.canContinue = true;
      }
    }

    return {
      complete: status.complete,
      rawHeader: rawHeader,
      codeHeader: codeHeader,
      headerEnd: headerEnd,
      state: localState,
      heredocs: localHeredocs,
      inBlockComment: localBlockComment
    };
  }

  function parse(lines, options) {
    var entries = [];
    var scopes = [{ indent: -1, visibility: null }];
    var suites = [];
    var heredocTerminators = [];
    var lexicalState = null;
    var inBlockComment = false;
    var path = String((options || {}).path || '');
    var allowTestDsl = testPath(path);
    var stopped = false;

    for (var i = 0; i < lines.length && !stopped; i++) {
      var line = String(lines[i] || '').replace(/\r?\n$/, '');
      var codeLine;
      var masked;

      if (inBlockComment) {
        if (/^=end\b/.test(line)) inBlockComment = false;
        continue;
      }

      if (heredocTerminators.length > 0) {
        var pendingHeredoc = heredocTerminators[0];
        var candidateTerminator = pendingHeredoc.allowIndent ? line.replace(/^\s+/, '') : line;
        if (candidateTerminator === pendingHeredoc.terminator) heredocTerminators.shift();
        continue;
      }

      masked = maskRubyLine(line, lexicalState);
      lexicalState = masked.state;
      codeLine = masked.code;

      if (/^=begin\b/.test(codeLine)) {
        inBlockComment = true;
        continue;
      }

      for (var h = 0; h < masked.heredocs.length; h++) heredocTerminators.push(masked.heredocs[h]);
      if (/^\s*$/.test(codeLine)) continue;

      var indent = indentation(line);
      while (suites.length > 0 && indent <= suites[suites.length - 1].indent) suites.pop();

      if (SCOPE_RE.test(codeLine)) {
        popScopesAtOrInside(scopes, indent);
        scopes.push({ indent: indent, visibility: null });
        continue;
      }

      var visibilityMatch = VISIBILITY_RE.exec(codeLine);
      if (visibilityMatch) {
        popScopesAtOrInside(scopes, indent);
        scopes[scopes.length - 1].visibility = visibilityMatch[1];
        continue;
      }

      var methodMatch = DEF_RE.exec(codeLine);
      if (methodMatch) {
        popScopesAtOrInside(scopes, indent);
        if (!addEntry(entries, {
          line: i + 1,
          name: (methodMatch[1] || '') + methodMatch[2],
          kind: 'method',
          depth: suites.length,
          visibility: methodMatch[1] ? 'public' : scopes[scopes.length - 1].visibility
        })) stopped = true;
        continue;
      }

      if (!allowTestDsl) continue;

      var declarationMatch = DECLARATION_RE.exec(codeLine);
      if (!declarationMatch) continue;

      var declaration = declarationMatch[1];
      var kind = SUITE_NAMES[declaration] ? 'suite' : (TEST_NAMES[declaration] ? 'test' : null);
      if (!kind) continue;

      var rawHeader = line;
      var codeHeader = codeLine;
      var headerEnd = i;
      var headerScan = scanDeclarationHeader(
        lines, i, rawHeader, codeHeader, lexicalState,
        heredocTerminators, inBlockComment
      );

      if (!headerScan.complete) continue;
      if (headerScan.headerEnd > i) {
        rawHeader = headerScan.rawHeader;
        codeHeader = headerScan.codeHeader;
        headerEnd = headerScan.headerEnd;
        lexicalState = headerScan.state;
        heredocTerminators = headerScan.heredocs;
        inBlockComment = headerScan.inBlockComment;
      }

      var name = declarationDescription(rawHeader, codeHeader, declaration, kind, i + 1);
      if (!name) continue;

      if (!addEntry(entries, {
        line: i + 1,
        name: name,
        kind: kind,
        depth: suites.length,
        visibility: null
      })) {
        stopped = true;
        continue;
      }

      if (kind === 'suite' && !/(?:\bdo\b|\{)[\s\S]*\bend\b/.test(codeHeader)) {
        suites.push({ indent: indent });
      }
      i = headerEnd;
    }

    return { entries: entries, truncated: entries.length >= MAX_ENTRIES && stopped };
  }

  return { parse: parse, isTestPath: testPath };
})();

window.RubyOutline = RubyOutline;
