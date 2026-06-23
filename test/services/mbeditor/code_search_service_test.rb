# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class CodeSearchServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_code_search_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_file(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    # -------------------------------------------------------------------------
    # Matching pattern
    # -------------------------------------------------------------------------

    test "returns output lines when pattern matches a JS file" do
      write_file("app.js", "function myFunction() {}")

      lines = CodeSearchService.call("myFunction", @workspace)

      assert lines.any? { |l| l.include?("myFunction") }
    end

    # -------------------------------------------------------------------------
    # Non-matching pattern
    # -------------------------------------------------------------------------

    test "returns empty array when pattern does not match" do
      write_file("app.js", "function myFunction() {}")

      lines = CodeSearchService.call("noSuchSymbol", @workspace)

      assert_equal [], lines
    end

    # -------------------------------------------------------------------------
    # Glob exclusion
    # -------------------------------------------------------------------------

    test "does not return matches from non-JS files" do
      write_file("notes.txt", "myFunction is mentioned here")

      lines = CodeSearchService.call("myFunction", @workspace)

      assert_equal [], lines
    end

    # -------------------------------------------------------------------------
    # Subprocess failure
    # -------------------------------------------------------------------------

    test "returns empty array when workspace does not exist" do
      lines = CodeSearchService.call("anything", "/nonexistent/path/#{SecureRandom.hex}")

      assert_equal [], lines
    end

    # -------------------------------------------------------------------------
    # JS_GLOBS constant
    # -------------------------------------------------------------------------

    test "JS_GLOBS is a public constant with expected extensions" do
      globs = CodeSearchService::JS_GLOBS

      assert_includes globs, "*.js"
      assert_includes globs, "*.ts"
      assert_includes globs, "*.jsx"
      assert_includes globs, "*.tsx"
    end

    # -------------------------------------------------------------------------
    # Custom globs override
    # -------------------------------------------------------------------------

    test "globs kwarg restricts search to specified file types" do
      write_file("app.js",   "myFunction() {}")
      write_file("notes.rb", "def myFunction; end")

      lines = CodeSearchService.call("myFunction", @workspace, globs: ["*.rb"])

      assert lines.any? { |l| l.include?("notes.rb") }
      assert lines.none? { |l| l.include?("app.js") }
    end

    # -------------------------------------------------------------------------
    # Timeout: rg path routes through ProcessRunner with configured timeout
    # -------------------------------------------------------------------------

    test "rg path runs through ProcessRunner with the configured search_timeout" do
      skip "rg not available" unless AvailabilityProbe.rg

      write_file("app.js", "function myFunction() {}")

      captured = []
      with_search_timeout(7) do
        with_process_runner_recorder(captured) do
          lines = CodeSearchService.call("myFunction", @workspace)
          assert lines.any? { |l| l.include?("myFunction") }
        end
      end

      rg_call = captured.find { |c| c[:cmd].first == "rg" }
      assert rg_call, "expected the rg search to run through ProcessRunner"
      assert_equal 7, rg_call[:timeout]
    end

    # -------------------------------------------------------------------------
    # Timeout: grep path routes through ProcessRunner with configured timeout
    # -------------------------------------------------------------------------

    test "grep path runs through ProcessRunner with the configured search_timeout" do
      write_file("app.js", "function myFunction() {}")

      captured = []
      with_rg_available(false) do
        with_search_timeout(3) do
          with_process_runner_recorder(captured) do
            lines = CodeSearchService.call("myFunction", @workspace)
            assert lines.any? { |l| l.include?("myFunction") }
          end
        end
      end

      grep_call = captured.find { |c| c[:cmd].first == "grep" }
      assert grep_call, "expected the grep search to run through ProcessRunner"
      assert_equal 3, grep_call[:timeout]
    end

    # -------------------------------------------------------------------------
    # Timeout: graceful degradation
    # -------------------------------------------------------------------------

    test "returns empty array when the search subprocess times out" do
      write_file("app.js", "function myFunction() {}")

      stub_process_runner_raising(ProcessRunner::TimeoutError.new("timed out")) do
        lines = CodeSearchService.call("myFunction", @workspace)
        assert_equal [], lines
      end
    end

    private

    def with_rg_available(value)
      original = AvailabilityProbe.method(:rg)
      AvailabilityProbe.define_singleton_method(:rg) { value }
      yield
    ensure
      AvailabilityProbe.singleton_class.send(:remove_method, :rg)
      AvailabilityProbe.define_singleton_method(:rg, original)
    end

    def with_search_timeout(seconds)
      previous = Mbeditor.configuration.search_timeout
      Mbeditor.configuration.search_timeout = seconds
      yield
    ensure
      Mbeditor.configuration.search_timeout = previous
    end

    # Temporarily wrap ProcessRunner.call to record cmd + timeout while still
    # delegating to the real runner. Mirrors the recorder in
    # editors_controller_test.rb / git_info_service_test.rb.
    def with_process_runner_recorder(captured)
      real = ProcessRunner.method(:call)
      verbose = $VERBOSE
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call) do |cmd, **kwargs|
        captured << { cmd: cmd, timeout: kwargs[:timeout] }
        real.call(cmd, **kwargs)
      end
      $VERBOSE = verbose
      yield
    ensure
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call, real)
      $VERBOSE = verbose
    end

    def stub_process_runner_raising(error)
      real = ProcessRunner.method(:call)
      verbose = $VERBOSE
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call) do |*, **|
        raise error
      end
      $VERBOSE = verbose
      yield
    ensure
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call, real)
      $VERBOSE = verbose
    end
  end
end
