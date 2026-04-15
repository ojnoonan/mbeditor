# frozen_string_literal: true

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
        raise unless path.start_with?("/mbeditor")

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
          base = env["SCRIPT_NAME"].to_s.sub(%r{/$}, "")
          [200, { "Content-Type" => "text/html; charset=utf-8" }, [editor_shell_html(base)]]
        end
      end

      private

      def editor_shell_html(base)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Mbeditor</title>
            <link rel="stylesheet" href="#{base}/assets/fontawesome.min.css" />
            <link rel="stylesheet" href="#{base}/assets/mbeditor/application.css" />
          </head>
          <body>
            <script>
              window.MBEDITOR_BASE_PATH = #{base.to_json};
              window._mbeditorHostReact    = window.React;
              window._mbeditorHostReactDOM = window.ReactDOM;
              window._mbeditorDOMReady = false;
              document.addEventListener('DOMContentLoaded', function() { window._mbeditorDOMReady = true; }, { once: true });
            </script>
            <div id="mbeditor-root">
              <div id="mbeditor-loading">
                <div class="mbeditor-spinner"></div>
                <div class="mbeditor-loading-text">Loading editor&hellip;</div>
              </div>
            </div>
            <script defer src="#{base}/assets/react.min.js"></script>
            <script defer src="#{base}/assets/react-dom.min.js"></script>
            <script defer src="#{base}/assets/axios.min.js"></script>
            <script defer src="#{base}/assets/lodash.min.js"></script>
            <script defer src="#{base}/assets/minisearch.min.js"></script>
            <script defer src="#{base}/assets/marked.min.js"></script>
            <script defer src="#{base}/assets/emmet.js"></script>
            <script defer src="#{base}/assets/monaco-themes-bundle.js"></script>
            <script>
              window.MonacoEnvironment = {
                getWorkerUrl: function(workerId, label) {
                  if (label === 'typescript' || label === 'javascript') return '#{base}/ts_worker.js';
                  return '#{base}/monaco_worker.js';
                }
              };
              var require = { paths: { vs: '#{base}/monaco-editor/vs', 'monaco-editor/esm/vs': '#{base}/monaco-editor/vs', 'monaco-vim': '#{base}/assets/monaco-vim' } };
            </script>
            <script src="#{base}/monaco-editor/vs/loader.js"></script>
            <script>
              (function() {
                var prettierScripts = [
                  '#{base}/assets/prettier-standalone.js',
                  '#{base}/assets/prettier-plugin-babel.js',
                  '#{base}/assets/prettier-plugin-estree.js',
                  '#{base}/assets/prettier-plugin-html.js',
                  '#{base}/assets/prettier-plugin-postcss.js',
                  '#{base}/assets/prettier-plugin-markdown.js'
                ];
                var _define = window.define;
                window.define = undefined;
                var pending = prettierScripts.length;
                function onAllPrettierLoaded() {
                  function proceed() {
                    window.MbeditorRuntime = { React: window.React, ReactDOM: window.ReactDOM };
                    window.React    = window._mbeditorHostReact;
                    window.ReactDOM = window._mbeditorHostReactDOM;
                    window.define = _define;
                    require(['vs/editor/editor.main'], function() {
                      if (window.MBEDITOR_CUSTOM_THEMES && window.monaco) {
                        Object.keys(window.MBEDITOR_CUSTOM_THEMES).forEach(function(id) {
                          window.monaco.editor.defineTheme(id, window.MBEDITOR_CUSTOM_THEMES[id]);
                        });
                      }
                      var s = document.createElement('script');
                      s.src = '#{base}/assets/mbeditor/application.js';
                      s.onload = function() {
                        var root = document.getElementById('mbeditor-root');
                        var _R = window.MbeditorRuntime.React, _RD = window.MbeditorRuntime.ReactDOM;
                        if (window.MbeditorApp && _R && _RD) _RD.render(_R.createElement(window.MbeditorApp), root);
                      };
                      document.body.appendChild(s);
                    });
                  }
                  if (window._mbeditorDOMReady) proceed();
                  else document.addEventListener('DOMContentLoaded', proceed, { once: true });
                }
                prettierScripts.forEach(function(src) {
                  var s = document.createElement('script');
                  s.src = src;
                  s.onload = function() { if (--pending === 0) onAllPrettierLoaded(); };
                  document.head.appendChild(s);
                });
              })();
            </script>
          </body>
          </html>
        HTML
      end
    end
  end
end
