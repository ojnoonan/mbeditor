Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true
  config.cache_classes = false

  # Matches what `rails new` puts in a real app's development environment.
  # Without this Rails never inserts ActiveRecord::Migration::CheckPending, so
  # the dummy could not exercise mbeditor's pending-migration handling at all.
  config.active_record.migration_error = :page_load
end
