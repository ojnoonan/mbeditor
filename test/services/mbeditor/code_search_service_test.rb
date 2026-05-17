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
  end
end
