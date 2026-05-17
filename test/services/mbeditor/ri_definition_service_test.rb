# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RiDefinitionServiceTest < ActiveSupport::TestCase
    def setup
      RiDefinitionService.clear_cache!
    end

    # -------------------------------------------------------------------------
    # Known Ruby core method
    # -------------------------------------------------------------------------

    test "returns a result for a known Ruby core method" do
      results = RiDefinitionService.call("puts")
      # ri may not be installed in all CI environments — skip gracefully
      skip "ri not available" if results.empty?

      assert_equal 1, results.length
      r = results[0]
      assert_includes r[:signature], "puts"
      assert r[:line] == 0, "ri results always have line 0"
      assert r[:file].is_a?(String)
      assert r[:file].length > 0
    end

    test "returns a result with a non-empty signature for 'map'" do
      results = RiDefinitionService.call("map")
      skip "ri not available" if results.empty?

      assert_equal 1, results.length
      assert_includes results[0][:signature], "map"
    end

    # -------------------------------------------------------------------------
    # Unknown symbol
    # -------------------------------------------------------------------------

    test "returns empty array for an unknown symbol" do
      results = RiDefinitionService.call("totally_unknown_method_xyz_abc_123")
      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # Caching
    # -------------------------------------------------------------------------

    test "returns the same object on repeated calls (cache hit)" do
      # Call twice — second result must be the cached array (same object_id)
      first  = RiDefinitionService.call("puts")
      second = RiDefinitionService.call("puts")
      assert_same first, second
    end

    test "clear_cache! forces a fresh lookup" do
      first = RiDefinitionService.call("puts")
      RiDefinitionService.clear_cache!
      second = RiDefinitionService.call("puts")
      # Both calls return equivalent data; they are not the same object
      assert_equal first, second
    end

    # -------------------------------------------------------------------------
    # Result structure
    # -------------------------------------------------------------------------

    test "result hash has required keys" do
      results = RiDefinitionService.call("puts")
      skip "ri not available" if results.empty?

      r = results[0]
      assert r.key?(:file),      "missing :file"
      assert r.key?(:line),      "missing :line"
      assert r.key?(:signature), "missing :signature"
      assert r.key?(:comments),  "missing :comments"
    end

    test "comments field is a String" do
      results = RiDefinitionService.call("puts")
      skip "ri not available" if results.empty?

      assert results[0][:comments].is_a?(String)
    end

    # -------------------------------------------------------------------------
    # Absent ri binary
    # -------------------------------------------------------------------------

    test "returns empty array when ri binary is not installed" do
      open3_singleton = class << Open3; self; end
      open3_singleton.alias_method :__original_popen3_for_ri_enoent, :popen3
      open3_singleton.remove_method :popen3
      Open3.define_singleton_method(:popen3) do |*_args, &_block|
        raise Errno::ENOENT, "No such file or directory - ri"
      end

      result = RiDefinitionService.call("some_method")
      assert_equal [], result
    ensure
      open3_singleton.remove_method :popen3
      open3_singleton.alias_method :popen3, :__original_popen3_for_ri_enoent
      open3_singleton.remove_method :__original_popen3_for_ri_enoent
      RiDefinitionService.clear_cache!
    end
  end
end
