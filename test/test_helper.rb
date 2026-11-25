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
  # AiBundleService caps a part at 64 MB; tests lower it instead of writing that much.
  def with_max_bytes(limit)
    old = Mbeditor::AiBundleService::MAX_BYTES
    Mbeditor::AiBundleService.send(:remove_const, :MAX_BYTES)
    Mbeditor::AiBundleService.const_set(:MAX_BYTES, limit)
    yield
  ensure
    Mbeditor::AiBundleService.send(:remove_const, :MAX_BYTES)
    Mbeditor::AiBundleService.const_set(:MAX_BYTES, old)
  end

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

# The dummy app reloads code in test (enable_reloading), and a reload runs
# ActionCable.server.restart, which discards the adapter ActionCable::TestHelper
# swapped in, so assert_broadcast_on then errors. Settle a pending reload before
# that swap rather than letting the test's first request trigger it.
ActionCable::TestHelper.prepend(Module.new do
  def before_setup
    Rails.application.reloader.reload! if Rails.application.reloaders.any?(&:updated?)
    super
  end
end)
