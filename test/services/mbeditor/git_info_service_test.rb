# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitInfoServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)

    def setup
      GitInfoService.invalidate(REPO_PATH)
    end

    # -------------------------------------------------------------------------
    # Smoke test — real repo
    # -------------------------------------------------------------------------

    def test_call_returns_ok_true_with_all_payload_keys
      result = GitInfoService.call(REPO_PATH)

      assert result[:ok], "expected ok: true, got: #{result.inspect}"
      assert_instance_of String, result[:branch]
      assert result.key?(:upstreamBranch)
      assert_kind_of Integer, result[:ahead]
      assert_kind_of Integer, result[:behind]
      assert_kind_of Array, result[:workingTree]
      assert_kind_of Array, result[:unpushedFiles]
      assert_kind_of Array, result[:unpushedCommits]
      assert_kind_of Array, result[:branchCommits]
      assert result.key?(:branchBaseRef)
      assert result.key?(:redmineTicketId)
    end

    # -------------------------------------------------------------------------
    # Cache hit — second call within TTL returns same object
    # -------------------------------------------------------------------------

    def test_call_returns_cached_result_on_second_call
      first  = GitInfoService.call(REPO_PATH)
      second = GitInfoService.call(REPO_PATH)

      assert_same first, second
    end

    # -------------------------------------------------------------------------
    # Cache invalidation — invalidate clears the entry so next call re-runs
    # -------------------------------------------------------------------------

    def test_invalidate_causes_next_call_to_return_fresh_result
      first = GitInfoService.call(REPO_PATH)
      GitInfoService.invalidate(REPO_PATH)
      second = GitInfoService.call(REPO_PATH)

      refute_same first, second
      assert second[:ok]
    end

    # -------------------------------------------------------------------------
    # Tmpdir scenarios
    # -------------------------------------------------------------------------

    def with_tmp_repo
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "-b", "main", exception: true)
        system("git", "-C", dir, "config", "user.email", "test@test.com", exception: true)
        system("git", "-C", dir, "config", "user.name", "Test", exception: true)
        yield dir
      ensure
        GitInfoService.invalidate(dir)
      end
    end

    def make_commit(dir, message: "Initial commit", filename: "a.txt")
      File.write(File.join(dir, filename), "content")
      system("git", "-C", dir, "add", ".", exception: true)
      system("git", "-C", dir, "commit", "-m", message, exception: true)
    end

    def test_no_upstream_branch_returns_nil_upstream_and_zero_counts
      with_tmp_repo do |dir|
        make_commit(dir)
        result = GitInfoService.call(dir)

        assert result[:ok]
        assert_nil result[:upstreamBranch]
        assert_equal 0, result[:ahead]
        assert_equal 0, result[:behind]
      end
    end

    def test_no_base_branch_candidate_returns_nil_branch_base_ref
      with_tmp_repo do |dir|
        make_commit(dir)
        result = GitInfoService.call(dir)

        assert result[:ok]
        assert_nil result[:branchBaseRef]
        assert_kind_of Array, result[:branchCommits]
      end
    end

    def test_redmine_ticket_id_from_branch_name
      with_tmp_repo do |dir|
        make_commit(dir)
        system("git", "-C", dir, "checkout", "-b", "123-my-feature", exception: true)
        make_commit(dir, message: "Work on feature", filename: "b.txt")

        original_enabled = Mbeditor.configuration.redmine_enabled
        original_source  = Mbeditor.configuration.redmine_ticket_source
        Mbeditor.configuration.redmine_enabled       = true
        Mbeditor.configuration.redmine_ticket_source = :branch

        result = GitInfoService.call(dir)

        assert result[:ok]
        assert_equal "123", result[:redmineTicketId]
      ensure
        Mbeditor.configuration.redmine_enabled       = original_enabled
        Mbeditor.configuration.redmine_ticket_source = original_source
      end
    end

    def test_redmine_ticket_id_from_commit_title
      with_tmp_repo do |dir|
        make_commit(dir)
        make_commit(dir, message: "Fix #456 the broken thing", filename: "b.txt")

        original_enabled = Mbeditor.configuration.redmine_enabled
        original_source  = Mbeditor.configuration.redmine_ticket_source
        Mbeditor.configuration.redmine_enabled       = true
        Mbeditor.configuration.redmine_ticket_source = :commit

        result = GitInfoService.call(dir)

        assert result[:ok]
        assert_equal "456", result[:redmineTicketId]
      ensure
        Mbeditor.configuration.redmine_enabled       = original_enabled
        Mbeditor.configuration.redmine_ticket_source = original_source
      end
    end

    def test_call_returns_error_hash_for_nonexistent_repo_path
      result = GitInfoService.call("/nonexistent/path/#{SecureRandom.hex}")

      assert_equal false, result[:ok]
      assert_kind_of String, result[:error]
    end
  end
end
