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
  timeout: 15,
  process_timeout: ENV.fetch("MBEDITOR_CUPRITE_PROCESS_TIMEOUT", "120").to_i,
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
