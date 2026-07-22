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

    test "search_respect_gitignore defaults to false" do
      assert_equal false, Mbeditor::Configuration.new.search_respect_gitignore
    end

    test "resilient_routing can be disabled" do
      config = Mbeditor::Configuration.new
      config.resilient_routing = false

      assert_equal false, config.resilient_routing
    end
  end
end
