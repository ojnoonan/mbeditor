# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class JsDefinitionServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_js_def_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_js(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def call(symbol)
      JsDefinitionService.new(symbol, @workspace).call
    end

    # -------------------------------------------------------------------------
    # Result shape
    # -------------------------------------------------------------------------

    test "returns result with file, line, and snippet keys when symbol is found" do
      write_js("app/components/button.js", "function myButton() { return true; }")

      results = call("myButton")

      assert results.any?, "expected at least one result"
      result = results.first
      assert result.key?(:file),    "result must have :file key"
      assert result.key?(:line),    "result must have :line key"
      assert result.key?(:snippet), "result must have :snippet key"
    end

    # -------------------------------------------------------------------------
    # Symbol not found
    # -------------------------------------------------------------------------

    test "returns empty array when symbol is not present" do
      write_js("app/app.js", "function unrelatedThing() {}")

      results = call("noSuchSymbol")

      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # Workspace-relative paths
    # -------------------------------------------------------------------------

    test "file key is workspace-relative, not absolute" do
      write_js("src/utils/helper.js", "function myHelper() {}")

      results = call("myHelper")

      assert results.any?
      assert_equal "src/utils/helper.js", results.first[:file]
    end

    # -------------------------------------------------------------------------
    # MAX_RESULTS cap
    # -------------------------------------------------------------------------

    test "caps results at MAX_RESULTS" do
      25.times do |i|
        write_js("components/comp_#{i}.js", "function theWidget() {}")
      end

      results = call("theWidget")

      assert results.length <= JsDefinitionService::MAX_RESULTS
    end

    # -------------------------------------------------------------------------
    # build_pattern: function declaration
    # -------------------------------------------------------------------------

    test "matches function declaration form" do
      write_js("app.js", "function myFunc() { return 1; }")

      results = call("myFunc")

      assert results.any?, "expected function declaration to be matched"
      assert_includes results.first[:snippet], "myFunc"
    end

    # -------------------------------------------------------------------------
    # build_pattern: const/let/var assignment
    # -------------------------------------------------------------------------

    test "matches const assignment form" do
      write_js("app.js", "const myWidget = function() {};")

      results = call("myWidget")

      assert results.any?, "expected const assignment to be matched"
    end

    # -------------------------------------------------------------------------
    # build_pattern: window property assignment
    # -------------------------------------------------------------------------

    test "matches window property assignment form" do
      write_js("app.js", "window.myGlobal = function() {};")

      results = call("myGlobal")

      assert results.any?, "expected window.X = to be matched"
    end

    # -------------------------------------------------------------------------
    # build_pattern: plain usage is NOT returned
    # -------------------------------------------------------------------------

    test "does not return plain usages that are not definitions" do
      write_js("app.js", "myFunc();\nconsole.log(myFunc);")

      results = call("myFunc")

      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # Ranking: top-level declarations beat nested ones
    # -------------------------------------------------------------------------

    test "top-level definition in a later file outranks an earlier nested one" do
      # 'a/...' sorts before 'z/...' in traversal order — the nested match is found first.
      write_js("a/parent.js", "var SomeParent = (function() {\n  function myHelper() { return 1; }\n  return { myHelper: myHelper };\n})();\n")
      write_js("z/global.js", "function myHelper() { return 2; }\n")

      results = call("myHelper")

      assert_operator results.length, :>=, 2
      assert_equal "z/global.js", results.first[:file]
      assert results.first[:topLevel]
      nested = results.find { |r| r[:file] == "a/parent.js" }
      assert_equal false, nested[:topLevel]
    end

    test "window assignment inside an indented IIFE body counts as top level" do
      write_js("a/iife.js", "(function() {\n  window.Exposed = function() {};\n})();\n")

      results = call("Exposed")

      assert_equal 1, results.length
      assert results.first[:topLevel]
    end

    test "the result cap is applied after ranking so the top-level match survives" do
      nested = (1..30).map { |i| "  function capHelper() { return #{i}; }" }.join("\n")
      write_js("a/many_nested.js", "var X = (function() {\n#{nested}\n})();\n")
      write_js("z/the_global.js", "function capHelper() { return 0; }\n")

      results = call("capHelper")

      assert_equal JsDefinitionService::MAX_RESULTS, results.length
      assert_equal "z/the_global.js", results.first[:file]
      assert results.first[:topLevel]
    end

    # -------------------------------------------------------------------------
    # Parent context: member resolution
    # -------------------------------------------------------------------------

    def call_with_parent(symbol, parent)
      JsDefinitionService.new(symbol, @workspace, parent: parent).call
    end

    test "parent context resolves a direct member assignment over a same-named global" do
      write_js("a/global.js", "function myAction() { return 'global'; }\n")
      write_js("b/parent.js", "var SomeParent = {};\nSomeParent.myAction = function() { return 'member'; };\n")

      results = call_with_parent("myAction", "SomeParent")

      assert_equal 1, results.length
      assert_equal "b/parent.js", results.first[:file]
      assert_equal 2, results.first[:line]
      assert results.first[:member]
      assert_equal false, results.first[:topLevel]
    end

    test "parent context resolves a prototype member assignment" do
      write_js("proto.js", "function Widget() {}\nWidget.prototype.render = function() {};\n")

      results = call_with_parent("render", "Widget")

      assert_equal 1, results.length
      assert_equal 2, results.first[:line]
    end

    test "parent context resolves object-literal methods only in files defining the parent" do
      write_js("a/other.js", "var Unrelated = {\n  doWork: function() { return 'wrong'; }\n};\n")
      write_js("b/parent.js", "var SomeParent = {\n  doWork: function() { return 'right'; }\n};\n")

      results = call_with_parent("doWork", "SomeParent")

      assert results.any?, "expected the object-literal member to be found"
      assert results.all? { |r| r[:file] == "b/parent.js" }
    end

    test "parent context falls back to ranked plain results when no member matches" do
      write_js("global.js", "function orphanFn() {}\n")

      results = call_with_parent("orphanFn", "NoSuchParent")

      assert_equal 1, results.length
      assert_equal "global.js", results.first[:file]
      assert results.first[:topLevel]
    end

    # -------------------------------------------------------------------------
    # git grep tier — patterns must be pure POSIX ERE
    # -------------------------------------------------------------------------
    # git grep's regex engine rejects `(?:` and treats \b/\s literally, so a
    # PCRE-flavoured pattern silently returns zero results on rg-less machines
    # in git workspaces. Run the same lookups through the git tier.

    test "definitions and members are found through the git grep tier" do
      system("git", "-C", @workspace, "init", "-q", exception: true)
      write_js("app/global.js", "function gitTierFn() {}\nvar GitParent = {};\nGitParent.gitTierFn = function() {};\nwindow.GitExposed = 1;\n")

      singleton = class << SearchReplaceService; self; end
      singleton.alias_method :__orig_rg_available?, :rg_available?
      SearchReplaceService.define_singleton_method(:rg_available?) { false }

      plain = call("gitTierFn")
      assert_equal 1, plain.count { |r| r[:snippet].start_with?("function") },
                   "plain function definition must be found via git grep"

      members = call_with_parent("gitTierFn", "GitParent")
      assert members.any?, "member assignment must be found via git grep"
      assert members.first[:member]

      window = call("GitExposed")
      assert_equal 1, window.length
      assert window.first[:topLevel]

      member_list = JsMembersService.new("GitParent", @workspace).call
      assert member_list.any? { |m| m[:name] == "gitTierFn" },
             "JsMembersService pattern must work via git grep"
    ensure
      singleton.remove_method :rg_available?
      singleton.alias_method :rg_available?, :__orig_rg_available?
      singleton.remove_method :__orig_rg_available?
    end
  end
end
