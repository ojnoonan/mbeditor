# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class EditorBootstrapTest < ActiveSupport::TestCase
    BASE = "/mbeditor"

    def boot_js
      Mbeditor::EditorBootstrap.boot_js(
        base: BASE,
        prettier_script_urls: ["#{BASE}/assets/prettier-standalone.js"],
        application_js_url: "#{BASE}/assets/mbeditor/application.js"
      )
    end

    test "setup_js embeds the base path as a JSON string" do
      js = Mbeditor::EditorBootstrap.setup_js(BASE)

      assert_includes js, %(window.MBEDITOR_BASE_PATH = "/mbeditor";)
      assert_includes js, "window._mbeditorDOMReady = false;"
    end

    test "boot_js wires every Monaco worker label" do
      js = boot_js

      %w[editor.worker.js json.worker.js css.worker.js html.worker.js ts.worker.js].each do |worker|
        assert_includes js, worker
      end
    end

    test "boot_js embeds the artifact and script URLs as JSON strings" do
      js = boot_js

      assert_includes js, %(monacoScript.src = "/mbeditor/monaco-editor/monaco.js";)
      assert_includes js, %(s.src = "/mbeditor/monaco-editor/monaco-vim.js";)
      assert_includes js, %(appScript.src = "/mbeditor/assets/mbeditor/application.js";)
      assert_includes js, %(var prettierScripts = ["/mbeditor/assets/prettier-standalone.js"];)
    end

    test "boot_js handles load failures for both the Monaco bundle and monaco-vim" do
      js = boot_js

      assert_includes js, "monacoScript.onerror"
      assert_includes js, "window._monacoVimPromise = null;"
    end

    test "embedded values cannot terminate the inline script element" do
      js = Mbeditor::EditorBootstrap.setup_js("/evil</script><script>")

      refute_includes js, "</script>"
    end

    test "pending-migrations fallback shell embeds the shared bootstrap" do
      html = Mbeditor::Rack::HandlePendingMigrations.new(nil).send(:editor_shell_html, BASE)

      assert_includes html, %(window.MBEDITOR_BASE_PATH = "/mbeditor";)
      assert_includes html, "window.MonacoEnvironment"
      assert_includes html, %(monacoScript.src = "/mbeditor/monaco-editor/monaco.js";)
      # The fallback must keep parity with the layout's error handling.
      assert_includes html, "monacoScript.onerror"
      assert_includes html, "window._monacoVimPromise = null;"
    end
  end
end
