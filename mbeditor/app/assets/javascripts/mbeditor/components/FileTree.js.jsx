const { useState, useEffect, useRef } = React;

const FileTree = ({ items, onSelect, activePath, gitFiles }) => {
  const [expanded, setExpanded] = useState({});

  const toggleFolder = (path, e) => {
    e.stopPropagation();
    setExpanded(prev => ({ ...prev, [path]: !prev[path] }));
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

  const renderTree = (nodes) => {
    const sortedNodes = [...nodes].sort((a, b) => {
      if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    return sortedNodes.map(node => {
      const isFolder = node.type === "folder";
      const isExpanded = !!expanded[node.path];
      const isActive = activePath === node.path;
      const status = getGitStatus(node.path);
      const statusMeta = getTreeStatusMeta(status);
      const isModified = statusMeta && (statusMeta.cssKey === "M" || statusMeta.cssKey === "A");

      return (
        <div key={node.path} className="file-tree">
          <div 
            className={`tree-item ${isActive ? "active" : ""} ${isModified ? "modified" : ""}`}
            onClick={(e) => isFolder ? toggleFolder(node.path, e) : onSelect(node.path, node.name)}
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
          
          {isFolder && isExpanded && node.children && (
            <div style={{ paddingLeft: "12px" }}>
              {renderTree(node.children)}
            </div>
          )}
        </div>
      );
    });
  };

  return <div className="file-tree-root">{renderTree(items)}</div>;
};

// Expose globally for sprockets require
window.FileTree = FileTree;
