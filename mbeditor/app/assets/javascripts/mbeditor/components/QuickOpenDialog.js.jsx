const { useState, useEffect, useRef } = React;

const QuickOpenDialog = ({ onSelect, onClose }) => {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef(null);

  useEffect(() => {
    if (inputRef.current) inputRef.current.focus();
  }, []);

  useEffect(() => {
    const res = SearchService.searchFiles(query);
    setResults(res.slice(0, 20)); // cap at 20
    setSelectedIndex(0);
  }, [query]);

  const handleKeyDown = (e) => {
    if (e.key === "Escape") onClose();
    if (e.key === "ArrowDown") setSelectedIndex(i => Math.min(i + 1, results.length - 1));
    if (e.key === "ArrowUp") setSelectedIndex(i => Math.max(i - 1, 0));
    if (e.key === "Enter" && results[selectedIndex]) {
      const res = results[selectedIndex];
      onSelect(res.path, res.name);
    }
  };

  return (
    <div className="quick-open-overlay" onClick={onClose}>
      <div className="quick-open-box" onClick={e => e.stopPropagation()}>
        <input 
          ref={inputRef}
          type="text" 
          className="quick-open-input"
          placeholder="Search files by name (Ctrl+P)..."
          value={query}
          onChange={e => setQuery(e.target.value)}
          onKeyDown={handleKeyDown}
        />
        <div className="quick-open-results">
          {results.map((res, i) => (
            <div 
              key={res.id} 
              className={`quick-open-result ${i === selectedIndex ? "selected" : ""}`}
              onClick={() => onSelect(res.path, res.name)}
              onMouseEnter={() => setSelectedIndex(i)}
            >
              <div className="quick-open-result-name">{res.name}</div>
              <div className="quick-open-result-path">{res.path}</div>
            </div>
          ))}
          {query && results.length === 0 && (
            <div style={{ padding: "12px 16px", color: "#666", fontSize: "12px" }}>No matching files.</div>
          )}
        </div>
      </div>
    </div>
  );
};

window.QuickOpenDialog = QuickOpenDialog;
