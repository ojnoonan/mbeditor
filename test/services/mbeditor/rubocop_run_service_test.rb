# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RubocopRunServiceTest < Minitest::Test
    JSON_OUT = {
      "files" => [
        { "path" => "b.rb", "offenses" => [] },
        { "path" => "vendor/bundle/ruby/3.4.0/gems/rack-3.1.8/lib/rack.rb", "offenses" => [{
          "cop_name" => "Style/Documentation", "message" => "Missing top-level documentation.",
          "severity" => "convention", "correctable" => true, "corrected" => false,
          "location" => { "start_line" => 1, "start_column" => 1 }
        }] },
        { "path" => "a.rb", "offenses" => [{
          "cop_name" => "Layout/TrailingWhitespace", "message" => "Trailing whitespace.",
          "severity" => "convention", "correctable" => true, "corrected" => false,
          "location" => { "start_line" => 3, "start_column" => 9 }
        }] }
      ],
      "summary" => { "offense_count" => 1 }
    }.to_json

    # Explicit patterns, not Mbeditor.configuration.excluded_paths: the config
    # is global and other tests move it, and what is under test here is the
    # filtering, not the default list.
    def matcher
      ExclusionMatcher.new(%w[vendor/bundle node_modules], root: Dir.pwd)
    end

    def test_parses_and_drops_clean_files
      # Bundler chatter in front of the JSON is the normal case, not the edge one.
      result = RubocopRunService.parse("Warning: something\n#{JSON_OUT}")

      assert result[:ok]
      # b.rb has no offenses; without a matcher nothing else is dropped.
      refute_includes result[:files].map { |f| f[:path] }, "b.rb"
      assert_includes result[:files].map { |f| f[:path] }, "a.rb"
      assert_equal 2, result[:correctable]
      offense = result[:files].find { |f| f[:path] == "a.rb" }[:offenses][0]
      assert_equal 3, offense[:line]
      assert_equal 9, offense[:column]
      assert offense[:correctable]
    end

    # A host .rubocop.yml that replaces AllCops/Exclude instead of merging it
    # drops RuboCop's own vendor exclusion, and the panel fills with gem source.
    def test_excluded_paths_are_dropped
      unfiltered = RubocopRunService.parse(JSON_OUT)
      filtered   = RubocopRunService.parse(JSON_OUT, nil, matcher)

      assert_includes unfiltered[:files].map { |f| f[:path] }, "vendor/bundle/ruby/3.4.0/gems/rack-3.1.8/lib/rack.rb"
      assert_equal ["a.rb"], filtered[:files].map { |f| f[:path] }
      assert_equal 1, filtered[:correctable]
    end

    # `rubocop -a` reports what it fixed alongside what it left, so the raw JSON
    # after a Fix run is byte-identical to the one before it. Left in, the panel
    # showed the same offenses and the Fix button stayed lit on offenses that
    # were already gone from disk — the "Fix does nothing" report.
    AUTOCORRECT_OUT = {
      "files" => [
        { "path" => "a.rb", "offenses" => [
          { "cop_name" => "Layout/ExtraSpacing", "message" => "Unnecessary spacing detected.",
            "severity" => "convention", "correctable" => true, "corrected" => true,
            "location" => { "start_line" => 2, "start_column" => 5 } },
          # `-a` skips cops whose autocorrect is unsafe, and RuboCop still calls
          # them correctable — this is the one that kept the button lit forever.
          { "cop_name" => "Style/FrozenStringLiteralComment", "message" => "Missing frozen string literal comment.",
            "severity" => "convention", "correctable" => true, "corrected" => false,
            "location" => { "start_line" => 1, "start_column" => 1 } }
        ] }
      ],
      "summary" => { "offense_count" => 2 }
    }.to_json

    def test_corrected_offenses_are_dropped_and_stop_counting_as_correctable
      result = RubocopRunService.parse(AUTOCORRECT_OUT, nil, nil, mode: :autocorrect)

      offenses = result[:files].find { |f| f[:path] == "a.rb" }[:offenses]
      assert_equal ["Style/FrozenStringLiteralComment"], offenses.map { |o| o[:copName] }
      # Nothing safe autocorrect can still fix, so the Fix button must go dark.
      assert_equal 0, result[:correctable]
    end

    def test_check_mode_still_reports_correctable
      result = RubocopRunService.parse(AUTOCORRECT_OUT)

      assert_equal 1, result[:correctable]
    end

    def test_no_json_is_an_error_not_a_crash
      result = RubocopRunService.parse("", "bundler: command not found: rubocop")

      refute result[:ok]
      assert_equal [], result[:files]
      assert_match(/command not found/, result[:error])
    end
  end
end
