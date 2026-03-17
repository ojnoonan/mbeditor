const { useState, useEffect, useRef } = React;

const EditorPanel = ({ tab, onContentChange, markers }) => {
  const editorRef = useRef(null);
  const monacoRef = useRef(null);
  const [markup, setMarkup] = useState('');

  useEffect(() => {
    if (!window._editorExtensionsRegistered && window.monaco) {
      window._editorExtensionsRegistered = true;
      
      // 1. Ruby Auto-End Plugin (Mimics vscode-ruby)
      window.monaco.languages.setLanguageConfiguration('ruby', {
        indentationRules: {
          increaseIndentPattern: /^\s*(def|class|module|if|unless|case|while|until|for|begin|elsif|else|rescue|ensure|when)\b/,
          decreaseIndentPattern: /^\s*(end|elsif|else|rescue|ensure|when)\b/
        },
        onEnterRules: [
          {
            beforeText: /^\s*(def|class|module|if|unless|case|while|until|for|begin)\b.*/,
            action: { indentAction: 2, appendText: 'end' } // IndentOutdent
          },
          {
            beforeText: /.*do(\s*\|.*\|)?\s*$/,
            action: { indentAction: 2, appendText: 'end' } // IndentOutdent
          }
        ]
      });

      // 2. JSX/HTML Auto Rename Tag (Linked Editing)
      const genericLinkedProvider = {
        provideLinkedEditingRanges: function(model, position) {
          const line = model.getLineContent(position.lineNumber);
          const wordInfo = model.getWordAtPosition(position);
          if (!wordInfo) return null;
          
          const word = wordInfo.word;
          const startCol = wordInfo.startColumn;
          const endCol = wordInfo.endColumn;
          
          if (line[startCol - 2] === '<') {
            const closeTagStr = `</${word}>`;
            const closeIdx = line.indexOf(closeTagStr, endCol - 1);
            if (closeIdx !== -1) {
              return {
                ranges: [
                  new window.monaco.Range(position.lineNumber, startCol, position.lineNumber, endCol),
                  new window.monaco.Range(position.lineNumber, closeIdx + 3, position.lineNumber, closeIdx + 3 + word.length)
                ],
                wordPattern: /[a-zA-Z0-9:\-_]+/
              };
            }
          }
          
          if (line[startCol - 3] === '<' && line[startCol - 2] === '/') {
            const openTagRegex = new RegExp(`<${word}(?:\\s|>)`);
            const match = line.match(openTagRegex);
            if (match) {
              const openStart = match.index + 2;
              if (openStart < startCol) {
                return {
                  ranges: [
                    new window.monaco.Range(position.lineNumber, openStart, position.lineNumber, openStart + word.length),
                    new window.monaco.Range(position.lineNumber, startCol, position.lineNumber, endCol)
                  ],
                  wordPattern: /[a-zA-Z0-9:\-_]+/
                };
              }
            }
          }
          return null;
        }
      };
      window.monaco.languages.registerLinkedEditingRangeProvider('javascript', genericLinkedProvider);
      window.monaco.languages.registerLinkedEditingRangeProvider('ruby', genericLinkedProvider);

      // Disable Monaco's built-in JS/TS validator — it can't parse JSX/arrow functions and throws false-positive errors
      if (window.monaco.languages.typescript) {
        window.monaco.languages.typescript.javascriptDefaults.setDiagnosticsOptions({
          noSemanticValidation: true,
          noSyntaxValidation: true
        });
        window.monaco.languages.typescript.typescriptDefaults.setDiagnosticsOptions({
          noSemanticValidation: true,
          noSyntaxValidation: true
        });
      }
    }
  }, []);
  useEffect(() => {
    if (!editorRef.current || !window.monaco) return;

    const parts = tab.path.split('.');
    const extension = parts.length > 1 ? parts.pop().toLowerCase() : '';
    let language = 'plaintext';
    switch(extension) {
      case 'rb': case 'ruby': case 'gemspec': case 'rakefile': language = 'ruby'; break;
      case 'js': case 'jsx': language = 'javascript'; break;
      case 'ts': case 'tsx': language = 'typescript'; break;
      case 'css': case 'scss': case 'sass': language = 'css'; break;
      case 'html': case 'erb': language = 'html'; break;
      case 'json': language = 'json'; break;
      case 'yaml': case 'yml': language = 'yaml'; break;
      case 'md': case 'markdown': language = 'markdown'; break;
      case 'sh': case 'bash': case 'zsh': language = 'shell'; break;
      case 'png': case 'jpg': case 'jpeg': case 'gif': case 'svg': case 'ico': case 'webp': language = 'image'; break;
    }

    if (language === 'image') return;

    const editor = window.monaco.editor.create(editorRef.current, {
      value: tab.content,
      language: language,
      theme: 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      renderLineHighlight: 'none',
      bracketPairColorization: { enabled: true },
      fontFamily: "'JetBrains Mono', 'Fira Code', Consolas, 'Courier New', monospace",
      fontSize: 13,
      tabSize: 4,
      insertSpaces: true,
      wordWrap: 'on',
      linkedEditing: true, // Enables Auto-Rename Tag natively!
      autoClosingBrackets: 'always',
      autoClosingQuotes: 'always',
      autoIndent: 'full',
      formatOnPaste: true,
      formatOnType: true
    });

    if (tab.viewState) {
      editor.restoreViewState(tab.viewState);
    }

    monacoRef.current = editor;

    const modelObj = editor.getModel();
    
    // Change listener
    const disposable = modelObj.onDidChangeContent((e) => {
      const val = editor.getValue();
      const currentContent = monacoRef.current._latestContent || '';
      
      // Normalize before comparing to prevent false positive dirty edits
      const vNorm = val.replace(/\r\n/g, '\n');
      const cNorm = currentContent.replace(/\r\n/g, '\n');
      if (vNorm !== cNorm) {
        onContentChange(val);
      }

      // Auto-Close Tag Plugin Logic
      if (!e.isUndoing && !e.isRedoing && e.changes.length === 1) {
        const change = e.changes[0];
        if (change.text === '>' && change.rangeLength === 0) {
          const lineNum = change.range.startLineNumber;
          const col = change.range.startColumn; // Is the column immediately before where the '>' was inserted
          const lineContent = modelObj.getLineContent(lineNum);
          
          const textBefore = lineContent.substring(0, col - 1); // text before the '>'
          const match = textBefore.match(/<([a-zA-Z][a-zA-Z0-9:\-_]*)(?:\s+[^>]*?)?$/);
          
          if (match && !textBefore.endsWith('/')) {
            const tagName = match[1];
            const voidElements = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'];
            
            if (!voidElements.includes(tagName.toLowerCase())) {
              const textAfter = lineContent.substring(col); // text after the '>'
              if (!textAfter.startsWith(`</${tagName}>`)) {
                setTimeout(() => {
                  if (!monacoRef.current) return;
                  const currentPos = monacoRef.current.getPosition();
                  monacoRef.current.executeEdits("auto-close", [{
                    range: new window.monaco.Range(lineNum, col + 1, lineNum, col + 1),
                    text: `</${tagName}>`
                  }]);
                  monacoRef.current.setPosition(currentPos);
                }, 0);
              }
            }
          }
        }
      }
    });

    return () => {
      TabManager.saveTabViewState(tab.id, editor.saveViewState());
      disposable.dispose();
      editor.dispose();
    };
  }, [tab.id]); // re-run ONLY on tab switch, not on content change (Monaco handles its own content state)

  // Listen for external content changes (e.g. after Format/Save/Load)
  useEffect(() => {
    const editor = monacoRef.current;
    if (editor) editor._latestContent = tab.content; // update ref for closure

    if (editor && editor.getValue() !== tab.content) {
      if (typeof tab.content !== 'string') return;
      // Normalize before comparing to prevent false positive dirty edits
      const vNorm = editor.getValue().replace(/\r\n/g, '\n');
      const cNorm = tab.content.replace(/\r\n/g, '\n');
      if (vNorm === cNorm) return;

      const model = editor.getModel();
      if (model) {
        if (!vNorm) {
          // If the editor is currently completely empty, treat it as an initial load.
          // setValue clears the undo stack which is correct for initial load.
          editor.setValue(tab.content);
        } else {
          // Keep undo stack for formats or replaces by using executeEdits
          editor.pushUndoStop();
          editor.executeEdits("external", [{
            range: model.getFullModelRange(),
            text: tab.content
          }]);
          editor.pushUndoStop();
        }
      }
    }
  }, [tab.content]);

  // Jump to line if specified
  useEffect(() => {
    if (tab.gotoLine && monacoRef.current) {
      const editor = monacoRef.current;
      setTimeout(() => {
        editor.revealLineInCenter(tab.gotoLine);
        editor.setPosition({ lineNumber: tab.gotoLine, column: 1 });
        editor.focus();
        
        // Remove gotoLine from tab state so it doesn't refire
        TabManager.saveTabViewState(tab.id, editor.saveViewState()); // save view state, but how to unset gotoLine?
        // We'll just mutate the local object so this effect doesn't spam jump if the component re-renders
        delete tab.gotoLine;
      }, 50);
    }
  }, [tab.gotoLine, tab.content]); // need tab.content in dep array so if it loads asynchronously, the jump happens AFTER content loads

  // Apply RuboCop markers
  useEffect(() => {
    if (monacoRef.current && window.monaco) {
      const model = monacoRef.current.getModel();
      if (model) {
        const monacoMarkers = markers.map(m => ({
          severity: m.severity === 'error' ? window.monaco.MarkerSeverity.Error : window.monaco.MarkerSeverity.Warning,
          message: m.message,
          startLineNumber: m.startLine,
          startColumn: m.startCol,
          endLineNumber: m.endLine,
          endColumn: m.endCol
        }));
        window.monaco.editor.setModelMarkers(model, 'rubocop', monacoMarkers);
      }
    }
  }, [markers, tab.id]);

  const parts = tab.path.split('.');
  const ext = parts.length > 1 ? parts.pop().toLowerCase() : '';
  const isImage = ['png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp'].includes(ext);
  const isMarkdown = ['md', 'markdown'].includes(ext);

  useEffect(() => {
    if (isMarkdown && window.marked) {
      setMarkup(window.marked.parse(tab.content || ''));
    }
  }, [tab.content, isMarkdown]);

  if (isImage) {
    const basePath = (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
    return (
      <div className="monaco-container" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#1e1e1e' }}>
        <img src={`${basePath}/raw?path=${encodeURIComponent(tab.path)}`} style={{ maxWidth: '90%', maxHeight: '90%', objectFit: 'contain' }} alt={tab.name} />
      </div>
    );
  }

  if (isMarkdown) {
    return (
      <div style={{ display: 'flex', flexDirection: 'row', width: '100%', height: '100%' }}>
        <div ref={editorRef} className="monaco-container" style={{ flex: 1, borderRight: '1px solid #333' }}></div>
        <div className="markdown-preview" style={{ flex: 1, padding: '20px', overflowY: 'auto', background: '#1e1e1e', color: '#ccc', fontFamily: 'sans-serif' }} dangerouslySetInnerHTML={{ __html: markup }}></div>
      </div>
    );
  }

  return <div ref={editorRef} className="monaco-container"></div>;
};

window.EditorPanel = EditorPanel;
