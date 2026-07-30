# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class JsMembersServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_js_members_test_")
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
      JsMembersService.new(symbol, @workspace).call
    end

    # -------------------------------------------------------------------------
    # Result shape
    # -------------------------------------------------------------------------

    test "returns result with name and snippet keys when member is found" do
      write_js("app/app.js", "ReactWindow.open = function() {};")

      results = call("ReactWindow")

      assert results.any?, "expected at least one result"
      result = results.first
      assert result.key?(:name),    "result must have :name key"
      assert result.key?(:snippet), "result must have :snippet key"
    end
    # -------------------------------------------------------------------------
    # Symbol not found
    # -------------------------------------------------------------------------

    test "returns empty array when no members match" do
      write_js("app/app.js", "SomeOther.open = function() {};")

      results = call("ReactWindow")

      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # build_pattern: direct assignment
    # -------------------------------------------------------------------------

    test "name key contains the member name, not the full symbol" do
      write_js("app/app.js", "ReactWindow.open = function() {};")

      results = call("ReactWindow")

      assert_equal "open", results.first[:name]
    end

    # -------------------------------------------------------------------------
    # build_pattern: prototype assignment
    # -------------------------------------------------------------------------

    test "matches prototype assignment form" do
      write_js("app/app.js", "ReactWindow.prototype.close = function() {};")

      results = call("ReactWindow")

      assert results.any?, "expected prototype assignment to be matched"
      assert_equal "close", results.first[:name]
    end

    # -------------------------------------------------------------------------
    # Deduplication
    # -------------------------------------------------------------------------

    test "deduplicates member names across multiple files" do
      write_js("app/a.js", "ReactWindow.open = function() {};")
      write_js("app/b.js", "ReactWindow.open = function() {};")

      results = call("ReactWindow")

      names = results.map { |r| r[:name] }
      assert_equal 1, names.count("open"), "member name should appear once even across files"
      assert_equal names.uniq, names, "no duplicate names in results"
    end

    # -------------------------------------------------------------------------
    # MAX_RESULTS cap
    # -------------------------------------------------------------------------

    test "results carry the defining file and line for navigation" do
      write_js("app/widgets/react_window.js", "// header\nReactWindow.open = function() {};\n")

      results = call("ReactWindow")

      member = results.find { |r| r[:name] == "open" }
      assert member, "expected the member to be found"
      assert_equal "app/widgets/react_window.js", member[:file]
      assert_equal 2, member[:line]
    end

    test "caps results at MAX_RESULTS" do
      (JsMembersService::MAX_RESULTS + 5).times do |i|
        write_js("app/comp_#{i}.js", "ReactWindow.method#{i} = function() {};")
      end

      results = call("ReactWindow")

      assert results.length <= JsMembersService::MAX_RESULTS
    end
  end
end
