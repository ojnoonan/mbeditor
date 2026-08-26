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
      File.write(File.join(@workspace, "HelloWidget.js.jsx"), <<~JSX)
        function HelloWidget(props) {
          var widgetLocalXyz = props.title;
          return <div>{widgetLocalXyz}</div>;
        }
      JSX
      File.write(File.join(@workspace, "App.js.jsx"), <<~JSX)
        function App() {
          return <HelloWidget title="hi" />;
        }
        var causesWarning = TotallyUndefinedSymbolXyz;
        implicitGlobalXyz = 42;
        var readsAnotherFilesLocal = widgetLocalXyz;
      JSX
      # Call-shape fixture: a component with a hand-written props contract, so
      # TypeScript has something real to check the call sites against.
      File.write(File.join(@workspace, "CallShapes.js.jsx"), <<~JSX)
        /**
         * @param {{ title: string, subtitle?: string }} props
         */
        function CardXyz(props) {
          return <div>{props.title}</div>;
        }
        function takesTwoXyz(a, b) {
          return a + b;
        }
        var fineCall    = takesTwoXyz(1, 2);
        var excessArgs  = takesTwoXyz(1, 2, 3);
        var fineProps   = <CardXyz title="ok" subtitle="s" />;
        var unknownProp = <CardXyz title="ok" bogusPropXyz={1} />;
        var missingProp = <CardXyz />;
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

    # Monaco MarkerSeverity: Error = 8, Warning = 4.
    #
    # "Cannot find name" is a Warning only while the workspace lookup is still
    # outstanding — host-app globals are invisible to the language service, so
    # an unresolved name is a question, not a verdict. Once the lookup reports
    # the name is defined nowhere, it is an Error like any other broken
    # reference. `widgetLocalXyz` is the case that used to produce no marker at
    # all: it exists on disk, but as a local inside a function in another file,
    # which the resolver mistook for a Sprockets global and declared ambient.
    test "an unknown read and an out-of-scope local are Errors once the lookup answers" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "App.js.jsx").click
      assert_selector ".monaco-editor", wait: 10

      markers = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 40
      loop do
        markers = page.evaluate_script(<<~'JS')
          (function () {
            if (!window.monaco) return null;
            return window.monaco.editor.getModelMarkers({ owner: 'javascript' })
              .map(function (m) { return { severity: m.severity, message: m.message }; });
          })()
        JS
        if markers.is_a?(Array) &&
           # The raw TS2304 lands before patchSeverities appends the hint, and it is
           # already severity 8 — so matching the name alone can break the loop on the
           # unpatched marker and fail the message assertion below. Wait for the
           # settled text instead; that is what "once the lookup answers" means.
           markers.any? { |m| m["message"].include?("implicitGlobalXyz") && m["message"].include?("implicit global") } &&
           markers.any? { |m| m["message"].include?("TotallyUndefinedSymbolXyz") && m["severity"] == 8 } &&
           markers.any? { |m| m["message"].include?("widgetLocalXyz") && m["severity"] == 8 }
          break
        end
        flunk "markers never settled; last: #{markers.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end

      implicit = markers.find { |m| m["message"].include?("implicitGlobalXyz") }
      assert_equal 8, implicit["severity"],
                   "expected the undeclared assignment to stay an Error, got: #{implicit.inspect}"
      assert_includes implicit["message"], "implicit global"

      # The cross-file component must not be dragged into the escalation.
      assert markers.none? { |m| m["message"].include?("HelloWidget") },
             "a real cross-file component must stay clean, got: #{markers.inspect}"
    end

    # Call-shape diagnostics are graded by what the mistake does at runtime:
    # an argument past the end of the parameter list is dropped and a prop the
    # component never reads is inert, so both are warnings; a required prop
    # that never arrives is undefined by the time the component reads it, so
    # that is an error. TypeScript folds the JSX cases into one code (2769),
    # which is why the grading reads the message rather than the code.
    test "excess arguments and unknown props warn while a missing required prop errors" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "CallShapes.js.jsx").click
      assert_selector ".monaco-editor", wait: 10

      markers = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 40
      loop do
        markers = page.evaluate_script(<<~'JS')
          (function () {
            if (!window.monaco) return null;
            return window.monaco.editor.getModelMarkers({ owner: 'javascript' })
              .map(function (m) { return { severity: m.severity, code: String(m.code && m.code.value || m.code || ''), message: m.message }; });
          })()
        JS
        break if markers.is_a?(Array) &&
                 markers.any? { |m| m["code"] == "2554" } &&
                 markers.count { |m| m["code"] == "2769" } >= 2

        flunk "call-shape markers never settled; last: #{markers.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end

      excess = markers.find { |m| m["code"] == "2554" }
      assert_equal 4, excess["severity"],
                   "an extra argument is dropped at runtime, so it should warn: #{excess.inspect}"

      unknown = markers.find { |m| m["message"].include?("bogusPropXyz") }
      assert unknown, "expected a diagnostic for the unknown prop, got: #{markers.inspect}"
      assert_equal 4, unknown["severity"],
                   "an unread prop is inert, so it should warn: #{unknown.inspect}"

      missing = markers.find { |m| m["message"].include?("is missing in type") }
      assert missing, "expected a diagnostic for the missing required prop, got: #{markers.inspect}"
      assert_equal 8, missing["severity"],
                   "a required prop that never arrives should error: #{missing.inspect}"

      # The correct call and the correct element are the control: enabling
      # these codes must not start flagging code that is fine.
      assert markers.none? { |m| m["message"].include?("takesTwoXyz(1, 2)") },
             "a matching call must stay clean, got: #{markers.inspect}"
    end
  end
end
