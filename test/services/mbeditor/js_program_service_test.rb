# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class JsProgramServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_js_program_test_")
      JsProgramService.invalidate(@workspace)
      @original_exclude  = Mbeditor.configuration.js_program_exclude
      @original_enabled  = Mbeditor.configuration.js_program
      @original_excluded = Mbeditor.configuration.excluded_paths
      # Pinned rather than inherited: other suites mutate excluded_paths
      # globally and don't always restore it, so what this service prunes has
      # to be stated here or the assertions depend on test order.
      Mbeditor.configuration.excluded_paths = Configuration.new.excluded_paths
    end

    def teardown
      Mbeditor.configuration.js_program_exclude = @original_exclude
      Mbeditor.configuration.js_program = @original_enabled
      Mbeditor.configuration.excluded_paths = @original_excluded
      JsProgramService.invalidate(@workspace)
      FileUtils.rm_rf(@workspace)
    end

    def write_file(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    def paths(result)
      result[:files].map { |f| f[:path] }
    end

    test "collects the workspace's own JS-family source with content" do
      write_file("app/assets/javascripts/ux/Widget.jsx", "var Widget = function () { return null; };\n")
      write_file("app/assets/javascripts/util.js", "function helper(a) { return a; }\n")
      write_file("app/assets/javascripts/typed.ts", "export const x: number = 1;\n")

      result = JsProgramService.call(@workspace)

      assert result[:ok]
      assert result[:enabled]
      assert_equal %w[app/assets/javascripts/typed.ts
                      app/assets/javascripts/util.js
                      app/assets/javascripts/ux/Widget.jsx].sort, paths(result).sort
      widget = result[:files].find { |f| f[:path].end_with?("Widget.jsx") }
      assert_includes widget[:content], "var Widget"
      assert_equal result[:files].sum { |f| f[:content].bytesize }, result[:totalBytes]
    end

    test "ignores non-JS files entirely" do
      write_file("app/models/user.rb", "class User; end\n")
      write_file("README.md", "# hi\n")
      write_file("app/assets/javascripts/a.js", "var A = 1;\n")

      assert_equal ["app/assets/javascripts/a.js"], paths(JsProgramService.call(@workspace))
    end

    test "prunes excluded directories without descending into them" do
      write_file("node_modules/left-pad/index.js", "var leftPad = 1;\n")
      write_file("vendor/assets/javascripts/angular.js", "var angular = {};\n")
      write_file("tmp/cache/thing.js", "var cached = 1;\n")
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")

      assert_equal ["app/assets/javascripts/mine.js"], paths(JsProgramService.call(@workspace))
    end

    test "js_program_exclude adds directories on top of excluded_paths" do
      write_file("app/assets/javascripts/react/react.js", "var reactish = 1;\n")
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")
      Mbeditor.configuration.js_program_exclude = %w[vendor app/assets/javascripts/react]
      JsProgramService.invalidate(@workspace)

      assert_equal ["app/assets/javascripts/mine.js"], paths(JsProgramService.call(@workspace))
    end

    test "skips minified files by name and by shape, and reports why" do
      write_file("app/assets/javascripts/thing.min.js", "var a=1,b=2;\n")
      # No "min" in the name — caught by the long-line check instead.
      write_file("app/assets/javascripts/bundle.js", "var x=1;" + ("/*pad*/" * 400) + "\n")
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")

      result = JsProgramService.call(@workspace)

      assert_equal ["app/assets/javascripts/mine.js"], paths(result)
      assert_includes result[:skipped].map { |s| s[:path] }, "app/assets/javascripts/bundle.js"
    end

    test "skips oversized files and reports them rather than truncating silently" do
      write_file("app/assets/javascripts/huge.js", "var pad = '#{"x" * 100}';\n" * 12_000)
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")

      result = JsProgramService.call(@workspace)

      assert_equal ["app/assets/javascripts/mine.js"], paths(result)
      skipped = result[:skipped].find { |s| s[:path] == "app/assets/javascripts/huge.js" }
      assert skipped, "expected the oversized file to be reported in :skipped"
      assert_match(/larger than/, skipped[:reason])
    end

    test "does not follow symlinks out of the workspace" do
      outside = Dir.mktmpdir("mbeditor_outside_")
      File.write(File.join(outside, "secret.js"), "var Secret = 1;\n")
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")
      FileUtils.ln_s(outside, File.join(@workspace, "app", "linked"))

      assert_equal ["app/assets/javascripts/mine.js"], paths(JsProgramService.call(@workspace))
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    test "js_program = false returns an empty, disabled program" do
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")
      Mbeditor.configuration.js_program = false
      JsProgramService.invalidate(@workspace)

      result = JsProgramService.call(@workspace)

      assert result[:ok]
      assert_equal false, result[:enabled]
      assert_empty result[:files]
    end

    test ".file returns one entry for incremental refresh" do
      write_file("app/assets/javascripts/mine.js", "var Mine = 1;\n")

      entry = JsProgramService.file(@workspace, "app/assets/javascripts/mine.js")

      assert_equal "app/assets/javascripts/mine.js", entry[:path]
      assert_includes entry[:content], "var Mine"
    end

    test ".file refuses excluded, non-JS, minified and out-of-workspace paths" do
      write_file("app/models/user.rb", "class User; end\n")
      write_file("node_modules/x/index.js", "var x = 1;\n")
      write_file("app/assets/javascripts/thing.min.js", "var a=1;\n")

      assert_nil JsProgramService.file(@workspace, "app/models/user.rb")
      assert_nil JsProgramService.file(@workspace, "node_modules/x/index.js")
      assert_nil JsProgramService.file(@workspace, "app/assets/javascripts/thing.min.js")
      assert_nil JsProgramService.file(@workspace, "../../etc/passwd.js")
    end

    test "results are cached per workspace until invalidated" do
      write_file("app/assets/javascripts/one.js", "var One = 1;\n")
      assert_equal ["app/assets/javascripts/one.js"], paths(JsProgramService.call(@workspace))

      write_file("app/assets/javascripts/two.js", "var Two = 2;\n")
      assert_equal ["app/assets/javascripts/one.js"], paths(JsProgramService.call(@workspace)),
                   "expected the cached result before invalidation"

      JsProgramService.invalidate(@workspace)
      assert_equal 2, JsProgramService.call(@workspace)[:files].length
    end
  end
end
