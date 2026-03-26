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
  end
end
