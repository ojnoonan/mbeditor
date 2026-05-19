# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class JsDefinitionServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_js_def_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_js(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def call(symbol)
      JsDefinitionService.new(symbol, @workspace).call
    end

    # -------------------------------------------------------------------------
    # Result shape
    # -------------------------------------------------------------------------

    test "returns result with file, line, and snippet keys when symbol is found" do
      write_js("app/components/button.js", "function myButton() { return true; }")

      results = call("myButton")

      assert results.any?, "expected at least one result"
      result = results.first
      assert result.key?(:file),    "result must have :file key"
      assert result.key?(:line),    "result must have :line key"
      assert result.key?(:snippet), "result must have :snippet key"
    end

    # -------------------------------------------------------------------------
    # Symbol not found
    # -------------------------------------------------------------------------

    test "returns empty array when symbol is not present" do
      write_js("app/app.js", "function unrelatedThing() {}")

      results = call("noSuchSymbol")

      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # Workspace-relative paths
    # -------------------------------------------------------------------------

    test "file key is workspace-relative, not absolute" do
      write_js("src/utils/helper.js", "function myHelper() {}")

      results = call("myHelper")

      assert results.any?
      assert_equal "src/utils/helper.js", results.first[:file]
    end

    # -------------------------------------------------------------------------
    # MAX_RESULTS cap
    # -------------------------------------------------------------------------

    test "caps results at MAX_RESULTS" do
      25.times do |i|
        write_js("components/comp_#{i}.js", "function theWidget() {}")
      end

      results = call("theWidget")

      assert results.length <= JsDefinitionService::MAX_RESULTS
    end

    # -------------------------------------------------------------------------
    # build_pattern: function declaration
    # -------------------------------------------------------------------------

    test "matches function declaration form" do
      write_js("app.js", "function myFunc() { return 1; }")

      results = call("myFunc")

      assert results.any?, "expected function declaration to be matched"
      assert_includes results.first[:snippet], "myFunc"
    end

    # -------------------------------------------------------------------------
    # build_pattern: const/let/var assignment
    # -------------------------------------------------------------------------

    test "matches const assignment form" do
      write_js("app.js", "const myWidget = function() {};")

      results = call("myWidget")

      assert results.any?, "expected const assignment to be matched"
    end

    # -------------------------------------------------------------------------
    # build_pattern: window property assignment
    # -------------------------------------------------------------------------

    test "matches window property assignment form" do
      write_js("app.js", "window.myGlobal = function() {};")

      results = call("myGlobal")

      assert results.any?, "expected window.X = to be matched"
    end

    # -------------------------------------------------------------------------
    # build_pattern: plain usage is NOT returned
    # -------------------------------------------------------------------------

    test "does not return plain usages that are not definitions" do
      write_js("app.js", "myFunc();\nconsole.log(myFunc);")

      results = call("myFunc")

      assert_equal [], results
    end
  end
end
