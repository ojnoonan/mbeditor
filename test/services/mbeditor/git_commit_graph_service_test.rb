# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitCommitGraphServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../../..', __dir__)

    def service
      GitCommitGraphService.new(repo_path: REPO_PATH)
    end

    def test_happy_path_returns_non_empty_array
      result = service.call
      assert_kind_of Array, result
      refute_empty result
    end

    def test_each_entry_has_expected_keys
      result = service.call
      entry = result.first

      assert entry.key?('hash'),    "entry should have 'hash'"
      assert entry.key?('parents'), "entry should have 'parents'"
      assert entry.key?('title'),   "entry should have 'title'"
      assert entry.key?('author'),  "entry should have 'author'"
      assert entry.key?('date'),    "entry should have 'date'"
      assert entry.key?('isLocal'), "entry should have 'isLocal'"
      assert_kind_of Array, entry['parents']
    end

    def test_is_local_is_a_boolean
      result = service.call
      result.each do |entry|
        assert_includes [true, false], entry['isLocal'],
                        "isLocal should be true or false, got #{entry['isLocal'].inspect}"
      end
    end

    def test_result_length_does_not_exceed_max_commits
      result = service.call
      assert_operator result.length, :<=, GitCommitGraphService::MAX_COMMITS
    end
  end
end
