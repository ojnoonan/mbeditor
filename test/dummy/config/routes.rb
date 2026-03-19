Rails.application.routes.draw do
  # Avoid noisy 404s in development console when no favicon is present.
  get "favicon.ico", to: proc { [204, { "Content-Type" => "image/x-icon" }, []] }

  get "monaco_worker.js", to: redirect("/mbeditor/monaco_worker.js")
  get "monaco-editor/*asset_path", to: redirect("/mbeditor/monaco-editor/%{asset_path}"), format: false
  mount ActionCable.server => "/cable"
  mount Mbeditor::Engine => "/mbeditor"
  root to: redirect("/mbeditor")
end
