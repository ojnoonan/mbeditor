# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  # Ruby intelligence inside ERB templates: active within <% %> tags, inert in
  # the surrounding HTML. Asserts go-to-definition (a tab opens — deterministic)
  # rather than hover-tooltip timing.
  class ErbIntellisenseSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_erb_sys_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "helpers"))
      File.write(File.join(@workspace, "app", "helpers", "theme_helper.rb"), <<~RUBY)
        module ThemeHelper
          def theme_badge(theme)
            theme.to_s
          end
        end
      RUBY
      File.write(File.join(@workspace, "page.html.erb", ), <<~ERB)
        <h1>Themes</h1>
        <div class="wrap">
          <%= theme_badge(theme) %>
        </div>
        <%
          multi = 1
        %>
      ERB

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

    test "ERB context detection distinguishes tag interiors from the HTML body" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "page.html.erb").click
      assert_selector ".monaco-editor", wait: 10

      probe = page.evaluate_script(<<~'JS')
        (function () {
          var content = document.querySelector('.monaco-editor')
            ? window.__mbeditorActiveEditor.getModel().getValue() : '';
          var m = window.monaco.editor.createModel(content, 'erb');
          var f = window.MbeditorEditorPlugins.isInsideErbTag;
          var res = {
            insideOutputTag: f(m, { lineNumber: 3, column: 9 }),
            inHtmlHeading:   f(m, { lineNumber: 1, column: 5 }),
            insideMultiLine: f(m, { lineNumber: 6, column: 5 }),
            afterClosingTag: f(m, { lineNumber: 4, column: 3 })
          };
          m.dispose();
          return res;
        })()
      JS

      assert_equal true,  probe["insideOutputTag"], "cursor inside <%= %> is Ruby context"
      assert_equal true,  probe["insideMultiLine"], "a multi-line <% %> block is Ruby context"
      assert_equal false, probe["inHtmlHeading"], "plain HTML is not Ruby context"
      assert_equal false, probe["afterClosingTag"], "text after %> is not Ruby context"
    end

    test "the ERB file opens with the erb language and Ruby providers attached" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "page.html.erb").click
      assert_selector ".monaco-editor", wait: 10

      assert_equal "erb", page.evaluate_script("window.__mbeditorActiveEditor.getModel().getLanguageId()")

      # Put the cursor on `theme_badge` inside <%= %> and run the Ruby
      # go-to-definition action. A tab opening for the helper is a
      # deterministic DOM change (unlike hover-tooltip timing) and proves the
      # ERB document reached the workspace definition services.
      page.execute_script(<<~'JS')
        var ed = window.__mbeditorActiveEditor;
        ed.setPosition({ lineNumber: 3, column: 9 });
        ed.focus();
        ed.getAction('mbeditor.gotoRubyDefinition').run();
      JS

      assert_selector ".tab-item", text: "theme_helper.rb", wait: 10
    end
  end
end
