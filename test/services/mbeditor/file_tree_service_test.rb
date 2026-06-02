# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class FileTreeServiceTest < Minitest::Test
    def setup
      @workspace = Dir.mktmpdir("mbeditor_tree_test_")
      Mbeditor.configure do |c|
        c.workspace_root   = @workspace
        c.excluded_paths   = []
      end
    end

    def teardown
      FileTreeService.reset!
      FileUtils.remove_entry(@workspace)
    end

    # --- .build: file nodes ---

    def test_build_returns_folder_node_with_children
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")

      tree = FileTreeService.build(@workspace)

      app = tree.find { |n| n[:name] == "app" }
      assert app, "expected an 'app' folder node"
      assert_equal "folder", app[:type]
      assert_equal "app",    app[:path]
      refute app.key?(:excluded)

      models = app[:children].find { |n| n[:name] == "models" }
      assert models
      user = models[:children].find { |n| n[:name] == "user.rb" }
      assert user
      assert_equal "app/models/user.rb", user[:path]
      assert_equal "file", user[:type]
    end

    # --- .build: exclusions ---

    def test_excluded_file_has_excluded_flag_and_no_size
      File.write(File.join(@workspace, "secret.log"), "x" * 100)
      Mbeditor.configure { |c| c.excluded_paths = ["secret.log"] }

      tree = FileTreeService.build(@workspace)

      node = tree.find { |n| n[:name] == "secret.log" }
      assert node
      assert_equal true, node[:excluded]
      refute node.key?(:size)
    end

    def test_excluded_directory_has_no_children_traversed
      FileUtils.mkdir_p(File.join(@workspace, "node_modules", "lodash"))
      File.write(File.join(@workspace, "node_modules", "lodash", "index.js"), "module.exports = {}")
      Mbeditor.configure { |c| c.excluded_paths = ["node_modules"] }

      tree = FileTreeService.build(@workspace)

      nm = tree.find { |n| n[:name] == "node_modules" }
      assert nm
      assert_equal true, nm[:excluded]
      assert_empty nm[:children]
    end

    # --- caching ---

    def test_build_returns_cached_result_without_re_traversing
      File.write(File.join(@workspace, "a.rb"), "a")

      first = FileTreeService.build(@workspace)

      # Mutate the workspace after the first call
      File.write(File.join(@workspace, "b.rb"), "b")

      second = FileTreeService.build(@workspace)

      assert_same first, second
      assert_equal 1, second.length
    end

    def test_invalidate_causes_next_build_to_re_traverse
      File.write(File.join(@workspace, "a.rb"), "a")
      FileTreeService.build(@workspace)

      File.write(File.join(@workspace, "b.rb"), "b")
      FileTreeService.invalidate(@workspace)

      tree = FileTreeService.build(@workspace)
      assert_equal 2, tree.length
    end

    def test_invalidate_returns_nil
      assert_nil FileTreeService.invalidate(@workspace)
    end

    def test_reset_clears_all_roots
      root2 = Dir.mktmpdir("mbeditor_tree_test2_")
      File.write(File.join(@workspace, "a.rb"), "a")
      File.write(File.join(root2, "x.rb"), "x")

      FileTreeService.build(@workspace)
      FileTreeService.build(root2)

      File.write(File.join(@workspace, "b.rb"), "b")
      File.write(File.join(root2, "y.rb"), "y")

      FileTreeService.reset!

      t1 = FileTreeService.build(@workspace)
      t2 = FileTreeService.build(root2)

      assert_equal 2, t1.length
      assert_equal 2, t2.length
    ensure
      FileUtils.remove_entry(root2)
    end

    def test_reset_returns_nil
      assert_nil FileTreeService.reset!
    end

    def test_build_returns_file_node_with_correct_fields
      File.write(File.join(@workspace, "hello.rb"), "puts 1\n")

      tree = FileTreeService.build(@workspace)

      assert_equal 1, tree.length
      node = tree.first
      assert_equal "hello.rb", node[:name]
      assert_equal "file",     node[:type]
      assert_equal "hello.rb", node[:path]
      assert_equal 7,          node[:size]
      refute node.key?(:excluded)
    end
  end
end
