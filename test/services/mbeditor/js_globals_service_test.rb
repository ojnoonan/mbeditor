# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class JsGlobalsServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_js_globals_test_")
      JsGlobalsService.invalidate(@workspace)
    end

    def teardown
      JsGlobalsService.invalidate(@workspace)
      FileUtils.rm_rf(@workspace)
    end

    def write_file(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def symbol_names(result)
      result[:symbols].map { |s| s[:name] }
    end

    test "collects top-level declarations across JS-family files including .js.jsx" do
      write_file("app/assets/javascripts/components/Foo.js.jsx",
                 "function Foo(props) {\n  return <div/>;\n}\n")
      write_file("app/assets/javascripts/bar.js", "var Bar = 1, Baz = 2;\n")
      write_file("app/assets/javascripts/qux.js", "window.Qux = { a: 1 };\n")
      write_file("app/assets/javascripts/klass.js", "class Widget {}\nconst HELPER = 3;\n")

      result = JsGlobalsService.call(@workspace)

      assert result[:ok]
      names = symbol_names(result)
      assert_includes names, "Foo"
      assert_includes names, "Bar"
      assert_includes names, "Baz"
      assert_includes names, "Qux"
      assert_includes names, "Widget"
      assert_includes names, "HELPER"

      foo = result[:symbols].find { |s| s[:name] == "Foo" }
      assert_equal "app/assets/javascripts/components/Foo.js.jsx", foo[:file]
      assert_equal "function", foo[:kind]
      assert_equal 1, foo[:line]
    end

    test "minified bundles do not flood the symbol table" do
      # One minified line declares thousands of one-letter names; unfiltered it
      # exhausts MAX_SYMBOLS before any real component is reached.
      minified = "var " + (1..900).map { |i| "m#{i}=#{i}" }.join(",") + ";"
      write_file("vendor/assets/javascripts/babel.min.js", minified)
      # Same content, filename says nothing — caught by the line-length guard.
      write_file("vendor/assets/javascripts/bundle.js", minified)
      write_file("app/assets/javascripts/components/Real.jsx", "function Real() {}\n")

      names = symbol_names(JsGlobalsService.call(@workspace))

      assert_includes names, "Real"
      assert_not_includes names, "m1"
      assert_not_includes names, "m900"
    end

    test "a normally formatted vendor library still contributes its globals" do
      write_file("vendor/assets/javascripts/angular.js", "var angular = {};\nfunction bootstrap() {}\n")

      names = symbol_names(JsGlobalsService.call(@workspace))

      assert_includes names, "angular"
      assert_includes names, "bootstrap"
    end

    test "truncated is false when the workspace fits under the cap" do
      write_file("app/assets/javascripts/a.js", "var Only = 1;\n")

      assert_equal false, JsGlobalsService.call(@workspace)[:truncated]
    end

    test "indented declarations are not treated as globals but indented window assignments are" do
      write_file("app/assets/javascripts/scoped.js",
                 "(function() {\n  function Inner() {}\n  var hidden = 1;\n  window.Exposed = Inner;\n})();\n")

      names = symbol_names(JsGlobalsService.call(@workspace))

      assert_not_includes names, "Inner"
      assert_not_includes names, "hidden"
      assert_includes names, "Exposed"
    end

    test "excluded directories are not scanned" do
      original_excluded = Mbeditor.configuration.excluded_paths
      Mbeditor.configuration.excluded_paths = %w[.git tmp log node_modules]
      write_file("node_modules/pkg/index.js", "var VendorGlobal = 1;\n")
      write_file("app/real.js", "var RealGlobal = 1;\n")

      names = symbol_names(JsGlobalsService.call(@workspace))

      assert_includes names, "RealGlobal"
      assert_not_includes names, "VendorGlobal"
    ensure
      Mbeditor.configuration.excluded_paths = original_excluded
      JsGlobalsService.invalidate(@workspace)
    end

    test "seeds UMD runtime globals the static scan cannot see" do
      result = JsGlobalsService.call(@workspace)

      assert_includes symbol_names(result), "ReactRailsUJS"
      ujs = result[:symbols].find { |s| s[:name] == "ReactRailsUJS" }
      assert_equal "configured", ujs[:kind]
      assert_nil ujs[:file]
    ensure
      JsGlobalsService.invalidate(@workspace)
    end

    test "merges configured js_global_identifiers and drops invalid names" do
      original = Mbeditor.configuration.js_global_identifiers
      Mbeditor.configuration.js_global_identifiers = ["Routes", "I18n", "bad name!", ""]

      result = JsGlobalsService.call(@workspace)
      names = symbol_names(result)

      assert_includes names, "Routes"
      assert_includes names, "I18n"
      assert_not_includes names, "bad name!"
      routes = result[:symbols].find { |s| s[:name] == "Routes" }
      assert_equal "configured", routes[:kind]
    ensure
      Mbeditor.configuration.js_global_identifiers = original
      JsGlobalsService.invalidate(@workspace)
    end

    test "grep tier finds the same globals when rg is unavailable" do
      write_file("app/widget.js.jsx", "function GrepWidget() {}\n")

      singleton = class << SearchReplaceService; self; end
      singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { false }

      names = symbol_names(JsGlobalsService.call(@workspace))
      assert_includes names, "GrepWidget"
    ensure
      singleton.remove_method :rg_available?
      singleton.alias_method :rg_available?, :__orig_rg_available?
      singleton.remove_method :__orig_rg_available?
    end

    test "cache serves repeat calls and invalidate forces a fresh scan" do
      write_file("app/a.js", "var First = 1;\n")
      first = JsGlobalsService.call(@workspace)
      assert_includes symbol_names(first), "First"

      write_file("app/b.js", "var Second = 1;\n")
      cached = JsGlobalsService.call(@workspace)
      assert_not_includes symbol_names(cached), "Second", "within TTL the cached payload is served"

      JsGlobalsService.invalidate(@workspace)
      fresh = JsGlobalsService.call(@workspace)
      assert_includes symbol_names(fresh), "Second"
    end

    test "configured identifiers survive the MAX_SYMBOLS cap" do
      content = (1..50).map { |i| "var CapTest#{i} = #{i};" }.join("\n")
      write_file("app/many.js", content)

      original_ids = Mbeditor.configuration.js_global_identifiers
      Mbeditor.configuration.js_global_identifiers = ["MustSurvive"]
      original = JsGlobalsService::MAX_SYMBOLS
      $VERBOSE = nil
      JsGlobalsService.send(:remove_const, :MAX_SYMBOLS)
      JsGlobalsService.const_set(:MAX_SYMBOLS, 5)
      $VERBOSE = true

      assert_includes symbol_names(JsGlobalsService.call(@workspace)), "MustSurvive"
    ensure
      $VERBOSE = nil
      JsGlobalsService.send(:remove_const, :MAX_SYMBOLS)
      JsGlobalsService.const_set(:MAX_SYMBOLS, original)
      $VERBOSE = true
      Mbeditor.configuration.js_global_identifiers = original_ids
      JsGlobalsService.invalidate(@workspace)
    end

    test "caps the symbol list at MAX_SYMBOLS" do
      content = (1..50).map { |i| "var CapTest#{i} = #{i};" }.join("\n")
      write_file("app/many.js", content)

      original = JsGlobalsService::MAX_SYMBOLS
      $VERBOSE = nil
      JsGlobalsService.send(:remove_const, :MAX_SYMBOLS)
      JsGlobalsService.const_set(:MAX_SYMBOLS, 10)
      $VERBOSE = true

      result = JsGlobalsService.call(@workspace)
      assert_operator result[:symbols].length, :<=, 10
    ensure
      $VERBOSE = nil
      JsGlobalsService.send(:remove_const, :MAX_SYMBOLS)
      JsGlobalsService.const_set(:MAX_SYMBOLS, original)
      $VERBOSE = true
      JsGlobalsService.invalidate(@workspace)
    end
  end
end
