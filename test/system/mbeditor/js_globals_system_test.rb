# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  # End-to-end proof of the Sprockets-globals model: a component defined at
  # top level in one .js.jsx file is usable from another file with no import,
  # and Monaco shows no "Cannot find name" diagnostic for it — while a truly
  # undefined symbol in the same file still produces one (which proves the
  # TS worker actually validated the file).
  class JsGlobalsSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_jsglobals_sys_")
      File.write(File.join(@workspace, "HelloWidget.js.jsx"),
                 "function HelloWidget(props) {\n  return <div>{props.title}</div>;\n}\n")
      File.write(File.join(@workspace, "App.js.jsx"), <<~JSX)
        function App() {
          return <HelloWidget title="hi" />;
        }
        var causesWarning = TotallyUndefinedSymbolXyz;
      JSX
      JsGlobalsService.invalidate(@workspace)
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      Capybara.reset_sessions!
      JsGlobalsService.invalidate(@workspace)
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    test "cross-file .js.jsx component reference produces no Cannot-find-name marker" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "App.js.jsx").click
      assert_selector ".monaco-editor", wait: 10

      messages = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      loop do
        messages = page.evaluate_script(<<~'JS')
          (function () {
            if (!window.monaco) return null;
            return window.monaco.editor.getModelMarkers({ owner: 'javascript' })
              .map(function (m) { return String(m.code) + '|' + m.message; });
          })()
        JS
        # Validation has demonstrably run once the intentionally-undefined
        # symbol is flagged; HelloWidget must be clean by then (or shortly
        # after the workspace-globals extraLib triggers revalidation).
        if messages.is_a?(Array) &&
           messages.any? { |m| m.include?("TotallyUndefinedSymbolXyz") } &&
           messages.none? { |m| m.include?("HelloWidget") }
          break
        end
        flunk "markers never settled; last: #{messages.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end

      assert messages.any? { |m| m.include?("TotallyUndefinedSymbolXyz") },
             "expected a marker for the truly undefined symbol"
      assert messages.none? { |m| m.include?("HelloWidget") },
             "expected no marker for the cross-file component, got: #{messages.inspect}"
    end
  end
end
