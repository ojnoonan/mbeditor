//= require mbeditor/application_iife_head
//= require mbeditor/editor_store
//= require mbeditor/file_icon
//= require mbeditor/file_service
//= require mbeditor/file_import
//= require mbeditor/history_service
//= require mbeditor/websocket_service
//= require mbeditor/git_service
//= require mbeditor/log_service
//= require mbeditor/conflict_parser
//= require mbeditor/search_service
//= require mbeditor/tab_manager
//= require mbeditor/collaboration_identity
//= require mbeditor/collaboration_service
//= require mbeditor/color_provider
//= require mbeditor/editor_plugins
//= require mbeditor/ruby_outline
//= require mbeditor/js_outline
//= require mbeditor/components/CollapsibleSection
//= require mbeditor/components/ShortcutHelp
//= require mbeditor/components/DiffViewer
//= require mbeditor/components/CombinedDiffViewer
//= require mbeditor/components/CommitGraph
//= require mbeditor/components/ModelGraph
//= require mbeditor/components/ChangelogView
//= require mbeditor/components/FileHistoryPanel
//= require mbeditor/components/TestResultsPanel
//= require mbeditor/components/LogPanel
//= require mbeditor/components/ProblemsPanel
//= require mbeditor/components/CodeReviewPanel
//= require mbeditor/components/EditorPanel
//= require mbeditor/components/FileTree
//= require mbeditor/components/GitPanel
//= require mbeditor/components/QuickOpenDialog
//= require mbeditor/components/TabBar
// Both import modals must be required *inside* the IIFE: React is an IIFE
// parameter (window.React is deliberately never set), so a component file
// placed after the tail resolves a bare `React` to undefined and takes the
// whole app down the first time it renders.
//= require mbeditor/components/ImportConflictModal
//= require mbeditor/components/ImportDialog
//= require mbeditor/components/MbeditorApp
//= require mbeditor/application_iife_tail
