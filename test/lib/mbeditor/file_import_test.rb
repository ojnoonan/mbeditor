# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # This suite skips in minimal compatibility bundles.
end

module Mbeditor
  # file_import.js is plain ES5 with no DOM access at load time, so the pure
  # helpers can be exercised directly. suggestDestinations is the one piece of
  # real logic: it decides where a picked folder actually belongs by matching
  # its relative paths as suffixes of the workspace tree.
  class FileImportTest < ActiveSupport::TestCase
    def setup
      skip "MiniRacer is not installed in this compatibility bundle" unless defined?(::MiniRacer)

      @context = MiniRacer::Context.new
      @context.eval("var window = this;")
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/file_import.js")))
    end

    # rels: relative paths of the picked files. docs: [path, type] pairs.
    def suggest(rels, docs)
      entries = rels.map { |r| { "relativePath" => r } }
      js_docs = docs.map { |path, type| { "path" => path, "type" => type } }
      @context.call("FileImport.suggestDestinations", entries, js_docs)
    end

    def file(path) = [path, "file"]
    def dir(path)  = [path, "dir"]

    test "suggests the prefix where the picked files already live" do
      docs = [
        dir("app/assets/javascripts/ux/component"),
        file("app/assets/javascripts/ux/component/button_component.js.jsx"),
        file("README.md")
      ]

      result = suggest(["ux/component/button_component.js.jsx"], docs)

      assert_equal "app/assets/javascripts", result.first["prefix"]
      assert_equal 1, result.first["files"]
    end

    test "matches the parent folder when the picked file itself is new" do
      docs = [
        dir("app/assets/javascripts/ux/component"),
        file("app/assets/javascripts/ux/component/existing.js")
      ]

      result = suggest(["ux/component/brand_new.js"], docs)

      assert_equal ["app/assets/javascripts"], result.map { |r| r["prefix"] }
      assert_equal 0, result.first["files"]
      assert_equal 1, result.first["dirs"]
    end

    test "an exact file match outranks a bare folder match" do
      docs = [
        dir("vendor/ux/component"),
        dir("app/assets/javascripts/ux/component"),
        file("app/assets/javascripts/ux/component/button.js")
      ]

      result = suggest(["ux/component/button.js"], docs)

      assert_equal %w[app/assets/javascripts vendor], result.map { |r| r["prefix"] }
    end

    test "prefixes are ranked by how many of the picked files they explain" do
      docs = [
        file("app/models/user.rb"),
        file("app/models/order.rb"),
        file("spec/models/user.rb")
      ]

      result = suggest(["models/user.rb", "models/order.rb"], docs)

      assert_equal %w[app spec], result.map { |r| r["prefix"] }
      assert_equal 2, result.first["files"]
    end

    test "the workspace root is never returned as a suggestion" do
      # A top-level match means the file is already where an unprefixed import
      # would put it — the root is offered by the dialog unconditionally, so
      # listing it here would just duplicate that option.
      result = suggest(["README.md"], [file("README.md")])

      assert_empty result
    end

    test "a partial path segment is not a match" do
      # 'ponent/button.js' must not match '.../component/button.js'.
      result = suggest(["ponent/button.js"], [file("app/component/button.js")])

      assert_empty result
    end

    test "returns nothing when the tree has no matching structure" do
      assert_empty suggest(["ux/component/button.js"], [file("README.md"), dir("lib")])
    end

    test "entriesFromFileList prefers webkitRelativePath over the bare name" do
      result = @context.call("FileImport.entriesFromFileList", [
        { "name" => "button.js", "webkitRelativePath" => "component/button.js" },
        { "name" => "loose.txt", "webkitRelativePath" => "" }
      ])

      assert_equal ["component/button.js", "loose.txt"],
                   result["entries"].map { |e| e["relativePath"] }
      assert_equal false, result["truncated"]
    end

    test "entriesFromFileList trims to the batch limit and says so" do
      files = Array.new(FileImport_max_entries(@context) + 5) do |i|
        { "name" => "f#{i}.txt", "webkitRelativePath" => "" }
      end

      result = @context.call("FileImport.entriesFromFileList", files)

      assert_equal FileImport_max_entries(@context), result["entries"].length
      assert_equal true, result["truncated"]
    end

    def FileImport_max_entries(context)
      context.eval("FileImport.MAX_ENTRIES")
    end
  end
end
