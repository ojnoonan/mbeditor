// Mbeditor app IIFE — React and ReactDOM are injected from window.MbeditorRuntime
// so that mbeditor never reads from or writes to window.React / window.ReactDOM,
// protecting the host application's globals.
(function(React, ReactDOM) {
