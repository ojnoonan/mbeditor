# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("dummy/config/environment", __dir__)
require "rails/test_help"
require "capybara/rails"
require "capybara/cuprite"
require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::ProgressReporter.new

MBEDITOR_CUPRITE_OPTIONS = {
  headless: true,
  # Page-load timeout: CI precompiles assets before system tests, so 60 s is
  # generous, but slow Ruby 3.0 runners still need headroom.  Override via env.
  timeout: ENV.fetch("MBEDITOR_CUPRITE_TIMEOUT", "60").to_i,
  process_timeout: ENV.fetch("MBEDITOR_CUPRITE_PROCESS_TIMEOUT", "120").to_i,
  # Suppress PendingConnectionsError in case any background resource is still
  # in-flight when Chrome fires the page-load event.
  pending_connection_errors: false,
  browser_options: {
    "no-sandbox": nil,
    "disable-dev-shm-usage": nil,
    "disable-gpu": nil
  }
}.freeze

Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, **MBEDITOR_CUPRITE_OPTIONS)
end
Capybara.default_driver       = :cuprite
Capybara.javascript_driver    = :cuprite
Capybara.default_max_wait_time = 10
