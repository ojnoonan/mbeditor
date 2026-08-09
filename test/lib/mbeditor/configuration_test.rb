# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ConfigurationTest < ActiveSupport::TestCase
    test "resilient_routing defaults to true" do
      assert_equal true, Mbeditor::Configuration.new.resilient_routing
    end

    test "search_timeout defaults to 15 seconds" do
      assert_equal 15, Mbeditor::Configuration.new.search_timeout
    end

    # Defaulting to true keeps git off --no-index, which walks every ignored
    # tree in the workspace. On the git-grep tier that is the difference
    # between a usable search and an unusable one.
    test "search_respect_gitignore defaults to true" do
      assert_equal true, Mbeditor::Configuration.new.search_respect_gitignore
    end

    test "ripgrep_command defaults to nil so the probe auto-resolves it" do
      assert_nil Mbeditor::Configuration.new.ripgrep_command
    end

    test "resilient_routing can be disabled" do
      config = Mbeditor::Configuration.new
      config.resilient_routing = false

      assert_equal false, config.resilient_routing
    end
  end
end
