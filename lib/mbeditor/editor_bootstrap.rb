# frozen_string_literal: true

require "erb"

module Mbeditor
  # Generates the inline bootstrap JavaScript shared by the standard editor
  # layout (app/views/layouts/mbeditor/application.html.erb) and the
  # pending-migrations fallback shell (Mbeditor::Rack::HandlePendingMigrations).
  # Both pages must boot the editor identically; keeping the script bodies here
  # is what stops the two copies drifting apart.
  module EditorBootstrap
    module_function

    # Early <script> body — must run before the deferred vendor scripts so the
    # host app's React can be snapshotted and restored later.
    def setup_js(base)
      <<~JS
        window.MBEDITOR_BASE_PATH = #{js(base)};
        // Snapshot any React the host app may already have before our deferred scripts run.
        window._mbeditorHostReact    = window.React;
        window._mbeditorHostReactDOM = window.ReactDOM;
        // Set by DOMContentLoaded, which fires after all deferred scripts have executed.
        window._mbeditorDOMReady = false;
        document.addEventListener('DOMContentLoaded', function() { window._mbeditorDOMReady = true; }, { once: true });
      JS
    end

    # Main <script> body — Monaco worker wiring, lazy Prettier/monaco-vim
    # loaders, and the deferred app + Monaco bundle boot (ADR 0002).
    def boot_js(base:, prettier_script_urls:, application_js_url:)
      <<~JS
        window.MonacoEnvironment = {
          getWorker: function(_workerId, label) {
            var base = (window.MBEDITOR_BASE_PATH || '') + '/monaco-editor/';
            var file = 'editor.worker.js';
            if (label === 'json') file = 'json.worker.js';
            else if (label === 'css' || label === 'scss' || label === 'less') file = 'css.worker.js';
            else if (label === 'html' || label === 'handlebars' || label === 'razor') file = 'html.worker.js';
            else if (label === 'typescript' || label === 'javascript') file = 'ts.worker.js';
            return new Worker(base + file);
          }
        };

        // Hide window.define before deferred vendor scripts (React, ReactDOM, etc.) execute
        // so their UMD wrappers set window globals instead of registering as AMD modules.
        // Prettier is loaded lazily on first Format action via window.loadPrettierPlugins().
        (function() {
          var _define = window.define;
          window.define = undefined;

          // Expose lazy Prettier loader — called on first Format action.
          // Temporarily hides window.define so Prettier's UMD wrapper sets
          // window.prettier / window.prettierPlugins instead of using AMD.
          var prettierScripts = #{js(prettier_script_urls)};

          window.loadPrettierPlugins = function() {
            if (window._prettierLoadPromise) return window._prettierLoadPromise;
            var promise = new Promise(function(resolve, reject) {
              var savedDefine = window.define;
              window.define = undefined;
              var pending = prettierScripts.length;
              var failed = null;
              // Restore window.define only once every script has settled: an
              // early restore let a sibling still in flight register as an AMD
              // module instead of setting its window global.
              function settle() {
                if (--pending > 0) return;
                window.define = savedDefine;
                if (failed) reject(new Error('Failed to load Prettier: ' + failed));
                else resolve();
              }
              prettierScripts.forEach(function(src) {
                var s = document.createElement('script');
                s.src = src;
                s.onload = settle;
                s.onerror = function() { failed = failed || src; settle(); };
                document.head.appendChild(s);
              });
            });
            window._prettierLoadPromise = promise;
            // Clear the cached promise so the next Format action retries the
            // load; caching a rejection disabled Format for the whole session.
            promise.catch(function() { window._prettierLoadPromise = null; });
            return promise;
          };

          // Lazy-load monaco-vim on first use. Drop-in for the old AMD
          // `require(['monaco-vim'], cb)`: invokes cb(window.MonacoVim) once ready.
          // The UMD's browser branch binds to the window.monaco set by the bundle.
          window.loadMonacoVim = function(cb) {
            if (window.MonacoVim) { cb(window.MonacoVim); return; }
            if (!window._monacoVimPromise) {
              window._monacoVimPromise = new Promise(function(resolve, reject) {
                var s = document.createElement('script');
                s.src = #{js("#{base}/monaco-editor/monaco-vim.js")};
                s.onload = resolve;
                s.onerror = function() { reject(new Error('Failed to load monaco-vim')); };
                document.head.appendChild(s);
              });
            }
            window._monacoVimPromise.then(function() { cb(window.MonacoVim); }, function(err) {
              // Clear the cached promise so the next vim-mode toggle retries the load.
              window._monacoVimPromise = null;
              console.error('Mbeditor: ' + err.message);
            });
          };

          // Deferred vendor scripts (React, ReactDOM, etc.) run before DOMContentLoaded.
          // Restoring window.define before they execute would cause them to register
          // as AMD modules instead of setting window globals, so wait for DOMContentLoaded first.
          function proceed() {
            // Store mbeditor's React/ReactDOM under a private namespace so the
            // app bundle can use them without touching window.React / window.ReactDOM.
            window.MbeditorRuntime = {
              React:    window.React,
              ReactDOM: window.ReactDOM
            };
            // Restore whatever the host app had before our deferred scripts ran.
            window.React    = window._mbeditorHostReact;
            window.ReactDOM = window._mbeditorHostReactDOM;

            window.define = _define;

            // Expose a promise that resolves when Monaco finishes loading.
            // EditorPanel awaits this before calling monaco.editor.create().
            var _monacoResolve;
            window.__monacoReady = new Promise(function(resolve) { _monacoResolve = resolve; });

            // Load application.js immediately — React mounts before Monaco is ready.
            // EditorPanel will show a skeleton until window.__monacoReady resolves.
            var appScript = document.createElement('script');
            appScript.src = #{js(application_js_url)};
            appScript.onload = function() {
              var root = document.getElementById('mbeditor-root');
              var _R  = window.MbeditorRuntime.React;
              var _RD = window.MbeditorRuntime.ReactDOM;
              if (window.MbeditorApp && _R && _RD) {
                _RD.render(_R.createElement(window.MbeditorApp), root);
              } else {
                console.error("Failed to mount: MbeditorApp or MbeditorRuntime is undefined.");
              }
            };
            appScript.onerror = function() {
              console.error('Mbeditor: failed to load application.js');
              document.getElementById('mbeditor-root').innerHTML = '<div style="padding:2rem;font-family:sans-serif;color:#c00">Editor failed to load. Please refresh the page.</div>';
            };
            document.body.appendChild(appScript);

            // Load Monaco in parallel — the bundle is an IIFE that sets window.monaco.
            var monacoScript = document.createElement('script');
            monacoScript.src = #{js("#{base}/monaco-editor/monaco.js")};
            monacoScript.onload = function() {
              // Register custom themes from the vendored bundle
              if (window.MBEDITOR_CUSTOM_THEMES && window.monaco) {
                Object.keys(window.MBEDITOR_CUSTOM_THEMES).forEach(function(id) {
                  window.monaco.editor.defineTheme(id, window.MBEDITOR_CUSTOM_THEMES[id]);
                });
              }
              _monacoResolve();
            };
            monacoScript.onerror = function() {
              console.error('Mbeditor: failed to load Monaco bundle');
              document.getElementById('mbeditor-root').innerHTML = '<div style="padding:2rem;font-family:sans-serif;color:#c00">Editor failed to load. Please refresh the page.</div>';
            };
            document.body.appendChild(monacoScript);
          }

          if (window._mbeditorDOMReady) {
            proceed();
          } else {
            document.addEventListener('DOMContentLoaded', proceed, { once: true });
          }
        })();
      JS
    end

    # JSON-encode a value for direct embedding inside an inline <script>,
    # escaping the characters that could terminate the script element.
    def js(value)
      ERB::Util.json_escape(value.to_json)
    end
  end
end
