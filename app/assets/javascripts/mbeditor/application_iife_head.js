// Mbeditor app IIFE — React and ReactDOM are injected from window.MbeditorRuntime
// so that mbeditor never reads from or writes to window.React / window.ReactDOM,
// protecting the host application's globals.

// Shared helper — returns the engine mount path with no trailing slash.
// All service modules and components use this instead of inlining the lookup.
window.mbeditorBasePath = function() {
  return (window.MBEDITOR_BASE_PATH || '/mbeditor').replace(/\/$/, '');
};

(function(React, ReactDOM) {
