const GitPanel = ({ gitInfo, error, onOpenFile }) => {
  const workingTree = (gitInfo && gitInfo.workingTree) || [];
  const unpushedFiles = (gitInfo && gitInfo.unpushedFiles) || [];
  const branchCommits = (gitInfo && gitInfo.branchCommits) || [];

  const statusMeta = (rawStatus) => {
    const raw = (rawStatus || '').trim();
    if (raw === '??') return { badge: 'NEW', cssKey: 'A', description: 'Untracked local file (not committed yet)' };
    if (raw.startsWith('R')) return { badge: 'R', cssKey: 'R', description: 'Renamed' };

    switch (raw.charAt(0)) {
      case 'M': return { badge: 'M', cssKey: 'M', description: 'Modified' };
      case 'A': return { badge: 'A', cssKey: 'A', description: 'Added' };
      case 'D': return { badge: 'D', cssKey: 'D', description: 'Deleted' };
      case 'U': return { badge: 'U', cssKey: 'Q', description: 'Unmerged/conflict' };
      case 'C': return { badge: 'C', cssKey: 'R', description: 'Copied' };
      default: return { badge: raw || '?', cssKey: 'Q', description: 'Unknown status' };
    }
  };

  const renderFileList = (items, emptyMessage) => {
    if (!items || items.length === 0) {
      return <div className="git-empty">{emptyMessage}</div>;
    }

    return (
      <div className="git-list">
        {items.map((item, idx) => {
          const name = (item.path || '').split('/').pop() || item.path;
          const meta = statusMeta(item.status);
          const statusClass = `git-${meta.cssKey}`;
          return (
            <div key={`${item.path}-${idx}`} className="git-file-item" onClick={() => onOpenFile(item.path, name)}>
              <span className={`git-status-badge ${statusClass}`} title={meta.description}>{meta.badge}</span>
              <span className="git-file-path" title={item.path}>{item.path}</span>
              <span className="git-file-status-label" title={meta.description}>{meta.description}</span>
            </div>
          );
        })}
      </div>
    );
  };

  return (
    <aside className="ide-git-panel" aria-label="Git panel">
      <div className="ide-git-panel-header">
        <div>
          <div className="ide-git-panel-title">Git</div>
          <div className="ide-git-panel-branch">{(gitInfo && gitInfo.branch) || 'unknown branch'}</div>
        </div>
      </div>

      {error && <div className="git-error">{error}</div>}

      <div className="git-metadata">
        <div>Ahead: {(gitInfo && gitInfo.ahead) || 0}</div>
        <div>Behind: {(gitInfo && gitInfo.behind) || 0}</div>
        <div>Upstream: {(gitInfo && gitInfo.upstreamBranch) || 'none'}</div>
      </div>

      <div className="git-section">
        <div className="git-section-title">Working Tree Changes ({workingTree.length})</div>
        <div className="git-hint">`NEW` means the file is local/untracked and not committed yet.</div>
        {renderFileList(workingTree, 'No working tree changes.')}
      </div>

      <div className="git-section">
        <div className="git-section-title">Unpushed File Changes ({unpushedFiles.length})</div>
        {renderFileList(unpushedFiles, 'No unpushed file changes.')}
      </div>

      <div className="git-section git-commit-section">
        <div className="git-section-title">Branch Commit Titles ({branchCommits.length})</div>
        {branchCommits.length === 0 ? (
          <div className="git-empty">No commits on this branch.</div>
        ) : (
          <div className="git-list">
            {branchCommits.map((commit) => (
              <div key={commit.hash} className="git-commit-item" title={commit.hash}>
                <div className="git-commit-title">{commit.title}</div>
                <div className="git-commit-meta">{(commit.hash || '').slice(0, 7)} · {commit.author}</div>
              </div>
            ))}
          </div>
        )}
      </div>
    </aside>
  );
};

window.GitPanel = GitPanel;
