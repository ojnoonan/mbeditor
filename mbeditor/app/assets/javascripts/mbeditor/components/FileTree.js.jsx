const { useState, useRef, useEffect } = React;

const FileTree = ({ items, onSelect, activePath, selectedPath, onNodeSelect, gitFiles, expandedDirs, onExpandedDirsChange, onFileDoubleClick, onContextMenu, pendingCreate, onCreateConfirm, onCreateCancel, pendingRename, onRenameConfirm, onRenameCancel }) => {
  const [inlineValue, setInlineValue] = useState('');
  const inlineRef = useRef(null);
  const committedRef = useRef(false);

  const renameSelectionEnd = (name) => {
    const value = String(name || '');
    const dotIndex = value.indexOf('.');
    return dotIndex > 0 ? dotIndex : value.length;
  };

  // Auto-focus the inline input whenever pendingCreate is set
  useEffect(() => {
    if (pendingRename) {
      setInlineValue(pendingRename.currentName || '');
      committedRef.current = false;
      setTimeout(() => {
        if (!inlineRef.current) return;
        const input = inlineRef.current;
        input.focus();
        const end = renameSelectionEnd(pendingRename.currentName);
        input.setSelectionRange(0, end);
      }, 0);
      return;
    }

    if (pendingCreate) {
      setInlineValue('');
      committedRef.current = false;
      setTimeout(() => { if (inlineRef.current) inlineRef.current.focus(); }, 0);
    }
  }, [pendingCreate, pendingRename]);

  const toggleFolder = (path, e) => {
    e.stopPropagation();
    const next = !(expandedDirs && expandedDirs[path]);
    if (onExpandedDirsChange) onExpandedDirsChange(Object.assign({}, expandedDirs || {}, { [path]: next }));
  };

  const selectNode = (node) => {
    if (!node || !onNodeSelect) return;
    onNodeSelect({ path: node.path, name: node.name, type: node.type });
  };

  const getGitStatus = (path) => {
    const gitFile = gitFiles.find(f => f.path === path);
    return gitFile ? gitFile.status : null;
  };

  const getTreeStatusMeta = (status) => {
    const raw = (status || '').trim();
    if (!raw) return null;
    if (raw === '??') return { badge: 'N', cssKey: 'A', title: 'Untracked (new file)' };
    if (raw.startsWith('R')) return { badge: 'R', cssKey: 'R', title: 'Renamed' };

    const key = raw.charAt(0);
    const titleMap = {
      M: 'Modified',
      A: 'Added',
      D: 'Deleted',
      U: 'Unmerged'
    };

    return { badge: key || '?', cssKey: key || 'Q', title: titleMap[key] || 'Status' };
  };

  window.getFileIcon = (name) => {
    const ext = name.split('.').pop().toLowerCase();
    const lName = name.toLowerCase();
    if (lName === 'gemfile' || ext === 'gemspec' || ext === 'lock') return 'fas fa-gem ruby-icon';
    if (ext === 'rb' || ext === 'rake' || lName === 'rakefile') return 'far fa-gem ruby-icon';
    if (ext === 'jsx' || name.endsWith('.js.jsx')) return 'fas fa-atom react-icon';
    if (ext === 'js' || ext === 'mjs' || ext === 'cjs') return 'fa-brands fa-js js-icon';
    if (ext === 'html') return 'fa-brands fa-html5 html-icon';
    if (ext === 'erb') return 'fa-brands fa-html5 erb-icon';
    if (ext === 'css' || ext === 'scss' || ext === 'sass') return 'fa-brands fa-css3-alt css-icon';
    if (['png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp', 'bmp', 'avif'].includes(ext)) return 'far fa-file-image image-icon';
    if (ext === 'json') return 'fas fa-code json-icon';
    if (ext === 'md' || ext === 'txt') return 'fas fa-file-alt md-icon';
    if (ext === 'yml' || ext === 'yaml') return 'fas fa-cogs yml-icon';
    return 'far fa-file-code';
  };

  const handleInlineKeyDown = (e) => {
    const isRename = !!pendingRename;
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      committedRef.current = true;
      const rawValue = e && e.currentTarget ? e.currentTarget.value : inlineValue;
      const val = String(rawValue || '').trim();
      if (val) {
        if (isRename && onRenameConfirm) onRenameConfirm(val, pendingRename);
        if (!isRename && onCreateConfirm) onCreateConfirm(val);
      } else {
        if (isRename && onRenameCancel) onRenameCancel();
        if (!isRename && onCreateCancel) onCreateCancel();
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      committedRef.current = true;
      if (isRename && onRenameCancel) onRenameCancel();
      if (!isRename && onCreateCancel) onCreateCancel();
    }
  };

  const handleInlineBlur = () => {
    const isRename = !!pendingRename;
    setTimeout(() => {
      if (!committedRef.current) {
        if (isRename && onRenameCancel) onRenameCancel();
        if (!isRename && onCreateCancel) onCreateCancel();
      }
      committedRef.current = false;
    }, 150);
  };

  const renderInlineRow = () => {
    const isFolder = pendingCreate.type === 'folder';
    const iconClass = isFolder
      ? 'fas fa-folder tree-folder-icon'
      : (window.getFileIcon(inlineValue || '') + ' tree-file-icon');
    return (
      <div key="__inline-create__" className="tree-item tree-item-inline-create">
        <div className="tree-item-icon"><i className={iconClass}></i></div>
        <input
          ref={inlineRef}
          className="tree-inline-input"
          type="text"
          value={inlineValue}
          onChange={(e) => setInlineValue(e.target.value)}
          onKeyDown={handleInlineKeyDown}
          onBlur={handleInlineBlur}
          autoComplete="off"
          spellCheck={false}
          placeholder={isFolder ? 'folder name' : 'file name'}
        />
      </div>
    );
  };

  const renderInlineRenameRow = (node) => {
    const isFolder = node.type === 'folder';
    const iconClass = isFolder
      ? 'fas fa-folder tree-folder-icon'
      : (window.getFileIcon(inlineValue || node.name || '') + ' tree-file-icon');
    return (
      <div className="tree-item tree-item-inline-create">
        <div className="tree-item-icon"><i className={iconClass}></i></div>
        <input
          ref={inlineRef}
          className="tree-inline-input"
          type="text"
          value={inlineValue}
          onChange={(e) => setInlineValue(e.target.value)}
          onKeyDown={handleInlineKeyDown}
          onBlur={handleInlineBlur}
          autoComplete="off"
          spellCheck={false}
          placeholder="name"
        />
      </div>
    );
  };

  const renderTree = (nodes, folderPath) => {
    const sortedNodes = [...nodes].sort((a, b) => {
      if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    const rows = sortedNodes.map(node => {
      const isFolder = node.type === "folder";
      const isExpanded = !!(expandedDirs && expandedDirs[node.path]);
      const isRenamingThisNode = !!(pendingRename && pendingRename.path === node.path);
      const isOpenFile = activePath === node.path;
      const isSelected = selectedPath === node.path;
      const status = getGitStatus(node.path);
      const statusMeta = getTreeStatusMeta(status);
      const isModified = statusMeta && (statusMeta.cssKey === "M" || statusMeta.cssKey === "A");

      return (
        <div key={node.path} className="file-tree">
          {isRenamingThisNode ? (
            renderInlineRenameRow(node)
          ) : (
            <div
              className={`tree-item ${isOpenFile ? "active" : ""} ${isSelected ? "selected" : ""} ${isModified ? "modified" : ""}`}
              onClick={(e) => {
                selectNode(node);
                if (isFolder) {
                  toggleFolder(node.path, e);
                } else {
                  onSelect(node.path, node.name);
                }
              }}
              onDoubleClick={(e) => {
                if (!isFolder && onFileDoubleClick) {
                  e.stopPropagation();
                  onFileDoubleClick(node.path, node.name);
                }
              }}
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                selectNode(node);
                if (onContextMenu) onContextMenu(e, node);
              }}
            >
              <div className="tree-item-icon">
                {isFolder ? (
                  <i className={`fas fa-folder${isExpanded ? "-open" : ""} tree-folder-icon`}></i>
                ) : (
                  <i className={`${window.getFileIcon(node.name)} tree-file-icon`}></i>
                )}
              </div>
              <div className="tree-item-name" title={node.path}>{node.name}</div>
              {statusMeta && (
                <div className={`git-status-badge git-${statusMeta.cssKey}`} title={statusMeta.title}>{statusMeta.badge}</div>
              )}
            </div>
          )}

          {isFolder && isExpanded && node.children && (
            <div style={{ paddingLeft: "12px" }}>
              {renderTree(node.children, node.path)}
            </div>
          )}
        </div>
      );
    });

    // Inject inline create row at the end of this directory's list
    if (pendingCreate && pendingCreate.parentPath === folderPath) {
      rows.push(renderInlineRow());
    }

    return rows;
  };

  return <div className="file-tree-root">{renderTree(items, '')}</div>;
};

// Expose globally for sprockets require
window.FileTree = FileTree;
