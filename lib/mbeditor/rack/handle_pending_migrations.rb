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
        prettier_scripts = %w[
          prettier-standalone.js
          prettier-plugin-babel.js
          prettier-plugin-estree.js
          prettier-plugin-html.js
          prettier-plugin-postcss.js
          prettier-plugin-markdown.js
        ].map { |f| "#{base}/assets/#{f}" }.to_json

        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Mbeditor</title>
            <link rel="stylesheet" href="#{base}/assets/fontawesome.min.css" />
            <link rel="stylesheet" href="#{base}/assets/mbeditor/application.css" />
            <script defer src="#{base}/assets/react.min.js"></script>
            <script defer src="#{base}/assets/react-dom.min.js"></script>
            <script defer src="#{base}/assets/axios.min.js"></script>
            <script defer src="#{base}/assets/lodash.min.js"></script>
            <script defer src="#{base}/assets/minisearch.min.js"></script>
            <script defer src="#{base}/assets/marked.min.js"></script>
            <script defer src="#{base}/assets/emmet.js"></script>
            <script defer src="#{base}/assets/monaco-themes-bundle.js"></script>
            <script>var require = { paths: { vs: '#{base}/monaco-editor/vs', 'monaco-editor/esm/vs': '#{base}/monaco-editor/vs', 'monaco-vim': '#{base}/assets/monaco-vim' } };</script>
            <script src="#{base}/monaco-editor/vs/loader.js"></script>
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
            <script>
              window.MonacoEnvironment = {
                getWorkerUrl: function(workerId, label) {
                  var b = window.MBEDITOR_BASE_PATH || '';
                  if (label === 'typescript' || label === 'javascript') return b + '/ts_worker.js';
                  return b + '/monaco_worker.js';
                }
              };
              (function() {
                var _define = window.define;
                window.define = undefined;

                var prettierScripts = #{prettier_scripts};
                window.loadPrettierPlugins = function() {
                  if (window._prettierLoadPromise) return window._prettierLoadPromise;
                  window._prettierLoadPromise = new Promise(function(resolve, reject) {
                    var savedDefine = window.define;
                    window.define = undefined;
                    var pending = prettierScripts.length;
                    prettierScripts.forEach(function(src) {
                      var s = document.createElement('script');
                      s.src = src;
                      s.onload = function() { if (--pending === 0) { window.define = savedDefine; resolve(); } };
                      s.onerror = function() { window.define = savedDefine; reject(new Error('Failed to load Prettier: ' + src)); };
                      document.head.appendChild(s);
                    });
                  });
                  return window._prettierLoadPromise;
                };

                function proceed() {
                  window.MbeditorRuntime = { React: window.React, ReactDOM: window.ReactDOM };
                  window.React    = window._mbeditorHostReact;
                  window.ReactDOM = window._mbeditorHostReactDOM;
                  window.define = _define;

                  var _monacoResolve;
                  window.__monacoReady = new Promise(function(resolve) { _monacoResolve = resolve; });

                  var appScript = document.createElement('script');
                  appScript.src = '#{base}/assets/mbeditor/application.js';
                  appScript.onload = function() {
                    var root = document.getElementById('mbeditor-root');
                    var _R = window.MbeditorRuntime.React, _RD = window.MbeditorRuntime.ReactDOM;
                    if (window.MbeditorApp && _R && _RD) _RD.render(_R.createElement(window.MbeditorApp), root);
                  };
                  appScript.onerror = function() {
                    document.getElementById('mbeditor-root').innerHTML =
                      '<div style="padding:2rem;font-family:sans-serif;color:#c00">Editor failed to load. Please refresh the page.</div>';
                  };
                  document.body.appendChild(appScript);

                  require(['vs/editor/editor.main'], function() {
                    if (window.MBEDITOR_CUSTOM_THEMES && window.monaco) {
                      Object.keys(window.MBEDITOR_CUSTOM_THEMES).forEach(function(id) {
                        window.monaco.editor.defineTheme(id, window.MBEDITOR_CUSTOM_THEMES[id]);
                      });
                    }
                    _monacoResolve();
                  });
                }

                if (window._mbeditorDOMReady) proceed();
                else document.addEventListener('DOMContentLoaded', proceed, { once: true });
              })();
            </script>
          </body>
          </html>
        HTML
      end
    end
  end
end
