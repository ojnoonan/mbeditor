# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require File.expand_path('dummy/config/environment', __dir__)
require 'rails/test_help'

require 'minitest/reporters'
Minitest::Reporters.use! Minitest::Reporters::ProgressReporter.new

require 'webmock/minitest'
WebMock.disable_net_connect!

# Never boot a rubocop --server daemon from the test suite: server startup is
# slow, leaves a background process per workspace, and the lint tests assert
# subprocess behavior that must stay deterministic.
Mbeditor.configuration.rubocop_server = false
