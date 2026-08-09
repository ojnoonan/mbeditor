# frozen_string_literal: true

module Mbeditor
  # Save-time JS/JSX syntax check using the HOST app's own toolchain: runs
  # babel-standalone inside a MiniRacer (V8) context — the same transform that
  # sprockets/react-rails will apply — so code that would break the host's
  # asset pipeline is caught in the editor instead of at page load.
  #
  # Zero new dependencies (ADR-0001): active only when the host already has
  # mini_racer loaded AND a babel-standalone asset can be found. Degrades to a
  # no-op otherwise.
  class JsSyntaxCheckService
    EVAL_TIMEOUT_MS = 2_000
    # V8 heap grows across transforms; recreate the context periodically.
    MAX_CHECKS_PER_CONTEXT = 50
    BABEL_ASSET_CANDIDATES = %w[babel.min.js babel.js babel-standalone.js babel-standalone.min.js].freeze
    MAX_SCOPE_FINDINGS = 50

    # Names defined by the browser rather than by any workspace file. ES
    # builtins (Array, Promise, ...) are NOT listed: babel's own
    # Scope#hasBinding already knows them, so this only needs the DOM layer.
    BROWSER_GLOBALS = %w[
      window document navigator location history screen console
      alert confirm prompt getComputedStyle matchMedia scrollTo scrollBy
      innerWidth innerHeight devicePixelRatio
      fetch Headers Request Response XMLHttpRequest WebSocket EventSource
      FormData URL URLSearchParams Blob File FileReader FileList DataTransfer
      AbortController AbortSignal DOMParser XMLSerializer
      setTimeout setInterval clearTimeout clearInterval
      requestAnimationFrame cancelAnimationFrame requestIdleCallback cancelIdleCallback
      queueMicrotask structuredClone atob btoa
      localStorage sessionStorage indexedDB crypto performance
      Event CustomEvent KeyboardEvent MouseEvent TouchEvent ErrorEvent
      MessageEvent PopStateEvent StorageEvent ProgressEvent ClipboardEvent
      MutationObserver ResizeObserver IntersectionObserver
      Node NodeList Element HTMLElement SVGElement Image Audio Option
      CSS customElements
    ].freeze

    # The React UMD globals plus the bare hook aliases host apps conventionally
    # pull out of React at the top of a Sprockets bundle.
    REACT_GLOBALS = %w[
      React ReactDOM PropTypes
      useState useEffect useLayoutEffect useRef useMemo useCallback useContext
      useReducer useId useTransition useDeferredValue useSyncExternalStore
      useImperativeHandle useDebugValue
    ].freeze

    # Installed into the V8 context alongside babel-standalone. collect()
    # returns a file's top-level declaration names (Sprockets concatenates
    # every file into one scope, so these are the cross-file globals). lint()
    # reports references babel can bind to no scope and no whitelist entry,
    # plus bindings that are only ever assigned inside a
    # useEffect/useLayoutEffect callback but read during render.
    LINT_HELPERS_JS = <<~'JS'
      (function () {
        if (globalThis.__mbLint) return;
        if (typeof Babel === "undefined" || !Babel.packages || !Babel.packages.parser || !Babel.packages.traverse) return;
        var parser = Babel.packages.parser;
        var traverse = Babel.packages.traverse["default"] || Babel.packages.traverse;

        function parse(source) {
          return parser.parse(source, { sourceType: "script", plugins: ["jsx"], errorRecovery: true });
        }

        function bindNames(node, out) {
          if (!node) return;
          switch (node.type) {
            case "Identifier": out.push(node.name); break;
            case "ObjectPattern": node.properties.forEach(function (p) { bindNames(p.value || p.argument, out); }); break;
            case "ArrayPattern": node.elements.forEach(function (el) { bindNames(el, out); }); break;
            case "AssignmentPattern": bindNames(node.left, out); break;
            case "RestElement": bindNames(node.argument, out); break;
          }
        }

        // Is this path inside the callback argument of useEffect/useLayoutEffect?
        function insideEffectCallback(path) {
          var fn = path.getFunctionParent();
          while (fn) {
            var parent = fn.parentPath;
            if (parent && parent.isCallExpression() && parent.node.arguments[0] === fn.node) {
              var callee = parent.node.callee;
              var name = callee.type === "Identifier" ? callee.name
                : (callee.type === "MemberExpression" && !callee.computed && callee.property.type === "Identifier"
                    ? callee.property.name : null);
              if (name === "useEffect" || name === "useLayoutEffect") return true;
            }
            fn = fn.getFunctionParent();
          }
          return false;
        }

        globalThis.__mbLint = {
          collect: function (source) {
            var names = [];
            var ast;
            try { ast = parse(source); } catch (e) { return names; }
            ast.program.body.forEach(function (node) {
              if (node.type === "VariableDeclaration") {
                node.declarations.forEach(function (d) { bindNames(d.id, names); });
              } else if (node.type === "FunctionDeclaration" || node.type === "ClassDeclaration") {
                if (node.id) names.push(node.id.name);
              }
            });
            return names;
          },

          lint: function (source, whitelist, max) {
            var findings = [];
            var wl = {};
            whitelist.forEach(function (n) { wl[n] = true; });
            var ast;
            try { ast = parse(source); } catch (e) { return findings; }
            var seen = {};

            try {
              traverse(ast, {
                ReferencedIdentifier: function (p) {
                  if (findings.length >= max) { p.stop(); return; }
                  var name = p.node.name;
                  if (p.isJSXIdentifier() && !/^[A-Z]/.test(name)) return; // <div>, <span>
                  if (wl[name]) return;
                  if (p.scope.hasBinding(name)) return; // includes ES builtins
                  if (p.parentPath && p.parentPath.isUnaryExpression({ operator: "typeof" })) return;
                  var loc = p.node.loc && p.node.loc.start;
                  var key = name + ":" + (loc ? loc.line : 0);
                  if (seen[key]) return;
                  seen[key] = true;
                  findings.push({
                    kind: "undeclared", name: name,
                    line: loc ? loc.line : 1, column: loc ? loc.column : 0,
                    message: "'" + name + "' is not defined in any reachable scope"
                  });
                },

                Function: function (p) {
                  if (findings.length >= max) { p.stop(); return; }
                  var bindings = p.scope.bindings;
                  Object.keys(bindings).forEach(function (name) {
                    var b = bindings[name];
                    if (b.kind !== "let" && b.kind !== "var") return;
                    if (!b.path.isVariableDeclarator() || b.path.node.init) return;
                    var writes = b.constantViolations || [];
                    if (!writes.length) return;
                    if (!writes.every(insideEffectCallback)) return;
                    var renderReads = (b.referencePaths || []).filter(function (r) { return !insideEffectCallback(r); });
                    if (!renderReads.length) return;
                    var loc = renderReads[0].node.loc && renderReads[0].node.loc.start;
                    findings.push({
                      kind: "effect", name: name,
                      line: loc ? loc.line : 1, column: loc ? loc.column : 0,
                      message: "'" + name + "' is only assigned inside an effect but read during render — undefined on first render"
                    });
                  });
                }
              });
            } catch (e) { /* traversal blew up on odd input — report what we have */ }
            return findings;
          }
        };
      })();
    JS

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def available?
        return false if Mbeditor.configuration.js_syntax_check == false
        return false unless defined?(::MiniRacer)

        !babel_source_path.nil?
      end

      # Returns nil when the source parses cleanly (or the checker is
      # unavailable/broken), else { "message" =>, "line" =>, "column" => }.
      def check(source)
        return nil unless available?

        MUTEX.synchronize do
          begin
            ctx = context
            return nil unless ctx

            result = ctx.eval(<<~JS)
              (function () {
                try {
                  Babel.transform(#{source.to_json}, { presets: ["react"], code: false });
                  return null;
                } catch (e) {
                  return {
                    message: String((e && e.message) || e).split("\\n")[0],
                    line: (e && e.loc && e.loc.line) || null,
                    column: (e && e.loc && e.loc.column) || null
                  };
                }
              })()
            JS

            @checks_run = (@checks_run || 0) + 1
            reset_context! if @checks_run >= MAX_CHECKS_PER_CONTEXT
            result
          rescue StandardError
            # Timeout / V8 OOM / eval failure: recreate on next use, report clean.
            reset_context!
            nil
          end
        end
      end

      # Babel-based scope lint: warnings for identifier references that bind to
      # no scope, no top-level declaration anywhere in the workspace's own JS
      # (Sprockets: one shared scope), no known window.X global, and no
      # browser/React name — the typos Monaco's TS worker misses once ambient
      # globals are declared. Plus the effect-write/render-read hazard.
      # Report-only; returns [] whenever anything is unavailable or fails.
      def scope_lint(workspace_root, source)
        return [] unless available? && Mbeditor.configuration.js_scope_lint != false

        MUTEX.synchronize do
          begin
            ctx = context
            return [] unless ctx

            ctx.eval(LINT_HELPERS_JS) unless @lint_helpers_loaded
            @lint_helpers_loaded = true
            return [] unless ctx.eval("typeof __mbLint !== 'undefined'")

            names = whitelist(ctx, workspace_root)
            findings = ctx.eval("__mbLint.lint(#{source.to_json}, #{names.to_json}, #{MAX_SCOPE_FINDINGS})")

            @checks_run = (@checks_run || 0) + 1
            reset_context! if @checks_run >= MAX_CHECKS_PER_CONTEXT
            Array(findings).select { |f| f.is_a?(Hash) }
          rescue StandardError
            reset_context!
            []
          end
        end
      end

      # Exposed for tests.
      def reset!
        MUTEX.synchronize do
          reset_context!
          @babel_path = :unresolved
          @decl_cache = nil
        end
      end

      private

      def context
        @context ||= begin
          path = babel_source_path
          return nil unless path

          ctx = ::MiniRacer::Context.new(timeout: EVAL_TIMEOUT_MS)
          ctx.eval(File.read(path))
          ctx.eval("if (typeof Babel === 'undefined') { throw new Error('Babel global missing'); }")
          @checks_run = 0
          ctx
        rescue StandardError
          @context = nil
          nil
        end
      end

      def reset_context!
        @context = nil
        @checks_run = 0
        @lint_helpers_loaded = false
      end

      # Cross-file whitelist: every top-level declaration in the workspace's
      # own JS program, every window.X-style global JsGlobalsService knows,
      # plus the browser and React layers. Per-file declaration names are
      # cached by content digest, so a steady-state save re-parses only the
      # files that changed since the last lint.
      def whitelist(ctx, workspace_root)
        names = []
        @decl_cache ||= {}
        live = {}

        program = JsProgramService.call(workspace_root.to_s)
        Array(program[:files]).each do |f|
          digest = f[:content].hash
          entry = @decl_cache[f[:path]]
          entry = { digest: digest, names: collect_names(ctx, f[:content]) } unless entry && entry[:digest] == digest
          live[f[:path]] = entry
          names.concat(entry[:names])
        end
        @decl_cache = live

        globals = JsGlobalsService.call(workspace_root.to_s)
        names.concat(Array(globals[:symbols]).map { |s| s[:name].to_s })

        (names + BROWSER_GLOBALS + REACT_GLOBALS).uniq
      end

      def collect_names(ctx, source)
        Array(ctx.eval("__mbLint.collect(#{source.to_json})")).grep(String)
      rescue StandardError
        []
      end

      def babel_source_path
        cached = @babel_path
        return (cached == :none ? nil : cached) if cached && cached != :unresolved

        @babel_path = resolve_babel_path || :none
        @babel_path == :none ? nil : @babel_path
      end

      def resolve_babel_path
        configured = Mbeditor.configuration.babel_standalone_path.to_s
        if configured != ""
          return configured if File.file?(configured)

          in_workspace = File.expand_path(configured, Rails.root.to_s)
          return in_workspace if File.file?(in_workspace)

          return nil
        end

        assets = Rails.application.try(:assets)
        return nil unless assets.respond_to?(:find_asset)

        BABEL_ASSET_CANDIDATES.each do |name|
          asset = begin
            assets.find_asset(name)
          rescue StandardError
            nil
          end
          filename = asset.respond_to?(:filename) ? asset.filename.to_s : nil
          return filename if filename && File.file?(filename)
        end
        nil
      end
    end
  end
end
