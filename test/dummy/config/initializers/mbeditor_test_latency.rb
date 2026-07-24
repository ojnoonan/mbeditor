# frozen_string_literal: true

# Insert the artificial-latency middleware only in the test environment, so the
# slow-server/slow-network system tests can simulate a laggy backend. It is a
# no-op (no sleep) until a test sets a delay, so it has no effect on ordinary
# test runs.
if Rails.env.test?
  require Rails.root.join("lib", "mbeditor_test_latency").to_s
  Rails.application.config.middleware.insert_before 0, MbeditorTestLatency::Middleware
end
