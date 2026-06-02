Rails.application.configure do
  config.eager_load = false
  # Reloading is enabled so the test environment mirrors development — the only
  # environment mbeditor runs in. In particular, ActionDispatch::Reloader is
  # present in the middleware stack, which the resilient-routing feature relies
  # on (it inserts itself just above the Reloader). With this off, that feature
  # could not be exercised in-process.
  config.enable_reloading = true
  config.consider_all_requests_local = true
end
