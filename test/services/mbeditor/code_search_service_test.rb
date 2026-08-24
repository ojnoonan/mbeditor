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

    test "grep fallback prunes exclusions via find and passes a timeout through ProcessRunner" do
      original_excluded = Mbeditor.configuration.excluded_paths
      Mbeditor.configuration.excluded_paths = %w[node_modules tmp vendor/bundle]
      captured = nil
      singleton = class << ProcessRunner; self; end
      singleton.alias_method :__orig_call, :call
      ProcessRunner.define_singleton_method(:call) do |cmd, **opts|
        # Background threads (git polling, cache warm) may call ProcessRunner
        # concurrently — only capture the grep spawned by CodeSearchService.
        if cmd.first == "sh"
          captured = { cmd: cmd, opts: opts }
          { stdout: "", stderr: "", exit_status: nil }
        else
          __orig_call(cmd, **opts)
        end
      end

      sr_singleton = class << SearchReplaceService; self; end
      sr_singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { false }

      CodeSearchService.call("pattern", @workspace)

      pipeline = captured[:cmd].last
      assert_includes pipeline, "-name node_modules"
      assert_includes pipeline, "-path #{File.join(@workspace, 'vendor/bundle')}"
      assert_includes pipeline, "-prune"
      assert_includes pipeline, "-I"
      assert_equal Mbeditor.configuration.search_timeout, captured[:opts][:timeout]
      assert_equal "C", captured[:opts][:env]["LC_ALL"]
    ensure
      Mbeditor.configuration.excluded_paths = original_excluded
      singleton.remove_method :call
      singleton.alias_method :call, :__orig_call
      singleton.remove_method :__orig_call
      sr_singleton.remove_method :rg_available?
      sr_singleton.alias_method :rg_available?, :__orig_rg_available?
      sr_singleton.remove_method :__orig_rg_available?
    end

    # The git tier used to be the only backend that ignored excluded_paths, so
    # a definition lookup walked node_modules in full on every "Cannot find
    # name" the editor reported. Keep the exclusions on the command line.
    test "git grep tier passes excluded paths as :(exclude) pathspecs and no LC_ALL" do
      original_excluded = Mbeditor.configuration.excluded_paths
      Mbeditor.configuration.excluded_paths = %w[node_modules vendor/bundle]
      system("git", "-C", @workspace, "init", "-q", exception: true)
      captured = nil

      singleton = class << ProcessRunner; self; end
      singleton.alias_method :__orig_call, :call
      ProcessRunner.define_singleton_method(:call) do |cmd, **opts|
        if cmd.first == "git" && cmd.include?("grep")
          captured = { cmd: cmd, opts: opts }
          { stdout: "", stderr: "", exit_status: nil }
        else
          __orig_call(cmd, **opts)
        end
      end

      sr_singleton = class << SearchReplaceService; self; end
      sr_singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { false }

      CodeSearchService.call("pattern", @workspace)

      assert_equal "git", captured[:cmd].first
      assert_includes captured[:cmd], ":(exclude)node_modules"
      assert_includes captured[:cmd], ":(exclude)vendor/bundle"
      assert_nil (captured[:opts][:env] || {})["LC_ALL"]
    ensure
      Mbeditor.configuration.excluded_paths = original_excluded
      singleton.remove_method :call
      singleton.alias_method :call, :__orig_call
      singleton.remove_method :__orig_call
      sr_singleton.remove_method :rg_available?
      sr_singleton.alias_method :rg_available?, :__orig_rg_available?
      sr_singleton.remove_method :__orig_rg_available?
    end

    # Minified bundles cannot hold the definition being looked for (their
    # globals are one-letter names inside a closure) but are usually the
    # largest files in the workspace, so every tier skips them — same
    # convention as JsProgramService and JsGlobalsService.
    test "minified bundles are skipped by the definition search" do
      write_file("app/assets/javascripts/thing.js", "function myFunction() {}")
      write_file("vendor/assets/lib.min.js", "function myFunction() {}")

      files = CodeSearchService.call("myFunction", @workspace).map { |l| l.split(":").first }

      assert files.any? { |f| f.end_with?("thing.js") }
      assert_empty files.select { |f| f.end_with?("lib.min.js") }, "minified bundle must not be scanned"
    end

    test "the rg tier honours search_respect_gitignore like the search service" do
      captured = nil
      singleton = class << ProcessRunner; self; end
      singleton.alias_method :__orig_call, :call
      ProcessRunner.define_singleton_method(:call) do |cmd, **opts|
        captured = cmd if cmd.first == "rg"
        { stdout: "", stderr: "", exit_status: nil }
      end

      sr_singleton = class << SearchReplaceService; self; end
      sr_singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { true }

      original = Mbeditor.configuration.search_respect_gitignore

      Mbeditor.configuration.search_respect_gitignore = false
      CodeSearchService.call("pattern", @workspace)
      assert_includes captured, "--no-ignore"

      Mbeditor.configuration.search_respect_gitignore = true
      CodeSearchService.call("pattern", @workspace)
      assert_not_includes captured, "--no-ignore"
    ensure
      Mbeditor.configuration.search_respect_gitignore = original
      singleton.remove_method :call
      singleton.alias_method :call, :__orig_call
      singleton.remove_method :__orig_call
      sr_singleton.remove_method :rg_available?
      sr_singleton.alias_method :rg_available?, :__orig_rg_available?
      sr_singleton.remove_method :__orig_rg_available?
    end

    test "returns empty array when a search subprocess times out" do
      singleton = class << ProcessRunner; self; end
      singleton.alias_method :__orig_call, :call
      ProcessRunner.define_singleton_method(:call) do |cmd, **opts|
        raise ProcessRunner::TimeoutError, "timed out" if cmd.first == "grep"

        __orig_call(cmd, **opts)
      end

      sr_singleton = class << SearchReplaceService; self; end
      sr_singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { false }

      assert_equal [], CodeSearchService.call("pattern", @workspace)
    ensure
      singleton.remove_method :call
      singleton.alias_method :call, :__orig_call
      singleton.remove_method :__orig_call
      sr_singleton.remove_method :rg_available?
      sr_singleton.alias_method :rg_available?, :__orig_rg_available?
      sr_singleton.remove_method :__orig_rg_available?
    end

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

      grep_call = captured.find { |c| c[:cmd].first == "sh" && c[:cmd].last.include?(" grep ") }
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
      # Aliased rather than captured as a Method: a reload between here and the
      # ensure re-points the constant at a new class, and rebinding the old
      # Method to it raises "can't bind singleton method to a different class".
      probe_singleton = class << AvailabilityProbe; self; end
      probe_singleton.alias_method :__orig_rg, :rg
      probe_singleton.define_method(:rg) { value }
      yield
    ensure
      probe_singleton.remove_method :rg
      probe_singleton.alias_method :rg, :__orig_rg
      probe_singleton.remove_method :__orig_rg
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
