// Entry for the bundled Monaco global build.
// esbuild compiles this to an IIFE with globalName "monaco", so loading the
// output script sets window.monaco to the full editor API namespace.
// editor.main pulls in all languages, basic-language colorizers, and the
// language-service contributions (css/html/json/typescript).
export * from 'monaco-editor/esm/vs/editor/editor.main.js';
