# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Mbeditor
  class FileWatcherTest < ActiveSupport::TestCase
    def setup
      @root = Dir.mktmpdir("mbeditor_watcher_")
      FileWatcher.stop
    end

    def teardown
      FileWatcher.stop
      FileUtils.rm_rf(@root)
      Mbeditor.configure { |c| c.watch_files = :auto }
    end

    test "start_if_enabled declines when the host disabled watching" do
      Mbeditor.configure { |c| c.watch_files = false }

      assert_equal false, FileWatcher.start_if_enabled
      assert_equal false, FileWatcher.running?
    end

    test "start_if_enabled declines outside the allowed environments" do
      original = Mbeditor.configuration.allowed_environments
      Mbeditor.configure { |c| c.allowed_environments = [:production] }

      assert_equal false, FileWatcher.start_if_enabled
    ensure
      Mbeditor.configure { |c| c.allowed_environments = original }
    end

    test "start declines a root that is not a directory" do
      assert_equal false, FileWatcher.start(File.join(@root, "does-not-exist"))
      assert_equal false, FileWatcher.running?
    end

    test "excluded paths become anchored patterns that listen can match" do
      # Pinned rather than read from the live default: other suites narrow
      # excluded_paths for their own fixtures, and this is asserting how a
      # pattern is built, not what the shipped default happens to contain.
      original = Mbeditor.configuration.excluded_paths
      Mbeditor.configure { |c| c.excluded_paths = %w[.git tmp node_modules vendor/bundle] }

      patterns = FileWatcher.send(:ignore_patterns, @root)
      combined = ->(path) { patterns.any? { |p| p.match?(path) } }

      assert combined.call(".git/HEAD")
      assert combined.call("node_modules/left-pad/index.js")
      assert combined.call("vendor/bundle/ruby/gems/foo.rb")
      assert combined.call("tmp")
      refute combined.call("app/models/user.rb")
      refute combined.call("app/tmpfile.rb"), "must anchor at the path root, not match mid-string"
      refute combined.call("mytmp/file.rb")
    ensure
      Mbeditor.configure { |c| c.excluded_paths = original }
    end

    test "an exclusion containing regex metacharacters is escaped, not interpreted" do
      original = Mbeditor.configuration.excluded_paths
      Mbeditor.configure { |c| c.excluded_paths = ["a.b+c"] }

      patterns = FileWatcher.send(:ignore_patterns, @root)
      assert patterns.first.match?("a.b+c/thing.rb")
      refute patterns.first.match?("axbxc/thing.rb"), "the dot must be literal"
    ensure
      Mbeditor.configure { |c| c.excluded_paths = original }
    end

    test "changed paths are reported relative to the workspace" do
      paths = [File.join(@root, "app/models/user.rb"), File.join(@root, "README.md")]

      assert_equal ["app/models/user.rb", "README.md"], FileWatcher.send(:relative_paths, @root, paths)
    end

    test "a path outside the workspace is dropped rather than reported raw" do
      paths = ["/somewhere/else/file.rb", @root, File.join(@root, "kept.rb")]

      assert_equal ["kept.rb"], FileWatcher.send(:relative_paths, @root, paths),
                   "an unrelatable path must not leak host layout to the client"
    end

    test "a raising cache invalidation does not propagate out of the watcher callback" do
      original = FileWatcher.method(:invalidate_caches)
      FileWatcher.define_singleton_method(:invalidate_caches) { |_root| raise "boom" }

      assert_nothing_raised do
        FileWatcher.send(:broadcast, @root, [File.join(@root, "a.rb")])
      end
    ensure
      FileWatcher.singleton_class.send(:remove_method, :invalidate_caches)
      FileWatcher.define_singleton_method(:invalidate_caches, original)
      FileWatcher.singleton_class.send(:private, :invalidate_caches)
    end
  end
end
