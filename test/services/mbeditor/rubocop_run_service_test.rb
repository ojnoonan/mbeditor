# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RubocopRunServiceTest < Minitest::Test
    JSON_OUT = {
      "files" => [
        { "path" => "b.rb", "offenses" => [] },
        { "path" => "a.rb", "offenses" => [{
          "cop_name" => "Layout/TrailingWhitespace", "message" => "Trailing whitespace.",
          "severity" => "convention", "correctable" => true, "corrected" => false,
          "location" => { "start_line" => 3, "start_column" => 9 }
        }] }
      ],
      "summary" => { "offense_count" => 1 }
    }.to_json

    def test_parses_and_drops_clean_files
      # Bundler chatter in front of the JSON is the normal case, not the edge one.
      result = RubocopRunService.parse("Warning: something\n#{JSON_OUT}")

      assert result[:ok]
      assert_equal ["a.rb"], result[:files].map { |f| f[:path] }
      assert_equal 1, result[:correctable]
      offense = result[:files][0][:offenses][0]
      assert_equal 3, offense[:line]
      assert_equal 9, offense[:column]
      assert offense[:correctable]
    end

    def test_no_json_is_an_error_not_a_crash
      result = RubocopRunService.parse("", "bundler: command not found: rubocop")

      refute result[:ok]
      assert_equal [], result[:files]
      assert_match(/command not found/, result[:error])
    end
  end
end
