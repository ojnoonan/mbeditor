# frozen_string_literal: true

require "mbeditor/editor_bootstrap"

module Mbeditor
  module Rack
    # Catches ActiveRecord::PendingMigrationError for mbeditor routes so the
    # editor remains usable (e.g. to edit migration files) even when migrations
    # are pending. Non-mbeditor routes are unaffected and still raise normally.
    class HandlePendingMigrations
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue => e
        raise unless defined?(ActiveRecord::PendingMigrationError) && e.is_a?(ActiveRecord::PendingMigrationError)

        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        raise unless path.start_with?(Mbeditor::MountPath.resolve)

        if env["HTTP_X_MBEDITOR_CLIENT"] == "1"
          # XHR from the editor frontend — structured JSON error.
          # The frontend axios interceptor shows a banner on this response.
          body = JSON.generate(pending_migration_error: e.message.strip)
          [503, { "Content-Type" => "application/json" }, [body]]
        else
          # HTML page load. Serve the editor shell so devs can edit migration
          # files. Assets are referenced by their unfingerprinted paths, which
          # Sprockets resolves in development (the only env mbeditor runs in).
          # The banner appears as soon as the first XHR fires.
          #
          # The base comes from MountPath, not SCRIPT_NAME: this middleware runs
          # above the router, so SCRIPT_NAME is still "" and the engine-served
          # URLs in the shell (/monaco-editor/...) were emitted without the
          # mount prefix and 404'd.
          [200, { "Content-Type" => "text/html; charset=utf-8" }, [editor_shell_html(mount_base)]]
        end
      end

      private

      def mount_base
        Mbeditor::MountPath.resolve.to_s.sub(%r{/$}, "")
      rescue StandardError
        ""
      end

      def editor_shell_html(base)
        prettier_script_urls = %w[
          prettier-standalone.js
          prettier-plugin-babel.js
          prettier-plugin-estree.js
          prettier-plugin-html.js
          prettier-plugin-postcss.js
          prettier-plugin-markdown.js
        ].map { |f| "/assets/#{f}" }

        # Bootstrap JS shared with the standard layout — see Mbeditor::EditorBootstrap
        setup_js = Mbeditor::EditorBootstrap.setup_js(base)
        boot_js  = Mbeditor::EditorBootstrap.boot_js(
          base: base,
          prettier_script_urls: prettier_script_urls,
          application_js_url: "/assets/mbeditor/application.js"
        )

        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Mbeditor</title>
            <link rel="stylesheet" href="/assets/fontawesome.min.css" />
            <link rel="stylesheet" href="/assets/mbeditor/application.css" />
            <script defer src="/assets/react.min.js"></script>
            <script defer src="/assets/react-dom.min.js"></script>
            <script defer src="/assets/axios.min.js"></script>
            <script defer src="/assets/lodash.min.js"></script>
            <script defer src="/assets/minisearch.min.js"></script>
            <script defer src="/assets/marked.min.js"></script>
            <script defer src="/assets/emmet.js"></script>
            <script defer src="/assets/monaco-themes-bundle.js"></script>
            <link rel="stylesheet" href="#{base}/monaco-editor/monaco.css" />
          </head>
          <body>
            <script>#{setup_js}</script>
            <div id="mbeditor-root">
              <div id="mbeditor-loading">
                <div class="mbeditor-spinner"></div>
                <div class="mbeditor-loading-text">Loading editor&hellip;</div>
              </div>
            </div>
            <script>#{boot_js}</script>
          </body>
          </html>
        HTML
      end
    end
  end
end
