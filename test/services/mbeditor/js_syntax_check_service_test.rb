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
  end
end
