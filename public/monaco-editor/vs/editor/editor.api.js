// Shim: monaco-vim requires "monaco-editor/esm/vs/editor/editor.api" but this
// install uses the AMD build (editor.main.js), which registers everything on
// window.monaco.  The AMD paths config maps "monaco-editor/esm/vs" -> "vs", so
// this file is reached as the resolved module.  Return the already-loaded
// window.monaco so monaco-vim gets the expected API object.
define([], function() { return window.monaco; });
