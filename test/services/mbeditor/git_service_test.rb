# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../../..', __dir__)

    # -------------------------------------------------------------------------
    # parse_git_log
    # -------------------------------------------------------------------------

    def test_parse_git_log_with_valid_input
      raw = "abc1234\x1fFix bug\x1fAlice\x1f2026-01-01T00:00:00Z\x1e" \
            "def5678\x1fAdd feature\x1fBob\x1f2026-01-02T00:00:00Z\x1e"

      result = GitService.parse_git_log(raw)

      assert_equal 2, result.length
      assert_equal 'abc1234', result[0]['hash']
      assert_equal 'Fix bug', result[0]['title']
      assert_equal 'Alice', result[0]['author']
      assert_equal '2026-01-01T00:00:00Z', result[0]['date']
    end

    def test_parse_git_log_with_empty_input
      result = GitService.parse_git_log('')
      assert_equal [], result
    end

    def test_parse_git_log_skips_incomplete_records
      # Only 3 fields — should be skipped
      raw = "abc1234\x1fFix bug\x1fAlice\x1e" \
            "def5678\x1fAdd feature\x1fBob\x1f2026-01-02T00:00:00Z\x1e"

      result = GitService.parse_git_log(raw)

      assert_equal 1, result.length
      assert_equal 'def5678', result[0]['hash']
    end

    # -------------------------------------------------------------------------
    # parse_git_log_with_parents
    # -------------------------------------------------------------------------

    def test_parse_git_log_with_parents_valid_input_multiple_parents
      sha1 = 'a' * 40
      sha2 = 'b' * 40
      sha3 = 'c' * 40
      raw = "#{sha1}\x1f#{sha2} #{sha3}\x1fMerge branch\x1fAlice\x1f2026-01-01T00:00:00Z\x1e"

      result = GitService.parse_git_log_with_parents(raw)

      assert_equal 1, result.length
      assert_kind_of Array, result[0]['parents']
      assert_equal 2, result[0]['parents'].length
      assert_includes result[0]['parents'], sha2
      assert_includes result[0]['parents'], sha3
    end

    # -------------------------------------------------------------------------
    # upstream_branch
    # -------------------------------------------------------------------------

    def test_upstream_branch_returns_nil_or_string
      result = GitService.upstream_branch(REPO_PATH)
      assert(result.nil? || result.is_a?(String),
             'upstream_branch should return nil or a String')
    end

    # -------------------------------------------------------------------------
    # ahead_behind
    # -------------------------------------------------------------------------

    def test_ahead_behind_returns_non_negative_integers
      upstream = GitService.upstream_branch(REPO_PATH)
      skip 'No upstream branch configured' if upstream.nil?

      ahead, behind = GitService.ahead_behind(REPO_PATH, upstream)

      assert_kind_of Integer, ahead
      assert_kind_of Integer, behind
      assert_operator ahead, :>=, 0
      assert_operator behind, :>=, 0
    end

    def test_ahead_behind_returns_zeros_for_blank_upstream
      ahead, behind = GitService.ahead_behind(REPO_PATH, '')
      assert_equal 0, ahead
      assert_equal 0, behind
    end

    # -------------------------------------------------------------------------
    # SAFE_GIT_REF
    # -------------------------------------------------------------------------

    def test_safe_git_ref_matches_normal_branch_names
      assert_match GitService::SAFE_GIT_REF, 'main'
      assert_match GitService::SAFE_GIT_REF, 'feature/my-branch'
      assert_match GitService::SAFE_GIT_REF, 'origin/main'
      assert_match GitService::SAFE_GIT_REF, 'release-1.0'
    end

    def test_safe_git_ref_rejects_names_with_spaces
      refute_match GitService::SAFE_GIT_REF, 'branch name'
      refute_match GitService::SAFE_GIT_REF, 'main branch'
    end

    def test_safe_git_ref_rejects_shell_metacharacters
      refute_match GitService::SAFE_GIT_REF, 'branch;rm -rf /'
      refute_match GitService::SAFE_GIT_REF, 'branch$(evil)'
      refute_match GitService::SAFE_GIT_REF, 'branch`cmd`'
      refute_match GitService::SAFE_GIT_REF, 'branch&other'
      refute_match GitService::SAFE_GIT_REF, 'not-valid!!'
    end
  end
end
