const { useState, useEffect } = React;

const CollapsibleSection = ({ title, children, isCollapsed = false, onToggle = null, icon = null, actions = null }) => {
  const [localCollapsed, setLocalCollapsed] = useState(isCollapsed);

  // Sync parent isCollapsed prop to local state when it changes
  useEffect(() => {
    setLocalCollapsed(isCollapsed);
  }, [isCollapsed]);

  const toggleCollapsed = (e) => {
    e.stopPropagation();
    const newState = !localCollapsed;
    setLocalCollapsed(newState);
    if (onToggle) {
      onToggle(newState);
    }
  };

  return (
    <div className="collapsible-section">
      <div className="collapsible-header" onClick={toggleCollapsed}>
        <i className={`collapsible-toggle fas fa-chevron-${localCollapsed ? 'right' : 'down'}`}></i>
        {icon && <i className={`collapsible-icon ${icon}`}></i>}
        <span className="collapsible-title">{title}</span>
        {actions && (
          <div className="collapsible-actions" onClick={(e) => e.stopPropagation()}>
            {actions}
          </div>
        )}
      </div>
      {!localCollapsed && (
        <div className="collapsible-content">
          {children}
        </div>
      )}
    </div>
  );
};

window.CollapsibleSection = CollapsibleSection;
