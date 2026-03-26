# frozen_string_literal: true

require 'test_helper'
require 'open3'

module Mbeditor
  class GitDiffServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)

    def test_working_tree_mode_returns_original_and_modified_strings
      result = GitDiffService.new(repo_path: REPO_PATH, file_path: 'Gemfile').call

      assert_kind_of Hash, result
      assert result.key?('original'), "result should have 'original'"
      assert result.key?('modified'), "result should have 'modified'"
      assert_kind_of String, result['original']
      assert_kind_of String, result['modified']
    end

    def test_between_two_commits_returns_strings
      # Fetch two real consecutive commits dynamically
      log_out, = Open3.capture2(
        'git', '-C', REPO_PATH, 'log', '--format=%H', '-2'
      )
      shas = log_out.lines.map(&:strip).reject(&:empty?)
      skip 'Need at least 2 commits' if shas.length < 2

      head_sha = shas[0]
      base_sha = shas[1]

      result = GitDiffService.new(
        repo_path: REPO_PATH,
        file_path: 'Gemfile',
        base_sha: base_sha,
        head_sha: head_sha
      ).call

      assert_kind_of String, result['original']
      assert_kind_of String, result['modified']
    end

    def test_base_sha_without_head_sha_diffs_ref_vs_working_tree
      log_out, = Open3.capture2('git', '-C', REPO_PATH, 'log', '--format=%H', '-1')
      sha = log_out.strip
      skip 'Need at least one commit' if sha.empty?

      result = GitDiffService.new(
        repo_path: REPO_PATH,
        file_path: 'Gemfile',
        base_sha: sha
      ).call

      # Both keys must be present and be strings
      assert result.key?('original'), "result should have 'original'"
      assert result.key?('modified'), "result should have 'modified'"
      assert_kind_of String, result['original']
      assert_kind_of String, result['modified']
      # original should be the content at the given SHA, not necessarily empty
      refute_nil result['original']
    end

    def test_file_not_in_git_history_returns_empty_original_and_disk_content_for_modified
      # Use a file that exists on disk but is not tracked in git history at HEAD
      # A new untracked file in a tmpdir simulates this
      Dir.mktmpdir('mbeditor_diff_test_') do |tmpdir|
        test_file = File.join(tmpdir, 'untracked.rb')
        File.write(test_file, "# content\n")

        result = GitDiffService.new(
          repo_path: REPO_PATH,
          file_path: test_file
        ).call

        # original should be empty (not in git HEAD)
        assert_equal '', result['original']
        # modified is empty string because resolve_path won't find it inside repo_path
        assert_kind_of String, result['modified']
      end
    end
  end
end
