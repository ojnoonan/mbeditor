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
      assert_equal "hint",    first_marker("severity" => 4)[:severity]
      assert_equal "info",    first_marker("severity" => nil)[:severity], "unknown severity degrades to info"
    end

    test "INFORMATION and HINT stay distinct so convention offenses outrank rubocop info" do
      refute_equal first_marker("severity" => 3)[:severity], first_marker("severity" => 4)[:severity]
    end

    test "flags cops that mean dead code so the editor can fade them" do
      %w[
        Lint/UselessAssignment
        Lint/UnusedMethodArgument
        Lint/UnusedBlockArgument
        Lint/UnreachableCode
        Style/RedundantSelf
        Lint/DeprecatedClassMethods
      ].each do |cop|
        assert LspDiagnosticsTranslator.unnecessary?(cop), "#{cop} should be treated as unnecessary"
        assert_equal true, first_marker("code" => cop)[:unnecessary]
      end
    end

    test "does not flag cops that mean the code is wrong rather than absent" do
      %w[
        Layout/SpaceAroundOperators
        Style/StringLiterals
        Metrics/MethodLength
        Lint/Void
      ].each do |cop|
        refute LspDiagnosticsTranslator.unnecessary?(cop), "#{cop} should not be faded"
        assert_equal false, first_marker("code" => cop)[:unnecessary]
      end

      assert_equal false, first_marker("code" => nil)[:unnecessary], "a missing cop name is not unnecessary"
    end

    test "passes through the RuboCop documentation URL when the server sends one" do
      href = "https://docs.rubocop.org/rubocop/cops_layout.html#layoutspacearoundoperators"
      # camelCase — the LSP wire key, not the Ruby keyword argument name. The
      # snake_case spelling silently yields nil.
      assert_equal href, first_marker("codeDescription" => { "href" => href })[:codeHref]

      assert_nil first_marker[:codeHref], "no codeDescription means no link"
      assert_nil first_marker("codeDescription" => {})[:codeHref]
      assert_nil first_marker("codeDescription" => nil)[:codeHref]
      assert_nil first_marker("code_description" => { "href" => href })[:codeHref],
                 "snake_case is not the wire key and must not be read"
    end

    test "fades Prism's cop-less dead-code warnings, which duplicate the RuboCop ones" do
      # Both land on the same range; fading only the RuboCop marker leaves the
      # Prism squiggle drawn over it and nothing appears greyed out.
      %w[
        assigned\ but\ unused\ variable\ -\ total
        statement\ not\ reached
      ].each do |message|
        marker = first_marker("source" => "Prism", "code" => nil, "message" => message)
        assert_equal true, marker[:unnecessary], "#{message.inspect} should fade"
      end

      assert_equal false,
                   first_marker("source" => "Prism", "code" => nil,
                                "message" => "unexpected end-of-input")[:unnecessary]
    end

    test "a cop name never has its message consulted for the unnecessary tag" do
      # Otherwise a cop whose description happens to say "unused" would fade.
      marker = first_marker("code" => "Metrics/MethodLength",
                            "message" => "assigned but unused variable - x")
      assert_equal false, marker[:unnecessary]
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
