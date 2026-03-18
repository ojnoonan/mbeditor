# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  class EditorSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite

    def setup
      @workspace = Dir.mktmpdir("mbeditor_sys_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "README.md"), "# Hello\n")
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root = @workspace
        c.excluded_paths = %w[.git tmp log]
      end
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    test "page loads and React mounts" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
    end

    test "file tree shows workspace files" do
      visit "/mbeditor"
      assert_text "README.md", wait: 10
    end

    test "clicking a file opens it in the editor" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "README.md").click
      assert_selector ".monaco-editor", wait: 10
    end

    test "Ctrl+P opens the quick-open dialog" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find("body").send_keys([:control, "p"])
      assert_selector ".quick-open-overlay", wait: 5
    end

    test "server-online heartbeat shows no offline indicator" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      assert_no_selector ".statusbar-offline"
    end
  end
end
