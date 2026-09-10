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

class Minitest::Test
  # Temporarily wrap ProcessRunner.call so every subprocess invocation is
  # recorded (cmd + timeout) while still delegating to the real runner.
  def with_process_runner_recorder(captured)
    runner = Mbeditor::ProcessRunner
    real = runner.method(:call)
    verbose = $VERBOSE
    $VERBOSE = nil
    runner.singleton_class.send(:define_method, :call) do |cmd, **kwargs|
      captured << { cmd: cmd, timeout: kwargs[:timeout] }
      real.call(cmd, **kwargs)
    end
    $VERBOSE = verbose
    yield
  ensure
    $VERBOSE = nil
    runner.singleton_class.send(:define_method, :call, real)
    $VERBOSE = verbose
  end
end
