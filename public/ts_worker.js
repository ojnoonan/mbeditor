const workerPath = self.location.pathname;
const basePath = workerPath.replace(/\/ts_worker\.js$/, "");

self.MonacoEnvironment = { baseUrl: `${basePath}/monaco-editor/` };
importScripts(`${basePath}/monaco-editor/vs/base/worker/workerMain.js`);
