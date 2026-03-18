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
      File.write(File.join(@workspace, "nested_example.rb"), "class Demo\n    def call\nend")
      File.write(File.join(@workspace, "component.jsx"), "<div")
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

    test "ruby auto-end inserts nested closing line below the cursor line" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "nested_example.rb").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue(["class Demo", "    def call", "end"].join("\n"));
        editor.setPosition({ lineNumber: 2, column: editor.getModel().getLineMaxColumn(2) });
        editor.focus();
        window.MbeditorEditorPlugins.runRubyEnter(editor);
      JS

      expected = "class Demo\n    def call\n        \n    end\nend"
      wait_for_editor_value(expected)
      assert_equal({ "lineNumber" => 3, "column" => 9 }, active_editor_position)
    end

    test "jsx auto-close inserts matching closing tag and preserves inner cursor position" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue("<div");
        editor.setPosition({ lineNumber: 1, column: editor.getModel().getLineMaxColumn(1) });
        editor.focus();
        editor.trigger('keyboard', 'type', { text: '>' });
      JS

      wait_for_editor_value("<div></div>")
      assert_equal({ "lineNumber" => 1, "column" => 6 }, active_editor_position)
    end

    private

    def active_editor_value
      page.evaluate_script("window.__mbeditorActiveEditor && window.__mbeditorActiveEditor.getValue()")
    end

    def active_editor_position
      page.evaluate_script(<<~JS)
        (function () {
          var editor = window.__mbeditorActiveEditor;
          if (!editor) return null;
          var position = editor.getPosition();
          return position ? { lineNumber: position.lineNumber, column: position.column } : null;
        })()
      JS
    end

    def wait_for_editor_value(expected, timeout: Capybara.default_max_wait_time)
      deadline = Time.now + timeout
      loop do
        value = active_editor_value
        return if value == expected
        raise "Timed out waiting for editor value to become #{expected.inspect}; got #{value.inspect}" if Time.now >= deadline

        sleep 0.05
      end
    end
  end
end
