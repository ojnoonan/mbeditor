Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true
  config.cache_classes = false
end
