# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RubyLspResultTranslatorTest < ActiveSupport::TestCase
    ROOT = Pathname.new("/workspace")

    def translator
      RubyLspResultTranslator
    end

    # ── definition ──────────────────────────────────────────────────────────

    def location(uri: "file:///workspace/app/models/user.rb", start_line: 2, start_char: 4,
                 end_line: 2, end_char: 9)
      { "uri" => uri,
        "range" => { "start" => { "line" => start_line, "character" => start_char },
                     "end" => { "line" => end_line, "character" => end_char } } }
    end

    test "definition converts 0-based LSP ranges to 1-based positions" do
      result = translator.definition([location], workspace_root: ROOT)

      loc = result[:results].first
      assert_equal "app/models/user.rb", loc[:file]
      assert_equal 3, loc[:line]
      assert_equal 5, loc[:col]
      assert_equal 3, loc[:endLine]
      assert_equal 10, loc[:endCol]
    end

    test "definition drops gem/stdlib locations outside the workspace" do
      result = translator.definition([location(uri: "file:///usr/lib/ruby/3.3/set.rb")], workspace_root: ROOT)
      assert_equal [], result[:results]
    end

    test "definition accepts a bare hash as well as an array" do
      result = translator.definition(location, workspace_root: ROOT)
      assert_equal 1, result[:results].length
    end

    test "definition reads targetUri/targetSelectionRange for LocationLink results" do
      link = { "targetUri" => "file:///workspace/app/models/user.rb",
                "targetSelectionRange" => { "start" => { "line" => 0, "character" => 0 },
                                             "end" => { "line" => 0, "character" => 1 } } }
      result = translator.definition([link], workspace_root: ROOT)
      assert_equal 1, result[:results].length
      assert_equal 1, result[:results].first[:line]
    end

    test "definition skips malformed entries" do
      result = translator.definition([location, "not a hash", nil], workspace_root: ROOT)
      assert_equal 1, result[:results].length
    end

    # ── hover ───────────────────────────────────────────────────────────────

    test "hover reads a Hash, Array, or bare string contents field" do
      assert_equal "text", translator.hover({ "contents" => { "value" => "text" } }, workspace_root: ROOT)[:markdown]
      assert_equal "a\n\nb",
                   translator.hover({ "contents" => [{ "value" => "a" }, { "value" => "b" }] },
                                     workspace_root: ROOT)[:markdown]
      assert_equal "plain", translator.hover({ "contents" => "plain" }, workspace_root: ROOT)[:markdown]
    end

    test "hover is nil when there is nothing to show" do
      assert_nil translator.hover({}, workspace_root: ROOT)[:markdown]
      assert_nil translator.hover(nil, workspace_root: ROOT)[:markdown]
    end

    test "hover escapes a leading '#' so a doc heading does not render as an <h1>" do
      markdown = translator.hover({ "contents" => { "value" => "## Title\nbody" } }, workspace_root: ROOT)[:markdown]
      assert_equal "\\## Title\nbody", markdown
    end

    test "hover does not escape '#' inside a fenced code block" do
      contents = "```ruby\n# a real comment\n```"
      markdown = translator.hover({ "contents" => { "value" => contents } }, workspace_root: ROOT)[:markdown]
      assert_equal contents, markdown
    end

    test "hover rewrites an in-workspace file link to the openDefinition command" do
      contents = "Definitions: [user.rb](file:///workspace/app/models/user.rb#L3,1-9,4)"
      markdown = translator.hover({ "contents" => { "value" => contents } }, workspace_root: ROOT)[:markdown]

      assert_includes markdown, "(command:mbeditor.openDefinition?"
      refute_includes markdown, "file://"
    end

    test "hover demotes a gem/stdlib file link to a plain code span instead of a dead link" do
      contents = "Definitions: [set.rb](file:///usr/lib/ruby/3.3/set.rb#L10,1-10,4)"
      markdown = translator.hover({ "contents" => { "value" => contents } }, workspace_root: ROOT)[:markdown]

      assert_equal "Definitions: `set.rb`", markdown
    end

    # ── completion ──────────────────────────────────────────────────────────

    def completion_item(overrides = {})
      { "label" => "puts", "kind" => 3, "insertText" => "puts", "detail" => "Kernel#puts" }.merge(overrides)
    end

    test "completion maps known LSP kinds and falls back to Text" do
      assert_equal "Function", translator.completion({ "items" => [completion_item] })[:suggestions].first[:kind]
      assert_equal "Text", translator.completion({ "items" => [completion_item("kind" => 999)] })[:suggestions].first[:kind]
    end

    test "completion prefers a textEdit's newText over insertText and label" do
      item = completion_item("textEdit" => { "newText" => "puts(" })
      assert_equal "puts(", translator.completion({ "items" => [item] })[:suggestions].first[:insertText]
    end

    test "completion flags snippet-format items" do
      item = completion_item("insertTextFormat" => 2)
      assert_equal true, translator.completion({ "items" => [item] })[:suggestions].first[:isSnippet]
      assert_equal false, translator.completion({ "items" => [completion_item] })[:suggestions].first[:isSnippet]
    end

    test "completion accepts a bare array and caps at 100 items" do
      many = Array.new(150) { completion_item }
      assert_equal 100, translator.completion(many)[:suggestions].length
    end

    # ── raw (URI sanitization) ──────────────────────────────────────────────

    test "raw rewrites an in-workspace file:// URI to a workspace-relative path" do
      node = { "uri" => "file:///workspace/app/models/user.rb", "range" => {} }
      result = translator.raw(node, workspace_root: ROOT)[:result]
      assert_equal "app/models/user.rb", result["uri"]
    end

    test "raw drops any object whose URI points outside the workspace" do
      node = [{ "uri" => "file:///etc/passwd" }, { "uri" => "file:///workspace/ok.rb" }]
      result = translator.raw(node, workspace_root: ROOT)[:result]
      assert_equal [{ "uri" => "ok.rb" }], result
    end

    test "raw unescapes a percent-encoded URI before matching the workspace prefix" do
      # A checkout with a space in its path previously matched nothing here.
      node = { "uri" => "file:///workspace/a%20b/file.rb" }
      result = translator.raw(node, workspace_root: ROOT)[:result]
      assert_equal "a b/file.rb", result["uri"]
    end

    test "raw leaves non-URI values alone" do
      node = { "kind" => "full", "count" => 3, "ok" => true, "nothing" => nil }
      assert_equal node, translator.raw(node, workspace_root: ROOT)[:result]
    end

    test "raw sanitizes file:// links embedded inside markdown strings, not just uri keys" do
      node = { "value" => "See file:///etc/shadow for details" }
      result = translator.raw(node, workspace_root: ROOT)[:result]
      assert_equal "See (external) for details", result["value"]
    end

    test "raw bounds recursion so a pathologically nested payload cannot hang the request" do
      nesting = RubyLspResultTranslator::MAX_LSP_DEPTH + 5
      deep = { "uri" => "file:///workspace/ok.rb" }
      nesting.times { deep = { "child" => deep } }

      result = translator.raw(deep, workspace_root: ROOT)[:result]

      observed_depth = 0
      node = result
      observed_depth += 1 while node.is_a?(Hash) && (node = node["child"])

      assert_operator observed_depth, :<, nesting, "content past MAX_LSP_DEPTH must be truncated, not walked in full"
    end
  end
end
