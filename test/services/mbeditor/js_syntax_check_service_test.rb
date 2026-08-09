# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # Tests below skip themselves when MiniRacer isn't available.
end

module Mbeditor
  class JsSyntaxCheckServiceTest < ActiveSupport::TestCase
    # A minimal stand-in exposing the same surface the service uses
    # (Babel.transform throwing a parse error with .loc). Real babel-standalone
    # is host-provided and too large to vendor for tests.
    STUB_BABEL = <<~JS
      var Babel = {
        transform: function (src, opts) {
          if (src.indexOf("SYNTAX_ERROR_MARKER") !== -1) {
            var e = new Error("Unexpected token (2:5)");
            e.loc = { line: 2, column: 5 };
            throw e;
          }
          return { code: null };
        }
      };
    JS

    def setup
      skip "mini_racer not available" unless defined?(::MiniRacer)
      @dir = Dir.mktmpdir("mbeditor_babel_test_")
      @babel_path = File.join(@dir, "babel.min.js")
      File.write(@babel_path, STUB_BABEL)
      @original_check = Mbeditor.configuration.js_syntax_check
      @original_path  = Mbeditor.configuration.babel_standalone_path
      Mbeditor.configuration.js_syntax_check = :auto
      Mbeditor.configuration.babel_standalone_path = @babel_path
      JsSyntaxCheckService.reset!
    end

    def teardown
      Mbeditor.configuration.js_syntax_check = @original_check
      Mbeditor.configuration.babel_standalone_path = @original_path
      JsSyntaxCheckService.reset!
      FileUtils.rm_rf(@dir) if @dir
    end

    test "available? is true with mini_racer and a configured babel path" do
      assert JsSyntaxCheckService.available?
    end

    test "available? is false when disabled via config" do
      Mbeditor.configuration.js_syntax_check = false
      assert_not JsSyntaxCheckService.available?
    end

    test "available? is false when the babel path does not exist" do
      Mbeditor.configuration.babel_standalone_path = File.join(@dir, "missing.js")
      JsSyntaxCheckService.reset!
      assert_not JsSyntaxCheckService.available?
    end

    test "check returns nil for source that transforms cleanly" do
      assert_nil JsSyntaxCheckService.check("var x = 1;")
    end

    test "check returns message, line, and column for a parse error" do
      err = JsSyntaxCheckService.check("var ok = 1;\nSYNTAX_ERROR_MARKER\n")

      assert_kind_of Hash, err
      assert_includes err["message"], "Unexpected token"
      assert_equal 2, err["line"]
      assert_equal 5, err["column"]
    end

    test "check survives a broken babel bundle by reporting clean" do
      File.write(@babel_path, "this is not javascript {{{")
      JsSyntaxCheckService.reset!

      assert JsSyntaxCheckService.available?, "availability is path-based"
      assert_nil JsSyntaxCheckService.check("var x = 1;")
    end

    # -------------------------------------------------------------------------
    # scope_lint — plumbing tests against a canned __mbLint. The real
    # parser/traverse logic requires real babel-standalone (host-provided, too
    # large to vendor); it is exercised against the genuine bundle in
    # development, and LINT_HELPERS_JS returns early when Babel.packages is
    # absent, which the fallback test below covers.
    # -------------------------------------------------------------------------

    # collect() whitelists any name declared as `const NAME` at a line start;
    # lint() reports every NEED_* token not on the whitelist.
    STUB_LINT_BABEL = STUB_BABEL + <<~JS
      globalThis.__mbLint = {
        collect: function (source) {
          var names = [], re = /^const (\\w+)/gm, m;
          while ((m = re.exec(source))) names.push(m[1]);
          return names;
        },
        lint: function (source, whitelist, max) {
          var out = [], re = /\\bNEED_\\w+\\b/g, m;
          while ((m = re.exec(source))) {
            if (whitelist.indexOf(m[0]) === -1) {
              out.push({ kind: "undeclared", name: m[0], line: 1, column: m.index,
                         message: m[0] + " is not defined in any reachable scope" });
            }
          }
          return out;
        }
      };
    JS

    def with_scope_lint_workspace
      File.write(@babel_path, STUB_LINT_BABEL)
      JsSyntaxCheckService.reset!
      workspace = File.join(@dir, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "defs.js"), "const NEED_defined = 1;\n")
      JsProgramService.invalidate(workspace)
      JsGlobalsService.invalidate(workspace)
      yield workspace
    ensure
      JsProgramService.invalidate(workspace)
      JsGlobalsService.invalidate(workspace)
    end

    test "scope_lint reports names missing from every scope and the cross-file whitelist" do
      with_scope_lint_workspace do |workspace|
        findings = JsSyntaxCheckService.scope_lint(workspace, "var a = NEED_missing;")

        assert_equal 1, findings.length
        assert_equal "NEED_missing", findings.first["name"]
        assert_includes findings.first["message"], "not defined in any reachable scope"
      end
    end

    test "scope_lint whitelists top-level declarations from other workspace files" do
      with_scope_lint_workspace do |workspace|
        assert_equal [], JsSyntaxCheckService.scope_lint(workspace, "var a = NEED_defined;")
      end
    end

    test "scope_lint returns nothing when disabled via config" do
      original = Mbeditor.configuration.js_scope_lint
      Mbeditor.configuration.js_scope_lint = false
      with_scope_lint_workspace do |workspace|
        assert_equal [], JsSyntaxCheckService.scope_lint(workspace, "var a = NEED_missing;")
      end
    ensure
      Mbeditor.configuration.js_scope_lint = original
    end

    test "scope_lint reports clean when babel lacks parser/traverse packages" do
      # STUB_BABEL defines no Babel.packages, so LINT_HELPERS_JS leaves
      # __mbLint undefined and the lint degrades to a no-op.
      workspace = File.join(@dir, "workspace")
      FileUtils.mkdir_p(workspace)
      assert_equal [], JsSyntaxCheckService.scope_lint(workspace, "var a = NEED_missing;")
    end
  end
end
