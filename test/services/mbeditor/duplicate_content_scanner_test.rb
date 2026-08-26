# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Mbeditor
  class DuplicateContentScannerTest < Minitest::Test
    def body(prefix = "")
      (1..25).map { |i| "#{prefix}line #{i}\n" }.join
    end

    # the exact shape a double-seeded save leaves on disk: X + X

    def test_check_flags_a_file_that_is_two_copies_of_itself
      hit = DuplicateContentScanner.check(body + body)

      assert_equal :exact, hit[:reason]
    end

    # edited since the corruption, so no longer byte-symmetric — the opening
    # block still appears twice

    def test_check_flags_a_repeated_opening_block
      hit = DuplicateContentScanner.check("#{body}tail edit\n#{body}")

      assert_equal :repeated_block, hit[:reason]
      assert_equal 27, hit[:line]
    end

    def test_check_passes_a_normal_file
      assert_nil DuplicateContentScanner.check(body)
    end

    def test_check_ignores_short_files
      assert_nil DuplicateContentScanner.check("a\nb\n" * 2)
    end

    # a block of near-identical lines repeats for boring reasons

    def test_check_ignores_a_low_variety_anchor
      assert_nil DuplicateContentScanner.check(("x\n" * 20) + "tail\n" + ("x\n" * 20))
    end

    def test_call_reports_duplicated_files_and_skips_clean_ones
      Dir.mktmpdir do |root|
        File.write(File.join(root, "bad.rb"), body + body)
        File.write(File.join(root, "good.rb"), body)
        Dir.mkdir(File.join(root, "tmp"))
        File.write(File.join(root, "tmp", "excluded.rb"), body + body)

        findings = DuplicateContentScanner.new(root, excluded: ["tmp"]).call

        assert_equal ["bad.rb"], findings.map(&:path)
        assert_equal :exact, findings.first.reason
      end
    end

    def test_call_skips_binary_files
      Dir.mktmpdir do |root|
        blob = "\x00\x01binary\x00"
        File.binwrite(File.join(root, "blob.bin"), blob * 40)

        assert_equal [], DuplicateContentScanner.new(root, excluded: []).call
      end
    end
  end
end
