# frozen_string_literal: true

module Mbeditor
  # Single source of truth for the engine's routes.
  #
  # Both the engine's own route set (config/routes.rb via
  # Mbeditor::Engine.routes.draw) and the (later) private, isolated route set
  # draw from this same proc, so the two can never drift apart.
  ROUTE_MAP = proc do
    root to: 'editors#index'

    get    'ping',            to: 'editors#ping'
    get    'workspace',       to: 'editors#workspace'
    get    'files',           to: 'editors#files'
    get    'file',            to: 'editors#show'
    get    'raw',             to: 'editors#raw'
    post   'file',            to: 'editors#save'
    post   'create_file',     to: 'editors#create_file'
    post   'create_dir',      to: 'editors#create_dir'
    patch  'rename',          to: 'editors#rename'
    delete 'delete',          to: 'editors#destroy_path'
    get    'state',           to: 'editors#state'
    post   'state',           to: 'editors#save_state'
    get    'branch_state',    to: 'editors#branch_state'
    post   'branch_state',    to: 'editors#save_branch_state'
    post   'prune_branch_states', to: 'editors#prune_branch_states'
    get  'file_history', to: 'editors#file_history'
    post 'file_history', to: 'editors#save_file_history'
    get    'search',          to: 'editors#search'
    post   'replace_in_files', to: 'editors#replace_in_files'
    get    'definition',      to: 'editors#definition'
    get    'js_definition',   to: 'editors#js_definition'
    get    'js_members',      to: 'editors#js_members'
    get    'module_members',  to: 'editors#module_members'
    get    'file_includes',   to: 'editors#file_includes'
    get    'client_config',   to: 'editors#client_config'
    get    'related_files',   to: 'editors#related_files'
    get    'model_schema',    to: 'editors#model_schema'
    get    'changelog',       to: 'editors#changelog'
    get    'git_info',        to: 'editors#git_info'
    get    'git_status',      to: 'editors#git_status'
    get    'manifest.webmanifest',            to: 'editors#pwa_manifest',   format: false
    get    'sw.js',                           to: 'editors#pwa_sw',         format: false
    get    'mbeditor-icon.svg',               to: 'editors#pwa_icon',       format: false
    get    'monaco_worker.js',                to: 'editors#monaco_worker',  format: false
    get    'ts_worker.js',                    to: 'editors#ts_worker',      format: false
    get    'monaco-editor/*asset_path',       to: 'editors#monaco_asset', format: false
    get    'min-maps/*asset_path',            to: 'editors#monaco_asset', format: false
    post   'lint',            to: 'editors#lint'
    post   'quick_fix',       to: 'editors#quick_fix'
    post   'format',          to: 'editors#format_file'
    post   'test',            to: 'editors#run_test'

    # ── Git & Code Review ──────────────────────────────────────────────────────
    get 'git/diff',           to: 'git#diff'
    get 'git/blame',          to: 'git#blame'
    get 'git/file_history',   to: 'git#file_history'
    get 'git/commit_graph',   to: 'git#commit_graph'
    get 'git/commit_detail',  to: 'git#commit_detail'
    get 'git/combined_diff',  to: 'git#combined_diff'

    # Redmine integration (enabled via config.mbeditor.redmine_enabled)
    get 'redmine/issue/:id', to: 'git#redmine_issue', as: :redmine_issue
  end
end
