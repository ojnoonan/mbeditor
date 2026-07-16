# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  class TabActionsSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_tabs_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "a.rb"), "class A; end\n")
      File.write(File.join(@workspace, "b.rb"), "class B; end\n")
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      Capybara.reset_sessions!
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    # Files render as `.tree-item-name` rows in `.file-tree`. A single click opens
    # a file as a "soft"/preview tab that the next open replaces; double-clicking
    # hardens it into a persistent tab. Use double-click so multiple tabs coexist.
    def open_file(name)
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: name, minimum: 1).first.double_click
      assert_selector ".tab-item", text: name, wait: 10
    end

    # Expand a folder row (collapsed by default) so its children become visible.
    def expand_folder(name)
      all(".tree-item-name", text: name, minimum: 1).first.click
    end

    test "close others leaves only the clicked tab" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "a.rb").right_click
      find(".ide-tab-context-menu-item", text: "Close Others").click

      assert_selector ".tab-item", count: 1
      assert_selector ".tab-item", text: "a.rb"
    end

    test "close all clears the pane" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "b.rb").right_click
      find(".ide-tab-context-menu-item", text: "Close All").click

      assert_no_selector ".tab-item", wait: 10
    end

    test "plus button creates a new file in the active file's directory" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      expand_folder("app")
      expand_folder("models")
      open_file("user.rb") # under app/models

      find(".tab-new-file-btn").click

      input = find(".tree-item-inline-create input", wait: 10)
      input.set("helper.rb")
      input.send_keys(:enter)

      assert_selector ".tab-item", text: "helper.rb", wait: 10
      assert File.exist?(File.join(@workspace, "app", "models", "helper.rb"))
    end
  end
end
