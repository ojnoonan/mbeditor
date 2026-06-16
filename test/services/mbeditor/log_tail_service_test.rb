# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Mbeditor
  class LogTailServiceTest < ActiveSupport::TestCase
    test "returns empty result when the log file does not exist" do
      Dir.mktmpdir do |dir|
        svc = LogTailService.new(File.join(dir, "missing.log"))
        result = svc.read_since(0)
        assert_equal [], result[:lines]
        assert_equal 0, result[:offset]
        assert_equal false, result[:reset]
      end
    end

    test "initial load (nil offset) returns existing complete lines and reset: true" do
      with_log("a\nb\nc\n") do |svc, _path|
        result = svc.read_since(nil)
        assert_equal %w[a b c], result[:lines]
        assert_equal 6, result[:offset]
        assert_equal true, result[:reset]
      end
    end

    test "read_since advances offset and only returns newly appended complete lines" do
      with_log("a\nb\n") do |svc, path|
        first = svc.read_since(nil)
        File.open(path, "a") { |f| f.write("c\nd\n") }
        second = svc.read_since(first[:offset])
        assert_equal %w[c d], second[:lines]
        assert_equal 8, second[:offset]
        assert_equal false, second[:reset]
      end
    end

    test "never emits a partial trailing line; it is delivered once the newline arrives" do
      with_log("a\n", offset_after: true) do |svc, path|
        File.open(path, "a") { |f| f.write("partial") }
        mid = svc.read_since(2)
        assert_equal [], mid[:lines]
        assert_equal 2, mid[:offset], "offset must not advance past an incomplete line"

        File.open(path, "a") { |f| f.write("-done\n") }
        done = svc.read_since(mid[:offset])
        assert_equal ["partial-done"], done[:lines]
      end
    end

    test "detects truncation/rotation: offset past EOF resets to start" do
      with_log("old long content\n") do |svc, path|
        File.write(path, "new\n") # shrinks file below the previous offset
        result = svc.read_since(50)
        assert_equal %w[new], result[:lines]
        assert_equal 4, result[:offset]
        assert_equal true, result[:reset]
      end
    end

    test "caps bytes per read so a huge append is delivered across calls" do
      with_log("") do |svc, path|
        big = (["x" * 99] * 4000).join("\n") + "\n" # ~400 KB, > BYTE_CAP
        File.write(path, big)
        first = svc.read_since(0)
        assert first[:offset] < big.bytesize, "should not consume the whole file at once"
        assert first[:lines].length.positive?
        second = svc.read_since(first[:offset])
        assert second[:lines].length.positive?
      end
    end

    private

    def with_log(content, offset_after: false)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "development.log")
        File.write(path, content)
        yield LogTailService.new(path), path
      end
    end
  end
end
