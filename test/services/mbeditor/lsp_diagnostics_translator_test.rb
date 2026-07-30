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

    def translate(items, uri = nil)
      LspDiagnosticsTranslator.call({ "kind" => "full", "items" => items }, uri)
    end

    def first_marker(overrides = {}, uri = nil)
      translate([diagnostic(overrides)], uri)[:markers].first
    end

    URI = "file:///workspace/app/models/user.rb"

    def action(uri: URI, title: "Autocorrect Layout/SpaceAroundOperators", new_text: " = ")
      { "title" => title,
        "kind" => "quickfix",
        "edit" => { "documentChanges" => [
          { "textDocument" => { "version" => nil, "uri" => uri },
            "edits" => [
              { "range" => { "start" => { "line" => 2, "character" => 4 },
                             "end" => { "line" => 2, "character" => 5 } },
                "newText" => new_text }
            ] }
        ] } }
    end

    def fixes_for(actions, uri: URI)
      first_marker({ "data" => { "correctable" => true, "code_actions" => actions } }, uri)[:fixes]
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

    # ── embedded code actions ────────────────────────────────────────────────
    # ruby-lsp's codeAction handler only echoes back what the client sent it, so
    # these edits are lifted straight off the diagnostic and applied with no
    # further request. That makes this a trust boundary.

    test "lifts embedded fixes and converts their edits to 1-based" do
      fixes = fixes_for([action])

      assert_equal 1, fixes.length
      assert_equal "Autocorrect Layout/SpaceAroundOperators", fixes.first[:title]

      edit = fixes.first[:edits].first
      assert_equal 3, edit[:startLine], "0-based LSP line 2 becomes 1-based 3"
      assert_equal 5, edit[:startCol]
      assert_equal 3, edit[:endLine]
      assert_equal 6, edit[:endCol]
      assert_equal " = ", edit[:text]
    end

    test "keeps every action the server offers, including disable-for-this-line" do
      fixes = fixes_for([action, action(title: "Disable Layout/SpaceAroundOperators for this line")])

      assert_equal ["Autocorrect Layout/SpaceAroundOperators",
                    "Disable Layout/SpaceAroundOperators for this line"],
                   fixes.map { |f| f[:title] }
    end

    test "drops any action carrying an edit for another document" do
      assert_nil fixes_for([action(uri: "file:///etc/passwd")]),
                 "an action that edits another file must never reach the editor"

      # One foreign edit poisons the whole action, not just that edit.
      mixed = action
      mixed["edit"]["documentChanges"] << {
        "textDocument" => { "uri" => "file:///etc/passwd" },
        "edits" => [{ "range" => { "start" => { "line" => 0, "character" => 0 },
                                   "end" => { "line" => 0, "character" => 1 } },
                      "newText" => "x" }]
      }
      assert_nil fixes_for([mixed])
    end

    test "drops an edit whose replacement is absurdly large" do
      huge = action(new_text: "x" * (LspDiagnosticsTranslator::MAX_EDIT_BYTES + 1))
      assert_nil fixes_for([huge]), "an action with no surviving edits is dropped entirely"
    end

    test "caps how many actions one diagnostic can contribute" do
      many = Array.new(LspDiagnosticsTranslator::MAX_CODE_ACTIONS + 3) { action }
      assert_equal LspDiagnosticsTranslator::MAX_CODE_ACTIONS, fixes_for(many).length
    end

    test "omits fixes entirely when there is nothing to apply" do
      assert_nil first_marker({}, URI)[:fixes], "no code_actions means no key at all"
      assert_nil fixes_for([])
      assert_nil fixes_for(["not a hash", nil])
      assert_nil fixes_for([{ "title" => "No edit attached" }])
    end

    test "without a request URI no embedded fix is ever trusted" do
      # Nothing to compare the edit targets against, so nothing is accepted.
      assert_nil first_marker({ "data" => { "code_actions" => [action] } })[:fixes]
    end

    test "skips malformed entries and counts what survives" do
      result = LspDiagnosticsTranslator.call([diagnostic, "not a hash", nil])

      assert_equal 1, result[:markers].length
      assert_equal 1, result[:summary]["offense_count"]
    end
  end
end
