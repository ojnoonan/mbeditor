# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("dummy/config/environment", __dir__)
require "rails/test_help"
require "capybara/rails"
require "capybara/cuprite"
require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::ProgressReporter.new

Capybara.register_driver(:cuprite) do |app|
  browser_options = {}
  if ENV["CI"]
    browser_options['no-sandbox'] = nil
    browser_options['disable-dev-shm-usage'] = nil
    browser_options['disable-gpu'] = nil
  end
  Capybara::Cuprite::Driver.new(
    app,
    headless: true,
    timeout: 15,
    process_timeout: 30,
    browser_options: browser_options
  )
end
Capybara.default_driver       = :cuprite
Capybara.javascript_driver    = :cuprite
Capybara.default_max_wait_time = 10
