# frozen_string_literal: true

require "test_helper"
require "open3"

module Mbeditor
  class GitCommitDetailServiceTest < Minitest::Test
    REPO_PATH = File.expand_path("../../..", __dir__)

    def known_sha
      out, = Open3.capture2("git", "-C", REPO_PATH, "log", "--format=%H", "-1")
      out.strip.tap { |s| skip "No commits found" if s.empty? }
    end

    def test_call_returns_files_as_array
      result = GitCommitDetailService.new(repo_path: REPO_PATH, sha: known_sha).call

      assert result.key?("files"), "result should have 'files' key"
      assert_kind_of Array, result["files"]
    end

    def test_file_entries_have_numeric_added_and_removed
      result = GitCommitDetailService.new(repo_path: REPO_PATH, sha: known_sha).call

      skip "commit has no file changes" if result["files"].empty?

      result["files"].each do |file|
        assert file.key?("added"),   "file entry missing 'added'"
        assert file.key?("removed"), "file entry missing 'removed'"
        assert_kind_of Integer, file["added"]
        assert_kind_of Integer, file["removed"]
      end
    end

    def test_file_entries_have_status_and_path
      result = GitCommitDetailService.new(repo_path: REPO_PATH, sha: known_sha).call

      skip "commit has no file changes" if result["files"].empty?

      result["files"].each do |file|
        assert file.key?("status"), "file entry missing 'status'"
        assert file.key?("path"),   "file entry missing 'path'"
        refute_empty file["status"]
        refute_empty file["path"]
      end
    end

    def test_call_returns_non_blank_metadata_for_known_sha
      result = GitCommitDetailService.new(repo_path: REPO_PATH, sha: known_sha).call

      assert_kind_of Hash, result
      refute_empty result["title"],  "title should be non-blank"
      refute_empty result["author"], "author should be non-blank"
      refute_empty result["date"],   "date should be non-blank"
    end
  end
end
