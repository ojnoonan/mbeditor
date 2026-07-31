window.SearchService = SearchService;
window.GitService = GitService;
window.FileService = FileService;
// Exposed for system tests to observe collaboration state and drive store updates
// (same test-seam convention as the services above).
window.EditorStore = EditorStore;
window.CollaborationService = CollaborationService;
window.CollaborationIdentity = CollaborationIdentity;
window.WebSocketService = WebSocketService;
})(window.MbeditorRuntime.React, window.MbeditorRuntime.ReactDOM);
