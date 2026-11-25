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

    test "close others leaves only the clicked tab" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "a.rb").right_click
      find(".ide-tab-context-menu .context-menu-item", text: "Close Others").click

      assert_selector ".tab-item", count: 1
      assert_selector ".tab-item", text: "a.rb"
    end

    test "close all clears the pane" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "b.rb").right_click
      find(".ide-tab-context-menu .context-menu-item", text: "Close All").click

      assert_no_selector ".tab-item", wait: 10
    end

    # Keys go through the page keyboard, which types into whatever has focus;
    # a node's send_keys would click it first and move focus itself.
    def press(*keys)
      page.driver.browser.keyboard.type(*keys)
    end

    def focused_menu_item
      page.evaluate_script(<<~JS)
        (function () {
          var el = document.activeElement;
          return el && el.classList.contains('context-menu-item') ? el.textContent.trim() : null;
        })()
      JS
    end

    def wait_for_condition(description, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = yield
        return result if result
        raise "Timed out waiting for #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

    def assert_focused_item(label)
      assert wait_for_condition("focus on the #{label} menu item") { focused_menu_item == label || nil },
             "focused menu item is #{focused_menu_item.inspect}, expected #{label.inspect}"
    end

    test "the explorer context menu works from the keyboard" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item[data-path='a.rb']").click

      press([:shift, :f10])
      assert_selector ".context-menu:popover-open", wait: 5
      assert_focused_item "Open"
      press(:down)
      assert_focused_item "New File"
      press(:end)
      assert_focused_item "Copy Path"
      press(:down) # wraps
      assert_focused_item "Open"
      press(:up)   # wraps back
      assert_focused_item "Copy Path"
      press(:home)
      assert_focused_item "Open"

      # Esc closes it and hands focus back to the tree.
      press(:escape)
      assert_no_selector ".context-menu", wait: 5
      assert wait_for_condition("focus back on the file tree") {
        page.evaluate_script("document.activeElement && document.activeElement.classList.contains('file-tree')") || nil
      }

      # Enter runs the focused item.
      press([:shift, :f10])
      assert_focused_item "Open"
      press(:enter)
      assert_no_selector ".context-menu", wait: 5
      assert_selector ".tab-item:not(.tab-soft)", text: "a.rb", wait: 10
    end

    test "a pointer-opened tab menu is entered with the first arrow key" do
      visit "/mbeditor"
      open_file("a.rb")
      open_file("b.rb")
      assert_selector ".tab-item", count: 2, wait: 10

      find(".tab-item", text: "a.rb").right_click
      assert_selector ".ide-tab-context-menu:popover-open", wait: 5
      assert_nil focused_menu_item, "a pointer open must not focus an item"
      press(:down)
      assert_focused_item "Close"
      press(:down)
      assert_focused_item "Close Others"
      press(:enter)

      assert_selector ".tab-item", count: 1, wait: 10
      assert_selector ".tab-item", text: "a.rb"
    end

    test "plus button opens an untitled scratch tab, and saving converts it to a real file" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      open_file("a.rb")

      find(".tab-new-file-btn").click

      # A scratch buffer opens immediately; nothing is written to disk.
      assert_selector ".tab-item", text: "Untitled-1", wait: 10
      assert_empty Dir.glob(File.join(@workspace, "Untitled*"))

      # Saving asks for a path in the Save as dialog and converts the tab.
      find(".monaco-editor .view-lines").click
      page.send_keys("scratch content")
      find("button.statusbar-btn[title^='Save the active file']").click
      within("dialog.mb-dialog", wait: 10) do
        find("input.import-dest-input").set("scratch.txt")
        click_button "Save"
      end

      assert_selector ".tab-item", text: "scratch.txt", wait: 10
      assert_no_selector ".tab-item", text: "Untitled-1"
      assert_equal "scratch content", File.read(File.join(@workspace, "scratch.txt")).strip
    end
  end
end
