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

    # Temporarily wrap ProcessRunner.call so every subprocess invocation is
    # recorded (cmd + timeout) while still delegating to the real runner.
    def with_process_runner_recorder(captured)
      real = ProcessRunner.method(:call)
      verbose = $VERBOSE
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call) do |cmd, **kwargs|
        captured << { cmd: cmd, timeout: kwargs[:timeout] }
        real.call(cmd, **kwargs)
      end
      $VERBOSE = verbose
      yield
    ensure
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call, real)
      $VERBOSE = verbose
    end

    # Records any direct Open3.capture3 subprocess (one that bypasses
    # ProcessRunner, and therefore config.git_timeout) during the block.
    def with_capture3_recorder(captured)
      real = Open3.method(:capture3)
      verbose = $VERBOSE
      $VERBOSE = nil
      Open3.singleton_class.send(:define_method, :capture3) do |*args, **kwargs|
        captured << args
        real.call(*args, **kwargs)
      end
      $VERBOSE = verbose
      yield
    ensure
      $VERBOSE = nil
      Open3.singleton_class.send(:define_method, :capture3, real)
      $VERBOSE = verbose
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

    # -------------------------------------------------------------------------
    # Timeout governance — git subprocesses route through ProcessRunner so
    # config.git_timeout is honored (issue #70).
    # -------------------------------------------------------------------------

    def test_wave_git_calls_run_through_process_runner_with_configured_timeout
      with_tmp_repo do |dir|
        make_commit(dir)
        original = Mbeditor.configuration.git_timeout
        Mbeditor.configuration.git_timeout = 7

        captured = []
        GitInfoService.invalidate(dir)
        result = with_process_runner_recorder(captured) { GitInfoService.call(dir) }

        assert result[:ok], "expected ok: true, got: #{result.inspect}"

        status_call = captured.find { |c| c[:cmd].include?("status") }
        refute_nil status_call,
                   "expected wave-1 `git status` to run through ProcessRunner, " \
                   "but it bypassed the timeout mechanism"
        assert_equal 7, status_call[:timeout],
                     "expected the configured git_timeout to be applied to the wave git call"
      ensure
        Mbeditor.configuration.git_timeout = original
      end
    end

    def test_full_call_makes_no_raw_open3_subprocess
      # The real project repo exercises wave-1 plus the wave-2 branch_log (and
      # ahead/behind + unpushed when an upstream exists).  None of those git
      # invocations may bypass ProcessRunner via a raw Open3.capture3.
      captured = []
      GitInfoService.invalidate(REPO_PATH)
      result = with_capture3_recorder(captured) { GitInfoService.call(REPO_PATH) }

      assert result[:ok], "expected ok: true, got: #{result.inspect}"
      assert_empty captured,
                   "expected no raw Open3.capture3 calls, but these git commands " \
                   "bypassed the timeout mechanism: #{captured.inspect}"
    end
  end
end
