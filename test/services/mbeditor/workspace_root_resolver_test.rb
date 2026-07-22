# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class WorkspaceRootResolverTest < Minitest::Test
    def teardown
      WorkspaceRootResolver.reset!
    end

    def test_configured_workspace_root_wins_and_is_not_memoized
      original = Mbeditor.configuration.workspace_root
      Mbeditor.configuration.workspace_root = "/tmp"

      assert_equal Pathname.new("/tmp"), WorkspaceRootResolver.call

      Mbeditor.configuration.workspace_root = "/var"
      assert_equal Pathname.new("/var"), WorkspaceRootResolver.call
    ensure
      Mbeditor.configuration.workspace_root = original
    end

    def test_git_resolution_is_memoized_across_calls
      original = Mbeditor.configuration.workspace_root
      Mbeditor.configuration.workspace_root = nil
      WorkspaceRootResolver.reset!

      singleton = class << Open3; self; end
      singleton.alias_method :__orig_capture3, :capture3
      call_count = 0
      ok = Object.new
      def ok.success? = true
      Open3.define_singleton_method(:capture3) do |*|
        call_count += 1
        ["/resolved/root\n", "", ok]
      end

      first = WorkspaceRootResolver.call
      second = WorkspaceRootResolver.call

      assert_equal Pathname.new("/resolved/root"), first
      assert_same first, second
      assert_equal 1, call_count
    ensure
      Mbeditor.configuration.workspace_root = original
      singleton.remove_method :capture3
      singleton.alias_method :capture3, :__orig_capture3
      singleton.remove_method :__orig_capture3
      WorkspaceRootResolver.reset!
    end

    def test_falls_back_to_rails_root_when_git_fails
      original = Mbeditor.configuration.workspace_root
      Mbeditor.configuration.workspace_root = nil
      WorkspaceRootResolver.reset!

      singleton = class << Open3; self; end
      singleton.alias_method :__orig_capture3, :capture3
      Open3.define_singleton_method(:capture3) do |*|
        raise Errno::ENOENT, "git"
      end

      assert_equal Rails.root, WorkspaceRootResolver.call
    ensure
      Mbeditor.configuration.workspace_root = original
      singleton.remove_method :capture3
      singleton.alias_method :capture3, :__orig_capture3
      singleton.remove_method :__orig_capture3
      WorkspaceRootResolver.reset!
    end

    def test_git_timeout_defaults_to_ten_seconds
      assert_equal 10, Configuration.new.git_timeout
    end
  end
end
