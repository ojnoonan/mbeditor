# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitBlameServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)
    FILE_PATH = 'Gemfile'.freeze

    def test_happy_path_returns_array_with_expected_keys
      result = GitBlameService.new(repo_path: REPO_PATH, file_path: FILE_PATH).call

      assert_kind_of Array, result
      refute_empty result

      first = result.first
      assert first.key?('line'),    "blame entry should have 'line'"
      assert first.key?('sha'),     "blame entry should have 'sha'"
      assert first.key?('author'),  "blame entry should have 'author'"
      assert first.key?('content'), "blame entry should have 'content'"
    end

    def test_each_line_has_40_char_hex_sha
      result = GitBlameService.new(repo_path: REPO_PATH, file_path: FILE_PATH).call

      result.each do |entry|
        assert_match(/\A[0-9a-f]{40}\z/, entry['sha'],
                     "sha should be 40 hex chars, got: #{entry['sha'].inspect}")
      end
    end

    def test_each_line_has_integer_line_number
      result = GitBlameService.new(repo_path: REPO_PATH, file_path: FILE_PATH).call

      result.each do |entry|
        assert_kind_of Integer, entry['line']
        assert_operator entry['line'], :>, 0
      end
    end

    def test_non_existent_file_raises_runtime_error
      assert_raises(RuntimeError) do
        GitBlameService.new(
          repo_path: REPO_PATH,
          file_path: 'this_file_does_not_exist_anywhere.rb'
        ).call
      end
    end

    # -------------------------------------------------------------------------
    # parse_porcelain — unit tests with crafted output
    # -------------------------------------------------------------------------

    SHA1 = 'a' * 40
    SHA2 = 'b' * 40

    def service
      GitBlameService.new(repo_path: '/fake', file_path: 'fake.rb')
    end

    def parse(output)
      service.send(:parse_porcelain, output)
    end

    def test_parse_porcelain_single_entry
      output = "#{SHA1} 1 1 1\n" \
               "author John Doe\n" \
               "author-mail <john@example.com>\n" \
               "author-time 1000000000\n" \
               "author-tz +0000\n" \
               "summary First commit\n" \
               "filename foo.rb\n" \
               "\thello world\n"

      result = parse(output)

      assert_equal 1, result.length
      assert_equal 1,             result[0]['line']
      assert_equal SHA1,          result[0]['sha']
      assert_equal 'John Doe',    result[0]['author']
      assert_equal 'john@example.com', result[0]['email']
      assert_equal 'First commit', result[0]['summary']
      assert_equal 'hello world', result[0]['content']
    end

    def test_parse_porcelain_repeated_sha_fills_metadata_from_cache
      # Second occurrence of the same commit sha has no metadata lines —
      # the parser should look up cached data from the first occurrence.
      output = "#{SHA1} 1 1 2\n" \
               "author Jane Smith\n" \
               "author-mail <jane@example.com>\n" \
               "author-time 1000000001\n" \
               "author-tz +0000\n" \
               "summary Initial\n" \
               "filename foo.rb\n" \
               "\tline one\n" \
               "#{SHA1} 2 2\n" \
               "\tline two\n"

      result = parse(output)

      assert_equal 2, result.length
      assert_equal 1, result[0]['line']
      assert_equal 2, result[1]['line']
      # Both entries should carry the same author from the cached metadata
      assert_equal 'Jane Smith', result[0]['author']
      assert_equal 'Jane Smith', result[1]['author']
      assert_equal 'line one',   result[0]['content']
      assert_equal 'line two',   result[1]['content']
    end

    def test_parse_porcelain_two_distinct_commits
      output = "#{SHA1} 1 1 1\n" \
               "author Alice\n" \
               "author-mail <alice@example.com>\n" \
               "author-time 1000000000\n" \
               "author-tz +0000\n" \
               "summary Commit A\n" \
               "filename foo.rb\n" \
               "\tfirst line\n" \
               "#{SHA2} 2 2 1\n" \
               "author Bob\n" \
               "author-mail <bob@example.com>\n" \
               "author-time 1000000001\n" \
               "author-tz +0000\n" \
               "summary Commit B\n" \
               "filename foo.rb\n" \
               "\tsecond line\n"

      result = parse(output)

      assert_equal 2,          result.length
      assert_equal 'Alice',    result[0]['author']
      assert_equal 'Bob',      result[1]['author']
      assert_equal 'first line',  result[0]['content']
      assert_equal 'second line', result[1]['content']
    end

    def test_parse_porcelain_incomplete_final_block_is_silently_dropped
      # The last block has no TAB content line — should be excluded from results,
      # not appended with missing fields.
      output = "#{SHA1} 1 1 1\n" \
               "author Alice\n" \
               "author-mail <alice@example.com>\n" \
               "author-time 1000000000\n" \
               "author-tz +0000\n" \
               "summary Complete entry\n" \
               "filename foo.rb\n" \
               "\tthe only complete line\n" \
               "#{SHA2} 2 2 1\n" \
               "author Bob\n" \
               "summary Incomplete — no content line follows\n"

      result = parse(output)

      assert_equal 1, result.length, 'incomplete final block must not be appended'
      assert_equal 'the only complete line', result[0]['content']
    end

    def test_parse_porcelain_empty_output_returns_empty_array
      assert_equal [], parse('')
    end
  end
end
