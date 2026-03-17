Mbeditor::Engine.routes.draw do
  root to: "editors#index"

  get  "files",      to: "editors#files"
  get  "file",       to: "editors#show"
  get  "raw",        to: "editors#raw"
  post "file",       to: "editors#save"
  get  "state",      to: "editors#state"
  post "state",      to: "editors#save_state"
  get  "search",     to: "editors#search"
  get  "git_info",   to: "editors#git_info"
  get  "git_status", to: "editors#git_status"
  post "reload",     to: "editors#reload"
  post "lint",       to: "editors#lint"
  post "format",     to: "editors#format_file"
end
