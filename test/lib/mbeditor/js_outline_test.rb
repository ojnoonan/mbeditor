# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # This parser suite skips in minimal compatibility bundles.
end

module Mbeditor
  # JsOutline translates the TypeScript worker's navigation tree, so the fixtures
  # here are trees in the shape that `getNavigationTree` returns. Offsets stand in
  # for source positions: `lineAt` maps offset -> line by dividing by 100, so an
  # item at offset 300 lands on line 4.
  class JsOutlineTest < ActiveSupport::TestCase
    def setup
      skip "MiniRacer is not installed in this compatibility bundle" unless defined?(::MiniRacer)

      @context = MiniRacer::Context.new
      @context.eval("var window = this;")
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/js_outline.js")))
      @context.eval(<<~JAVASCRIPT)
        function outline(root, sources) {
          return JsOutline.fromNavigationTree(root, {
            lineAt: function (offset) { return Math.floor(offset / 100) + 1; },
            textAt: function (offset) { return sources[String(offset)] || ''; }
          });
        }
      JAVASCRIPT
    end

    def item(text, kind, offset, named: true, children: nil, length: 10)
      node = { "text" => text, "kind" => kind, "kindModifiers" => "",
               "spans" => [{ "start" => offset, "length" => length }] }
      node["nameSpan"] = { "start" => offset, "length" => text.length } if named
      node["childItems"] = children if children
      node
    end

    def outline(root, sources = {})
      @context.eval("outline(#{root.to_json}, #{sources.to_json})")
    end

    def entries(root, sources = {})
      outline(root, sources).fetch("entries")
    end

    def root(children)
      { "text" => "<global>", "kind" => "script", "spans" => [{ "start" => 0, "length" => 999 }],
        "childItems" => children }
    end

    test "lists functions and classes with their members nested" do
      result = entries(root([
        item("Thing", "class", 200, children: [
          item("constructor", "constructor", 300, named: false),
          item("method", "method", 400),
          item("prop", "getter", 500)
        ]),
        item("classic", "function", 100)
      ]))

      assert_equal(
        [
          { "line" => 2, "name" => "classic",     "kind" => "method", "depth" => 0, "visibility" => nil },
          { "line" => 3, "name" => "Thing",       "kind" => "suite",  "depth" => 0, "visibility" => nil },
          { "line" => 4, "name" => "constructor", "kind" => "method", "depth" => 1, "visibility" => nil },
          { "line" => 5, "name" => "method",      "kind" => "method", "depth" => 1, "visibility" => nil },
          { "line" => 6, "name" => "prop",        "kind" => "method", "depth" => 1, "visibility" => nil }
        ],
        result
      )
    end

    test "reorders alphabetised children into source order" do
      # getNavigationTree sorts children by name; the outline must follow the file.
      names = entries(root([
        item("alpha", "function", 500),
        item("beta",  "function", 100),
        item("gamma", "function", 300)
      ])).map { |e| e["name"] }

      assert_equal %w[beta gamma alpha], names
    end

    test "admits variables that hold functions and drops the rest" do
      tree = root([
        item("Widget",      "const", 0),
        item("helper",      "const", 100),
        item("shorthand",   "let",   200),
        item("plainNumber", "const", 300),
        item("dataObj",     "const", 400),
        item("built",       "const", 500)
      ])
      sources = {
        "0"   => "Widget = () => <div />",
        "100" => "helper = function () { return 1; }",
        "200" => "shorthand = value => value",
        "300" => "plainNumber = 5",
        "400" => "dataObj = { a: 1 }",
        "500" => "built = makeThing(() => 1)"
      }

      assert_equal %w[Widget helper shorthand], entries(tree, sources).map { |e| e["name"] }
    end

    test "drops anonymous callbacks but keeps the declarations inside them" do
      result = entries(root([
        item("useEffect() callback", "function", 100, named: false, children: [
          item("onTick", "function", 200)
        ]),
        item("default", "const", 300, named: false)
      ]))

      # onTick survives at depth 0 — the skipped callback must not nest it.
      assert_equal(
        [{ "line" => 3, "name" => "onTick", "kind" => "method", "depth" => 0, "visibility" => nil }],
        result
      )
    end

    test "an empty or missing tree yields no entries" do
      assert_equal({ "entries" => [], "truncated" => false }, outline(root([])))
      assert_equal({ "entries" => [], "truncated" => false }, @context.eval("outline(null, {})"))
    end

    test "caps entries and reports truncation" do
      cap = @context.eval("JsOutline.MAX_ENTRIES")
      children = Array.new(cap + 5) { |i| item("fn#{i}", "function", i * 100) }
      result = outline(root(children))

      assert_equal cap, result.fetch("entries").length
      assert_equal true, result.fetch("truncated")
    end
  end
end
