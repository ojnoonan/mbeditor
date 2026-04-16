# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  class EditorSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite

    def setup
      @workspace = Dir.mktmpdir("mbeditor_sys_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "README.md"), "# Hello\n")
      File.write(File.join(@workspace, "Gemfile"), "source \"https://rubygems.org\"\n")
      File.write(File.join(@workspace, "Gemfile.lock"), "GEM\n  specs:\n")
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      File.write(File.join(@workspace, "nested_example.rb"), "class Demo\n    def call\nend")
      File.write(File.join(@workspace, "component.jsx"), "<div")
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
      all(".tree-item-name", text: "README.md").first.click
      assert_selector ".monaco-editor", wait: 10
    end

    test "Gemfile and Gemfile.lock use ruby syntax" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      all(".tree-item-name", text: "Gemfile").first.click
      assert_selector ".monaco-editor", wait: 10
      assert_equal "ruby", active_editor_language

      all(".tree-item-name", text: "Gemfile.lock").first.click
      assert_selector ".monaco-editor", wait: 10
      assert_equal "ruby", active_editor_language
    end

    test "Ctrl+P opens the quick-open dialog" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find("body").send_keys([:control, "p"])
      assert_selector ".quick-open-overlay", wait: 5

      find(".quick-open-input").set("README")
      assert_selector ".quick-open-result-icon", wait: 5
      assert_selector ".quick-open-clear-btn", wait: 5

      find(".quick-open-clear-btn").click
      assert_equal "", find(".quick-open-input").value
    end

    test "sidebar search shows loading and clear controls" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find(".ide-sidebar-tab", text: "SEARCH").click

      page.execute_script(<<~'JS')
        window.SearchService.projectSearch = function () {
          return new Promise(function () {});
        };
      JS

      find(".search-input").set("README")
      assert_selector ".search-btn i.fa-spin", wait: 5
      assert_selector ".search-clear-btn", wait: 5

      find(".search-clear-btn").click
      assert_equal "", find(".search-input").value
      assert_no_selector ".search-btn i.fa-spin", wait: 5
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

    test "tab key does not collapse multi-line selections in jsx" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      result = page.evaluate_script(<<~'JS')
        (function () {
          var editor = window.__mbeditorActiveEditor;
          var monaco = window.monaco;
          editor.setValue(["<div>", "<span>", "</span>"].join("\n"));

          var model = editor.getModel();
          editor.setSelection(new monaco.Selection(1, 1, 3, model.getLineMaxColumn(3)));
          var action = editor.getAction('mbeditor.emmet.expandAbbreviation');
          if (action && action.run) action.run();

          return {
            lineCount: model.getLineCount(),
            line1: model.getLineContent(1),
            line2: model.getLineContent(2),
            line3: model.getLineContent(3)
          };
        })()
      JS

      assert_equal 3, result["lineCount"]
      assert_match(/^\s*<div>\z/, result["line1"])
      assert_match(/^\s*<span>\z/, result["line2"])
      assert_match(/^\s*<\/span>\z/, result["line3"])
    end

    test "git blame toggle renders inline annotations" do
      repo_root = File.expand_path("../../..", __dir__)
      previous_workspace = @workspace

      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root = repo_root
        c.excluded_paths = %w[.git tmp log node_modules vendor/bundle]
      end

      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: "README.md", minimum: 1).first.click
      assert_selector ".monaco-editor", wait: 10

      click_button "Blame"
      assert_text "Loaded blame for", wait: 10

      header_count = page.evaluate_script(<<~JS)
        (function () {
          return document.querySelectorAll('.ide-blame-block-header').length;
        })()
      JS
      assert_operator header_count.to_i, :>, 0
    ensure
      Mbeditor.configure do |c|
        c.workspace_root = previous_workspace
      end
    end

    test "git panel refresh button spins while refreshing" do
      repo_root = File.expand_path("../../..", __dir__)
      previous_workspace = @workspace

      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root = repo_root
        c.excluded_paths = %w[.git tmp log node_modules vendor/bundle]
      end

      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find("button", text: "Git").click
      assert_selector ".ide-git-right-panel", wait: 5

      page.execute_script(<<~'JS')
        window.GitService.fetchInfo = function () {
          return new Promise(function () {});
        };
      JS

      find("button[title='Refresh']").click
      assert_selector "button[title='Refresh'] i.fa-spin", wait: 5
    ensure
      Mbeditor.configure do |c|
        c.workspace_root = previous_workspace
      end
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

    def active_editor_language
      page.evaluate_script(<<~JS)
        (function () {
          var editor = window.__mbeditorActiveEditor;
          if (!editor || !editor.getModel) return null;
          var model = editor.getModel();
          return model ? model.getLanguageId() : null;
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
