# frozen_string_literal: true

Mbeditor.configure do |config|
  # Allow developers to provide a custom RuboCop command for the dummy app.
  custom_rubocop_command = ENV["MBEDITOR_RUBOCOP_COMMAND"].to_s.strip

  # this is a test
  config.rubocop_command = custom_rubocop_command unless custom_rubocop_command.empty?
end
