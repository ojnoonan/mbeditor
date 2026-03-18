const { useState, useEffect, useRef } = React;

const TabBar = ({ tabs, activeId, onSelect, onClose, onTabDragStart, onTabDragEnd }) => {
  const containerRef = useRef(null);
  const [draggingTabId, setDraggingTabId] = useState(null);

  const getTabMarkerClass = (tab) => {
    const tabMarkers = tab.markers || [];
    if (!tabMarkers.length) return '';

    const hasError = tabMarkers.some((marker) => {
      const severity = String((marker && marker.severity) || '').toLowerCase();
      return severity === 'error' || severity === 'fatal';
    });
    if (hasError) return 'tab-has-error';

    const hasWarning = tabMarkers.some((marker) => {
      const severity = String((marker && marker.severity) || '').toLowerCase();
      return severity !== 'error' && severity !== 'fatal';
    });
    if (hasWarning) return 'tab-has-warning';

    return '';
  };

  // Scroll active tab into view
  useEffect(() => {
    if (containerRef.current) {
      const activeEl = containerRef.current.querySelector('.tab-item.active');
      if (activeEl) {
        activeEl.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
      }
    }
  }, [activeId, tabs]);

  return (
    <div className="tab-bar" ref={containerRef} onWheel={(e) => {
      if (containerRef.current) {
        containerRef.current.scrollLeft += e.deltaY;
      }
    }}>
      {tabs.map(tab => (
        <div 
          key={tab.id} 
          className={`tab-item ${activeId === tab.id ? 'active' : ''} ${getTabMarkerClass(tab)} ${draggingTabId === tab.id ? 'dragging' : ''}`}
          onClick={() => onSelect(tab.id)}
          title={`${tab.path} - Drag to move to another pane`}
          draggable
          onDragStart={(e) => {
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('application/x-mbeditor-tab', tab.id);
            setDraggingTabId(tab.id);
            if (onTabDragStart) onTabDragStart(tab.id);
          }}
          onDragEnd={() => {
            setDraggingTabId(null);
            if (onTabDragEnd) onTabDragEnd();
          }}
        >
          <i className={`tab-item-icon ${window.getFileIcon ? window.getFileIcon(tab.name) : 'far fa-file-code'}`}></i>
          <div className="tab-item-name">{tab.name}</div>
          {tab.dirty && <div className="tab-dirty-dot">●</div>}
          <div 
            className="tab-close" 
            onClick={(e) => {
              e.stopPropagation();
              onClose(tab.id);
            }}
          >
            <i className="fas fa-times"></i>
          </div>
        </div>
      ))}
    </div>
  );
};

window.TabBar = TabBar;
