# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class LspDiagnosticsTranslatorTest < ActiveSupport::TestCase
    def diagnostic(overrides = {})
      {
        "source" => "RuboCop",
        "code" => "Layout/SpaceAroundOperators",
        "severity" => 3,
        "message" => "Surrounding space missing.",
        "range" => { "start" => { "line" => 2, "character" => 4 },
                     "end" => { "line" => 2, "character" => 5 } },
        "data" => { "correctable" => true }
      }.merge(overrides)
    end

    def translate(items)
      LspDiagnosticsTranslator.call({ "kind" => "full", "items" => items })
    end

    def first_marker(overrides = {})
      translate([diagnostic(overrides)])[:markers].first
    end

    test "converts 0-based LSP ranges to 1-based marker positions" do
      marker = first_marker

      assert_equal 3, marker[:startLine]
      assert_equal 5, marker[:startCol]
      assert_equal 3, marker[:endLine]
      assert_equal 6, marker[:endCol]
    end

    test "maps every LSP severity into the marker severity domain" do
      assert_equal "error",   first_marker("severity" => 1)[:severity]
      assert_equal "warning", first_marker("severity" => 2)[:severity]
      assert_equal "info",    first_marker("severity" => 3)[:severity]
      assert_equal "info",    first_marker("severity" => 4)[:severity]
      assert_equal "info",    first_marker("severity" => nil)[:severity], "unknown severity degrades to info"
    end

    test "extracts the cop name from string, integer, and CodeDescription forms" do
      assert_equal "Style/Foo", first_marker("code" => "Style/Foo")[:copName]
      assert_equal "1234", first_marker("code" => 1234)[:copName]
      assert_equal "Style/Bar", first_marker("code" => { "value" => "Style/Bar" })[:copName]
      assert_equal "", first_marker("code" => nil)[:copName]
    end

    test "only RuboCop-sourced diagnostics claim the rubocop source" do
      assert_equal "rubocop", first_marker("source" => "RuboCop")[:source]
      assert_equal "rubocop", first_marker("source" => "rubocop")[:source]
      assert_equal "prism", first_marker("source" => "Prism")[:source]
      assert_equal "", first_marker("source" => nil)[:source]
    end

    test "correctable is true only when the data payload says so" do
      assert_equal true, first_marker[:correctable]
      assert_equal false, first_marker("data" => { "correctable" => false })[:correctable]
      assert_equal false, first_marker("data" => nil)[:correctable]
      assert_equal false, first_marker("data" => {})[:correctable]
    end

    test "prefixes the message with the cop name and strips the uncorrectable notice" do
      marker = first_marker("message" => "Do not do that.\n\nThis offense is not auto-correctable.\n")
      assert_equal "[Layout/SpaceAroundOperators] Do not do that.", marker[:message]

      bare = first_marker("code" => nil, "message" => "unexpected end-of-input")
      assert_equal "unexpected end-of-input", bare[:message], "no cop name means no bracket prefix"
    end

    test "guards against inverted or empty ranges" do
      marker = first_marker("range" => { "start" => { "line" => 5, "character" => 9 },
                                         "end" => { "line" => 1, "character" => 0 } })
      assert_equal 6, marker[:startLine]
      assert_equal 6, marker[:endLine], "an end before the start collapses onto the start line"
      assert_operator marker[:endCol], :>, marker[:startCol], "zero-width markers would be invisible"
    end

    test "accepts a bare array, a full report, and nil" do
      assert_equal 1, LspDiagnosticsTranslator.call([diagnostic])[:markers].length
      assert_equal 1, translate([diagnostic])[:markers].length
      assert_equal [], LspDiagnosticsTranslator.call(nil)[:markers]
      assert_equal 0, LspDiagnosticsTranslator.call(nil)[:summary]["offense_count"]
    end

    test "skips malformed entries and counts what survives" do
      result = LspDiagnosticsTranslator.call([diagnostic, "not a hash", nil])

      assert_equal 1, result[:markers].length
      assert_equal 1, result[:summary]["offense_count"]
    end
  end
end
