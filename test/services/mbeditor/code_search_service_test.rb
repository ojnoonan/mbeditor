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

    test "grep fallback passes exclude-dirs and a timeout through ProcessRunner" do
      original_excluded = Mbeditor.configuration.excluded_paths
      Mbeditor.configuration.excluded_paths = %w[node_modules tmp vendor/bundle]
      captured = nil
      singleton = class << ProcessRunner; self; end
      singleton.alias_method :__orig_call, :call
      ProcessRunner.define_singleton_method(:call) do |cmd, **opts|
        # Background threads (git polling, cache warm) may call ProcessRunner
        # concurrently — only capture the grep spawned by CodeSearchService.
        if cmd.first == "grep"
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

      assert_equal "grep", captured[:cmd].first
      assert_includes captured[:cmd], "--exclude-dir=node_modules"
      assert_includes captured[:cmd], "-I"
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
  end
end
