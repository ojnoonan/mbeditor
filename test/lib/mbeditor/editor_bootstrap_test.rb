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

    # A cached rejected promise disabled Format for the rest of the session, and
    # restoring window.define from one script's onerror let siblings still in
    # flight register as AMD modules instead of setting their globals.
    test "boot_js lets a failed Prettier load be retried" do
      js = boot_js

      assert_includes js, "window._prettierLoadPromise = null;"
      assert_includes js, "if (--pending > 0) return;"
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

    # Sprockets serves at /assets, not under the engine mount, so a prefixed
    # asset URL 404s and the fallback shell renders without CSS or JS. Only the
    # engine-served /monaco-editor URLs carry the mount prefix.
    test "the fallback shell points asset URLs at Sprockets, not the engine mount" do
      html = Mbeditor::Rack::HandlePendingMigrations.new(nil).send(:editor_shell_html, BASE)

      refute_includes html, "#{BASE}/assets/"
      assert_includes html, %(href="/assets/mbeditor/application.css")
      assert_includes html, %(appScript.src = "/assets/mbeditor/application.js";)
      assert_includes html, %(var prettierScripts = ["/assets/prettier-standalone.js")
      assert_includes html, "#{BASE}/monaco-editor/monaco.css"
    end
  end
end
