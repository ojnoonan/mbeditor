Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Backward-compatible root asset routes for older host-side layouts/scripts.
  get "monaco_worker.js", to: redirect("/mbeditor/monaco_worker.js")
  get "monaco-editor/*asset_path", to: redirect("/mbeditor/monaco-editor/%{asset_path}"), format: false

  mount Mbeditor::Engine => "/mbeditor"
  root to: redirect("/mbeditor")
end
