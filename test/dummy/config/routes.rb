Rails.application.routes.draw do
  # Avoid noisy 404s in development console when no favicon is present.
  get "favicon.ico", to: proc { [204, { "Content-Type" => "image/x-icon" }, []] }

  post   "login",  to: "sessions#create"

  # Shaped to exercise the controller route hints: a full resource, a
  # member and a collection route, a namespace, and a controller action
  # deliberately left unrouted.
  resources :orders do
    member     { post :cancel }
    collection { get  :search }
  end

  namespace :admin do
    resources :users, only: %i[index show]
  end

  delete "logout", to: "sessions#destroy"

  mount ActionCable.server => '/cable'
  mount Mbeditor::Engine => "/mbeditor"
  root to: redirect("/mbeditor")
end
