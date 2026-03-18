# frozen_string_literal: true

Mbeditor::Engine.routes.draw do
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
  get    'search',          to: 'editors#search'
  get    'git_info',        to: 'editors#git_info'
  get    'git_status',      to: 'editors#git_status'
  get    'monaco_worker.js',                to: 'editors#monaco_worker'
  get    'monaco-editor/*asset_path',       to: 'editors#monaco_asset', format: false
  get    'min-maps/*asset_path',            to: 'editors#monaco_asset', format: false
  post   'lint',            to: 'editors#lint'
  post   'format',          to: 'editors#format_file'
end
