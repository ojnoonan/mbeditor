# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)

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

    # -------------------------------------------------------------------------
    # Broken / degenerate repo states
    # -------------------------------------------------------------------------

    def test_current_branch_returns_nil_in_non_git_directory
      Dir.mktmpdir('mbeditor_nongit_') do |dir|
        result = GitService.current_branch(dir)
        assert_nil result
      end
    end

    def test_current_branch_returns_head_string_in_detached_head_state
      Dir.mktmpdir('mbeditor_detached_') do |repo|
        system('git', '-C', repo, 'init', '-q')
        system('git', '-C', repo, 'config', 'user.email', 'test@mbeditor.test')
        system('git', '-C', repo, 'config', 'user.name', 'Test')
        File.write(File.join(repo, 'f.rb'), "x = 1\n")
        system('git', '-C', repo, 'add', 'f.rb')
        system('git', '-C', repo, 'commit', '-m', 'init', '-q')
        system('git', '-C', repo, 'checkout', '--detach', 'HEAD', '--quiet')

        # rev-parse --abbrev-ref HEAD returns "HEAD" in detached state
        result = GitService.current_branch(repo)
        assert_equal 'HEAD', result
      end
    end

    def test_upstream_branch_returns_nil_in_non_git_directory
      Dir.mktmpdir('mbeditor_nongit_') do |dir|
        result = GitService.upstream_branch(dir)
        assert_nil result
      end
    end

    def test_upstream_branch_returns_nil_when_no_upstream_configured
      Dir.mktmpdir('mbeditor_noupstream_') do |repo|
        system('git', '-C', repo, 'init', '-q')
        system('git', '-C', repo, 'config', 'user.email', 'test@mbeditor.test')
        system('git', '-C', repo, 'config', 'user.name', 'Test')
        File.write(File.join(repo, 'f.rb'), "x = 1\n")
        system('git', '-C', repo, 'add', 'f.rb')
        system('git', '-C', repo, 'commit', '-m', 'init', '-q')

        result = GitService.upstream_branch(repo)
        assert_nil result
      end
    end

    def test_ahead_behind_returns_zeros_in_non_git_directory
      Dir.mktmpdir('mbeditor_nongit_') do |dir|
        ahead, behind = GitService.ahead_behind(dir, 'origin/main')
        assert_equal [0, 0], [ahead, behind]
      end
    end

    # -------------------------------------------------------------------------
    # resolve_path
    # -------------------------------------------------------------------------

    def test_resolve_path_returns_full_path_for_valid_relative
      result = GitService.resolve_path('/some/root', 'lib/foo.rb')
      assert_equal '/some/root/lib/foo.rb', result
    end

    def test_resolve_path_returns_nil_for_traversal
      result = GitService.resolve_path('/some/root', '../../etc/passwd')
      assert_nil result
    end

    def test_resolve_path_returns_nil_for_blank_input
      assert_nil GitService.resolve_path('/some/root', '')
      assert_nil GitService.resolve_path('/some/root', nil)
    end

    def test_resolve_path_returns_repo_path_for_exact_root_dot
      result = GitService.resolve_path('/some/root', '.')
      assert_equal '/some/root', result
    end

    def test_resolve_path_resolves_real_file_inside_repo
      Dir.mktmpdir do |repo|
        FileUtils.mkdir_p(File.join(repo, 'lib'))
        File.write(File.join(repo, 'lib', 'foo.rb'), 'x')

        result = GitService.resolve_path(repo, 'lib/foo.rb')

        assert_equal File.join(repo, 'lib', 'foo.rb'), result
      end
    end

    def test_resolve_path_returns_nil_for_symlink_escape
      Dir.mktmpdir do |outside|
        Dir.mktmpdir do |repo|
          # A symlink inside the repo that resolves to a directory outside it.
          File.write(File.join(outside, 'secret.txt'), 'top secret')
          File.symlink(outside, File.join(repo, 'escape'))

          result = GitService.resolve_path(repo, 'escape/secret.txt')

          assert_nil result, 'symlink resolving outside the repo must be rejected'
        end
      end
    end

    def test_resolve_path_returns_nil_for_dangling_symlink_escape
      Dir.mktmpdir do |repo|
        # A symlink inside the repo pointing outside it at a target that does
        # not exist. File.exist? follows the link and reports false, so an
        # existence walk would step past it and wrongly allow the path.
        File.symlink(File.join(Dir.tmpdir, 'mbeditor_missing_target'), File.join(repo, 'escape'))

        assert_nil GitService.resolve_path(repo, 'escape'),
                   'dangling symlink resolving outside the repo must be rejected'
      end
    end

    # -------------------------------------------------------------------------
    # parse_porcelain_status
    # -------------------------------------------------------------------------

    def test_parse_porcelain_status_returns_status_and_path_hashes
      output = " M app/foo.rb\n?? app/bar.rb\nA  app/baz.rb\n"
      result = GitService.parse_porcelain_status(output)
      assert_equal 3, result.length
      assert_equal({ status: "M", path: "app/foo.rb" }, result[0])
      assert_equal({ status: "??", path: "app/bar.rb" }, result[1])
      assert_equal({ status: "A", path: "app/baz.rb" }, result[2])
    end

    def test_parse_porcelain_status_with_empty_input_returns_empty_array
      assert_equal [], GitService.parse_porcelain_status("")
    end

    def test_parse_porcelain_status_skips_short_lines
      output = "AB\n M app/foo.rb\n"
      result = GitService.parse_porcelain_status(output)
      assert_equal 1, result.length
      assert_equal "app/foo.rb", result[0][:path]
    end

    # -------------------------------------------------------------------------
    # parse_name_status
    # -------------------------------------------------------------------------

    def test_parse_name_status_returns_status_and_path_hashes
      output = "M\tapp/foo.rb\nA\tapp/bar.rb\nD\tapp/old.rb\n"
      result = GitService.parse_name_status(output)
      assert_equal 3, result.length
      assert_equal({ status: "M", path: "app/foo.rb" }, result[0])
      assert_equal({ status: "A", path: "app/bar.rb" }, result[1])
      assert_equal({ status: "D", path: "app/old.rb" }, result[2])
    end

    def test_parse_name_status_with_empty_input_returns_empty_array
      assert_equal [], GitService.parse_name_status("")
    end

    def test_parse_name_status_skips_lines_with_blank_path
      output = "\t\nM\tapp/foo.rb\n"
      result = GitService.parse_name_status(output)
      assert_equal 1, result.length
      assert_equal "app/foo.rb", result[0][:path]
    end

    # ── find_branch_base / base_branch? ──────────────────────────────────────
    # These had no coverage at all, which is how the base-selection bugs
    # survived: every existing test re-derived its expectation from this method.

    def make_repo(dir)
      [["git", "-C", dir, "init", "-b", "develop"],
       ["git", "-C", dir, "config", "user.email", "t@example.com"],
       ["git", "-C", dir, "config", "user.name", "T"]].each do |cmd|
        system(*cmd, out: File::NULL, err: File::NULL)
      end
      commit(dir, "base.txt", "base")
    end

    def commit(dir, file, content)
      File.write(File.join(dir, file), "#{content}\n")
      system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-m", content, out: File::NULL, err: File::NULL)
    end

    def test_find_branch_base_prefers_the_earliest_verifiable_candidate
      Dir.mktmpdir("mbeditor_fbb_") do |dir|
        make_repo(dir)
        system("git", "-C", dir, "checkout", "-b", "feature", out: File::NULL, err: File::NULL)
        commit(dir, "feature.txt", "work")

        sha, ref = GitService.find_branch_base(dir, "feature",
                                              candidates: %w[origin/develop develop main])

        assert_equal "develop", ref, "origin/develop does not exist; develop does"
        assert_match(/\A[0-9a-f]{40}\z/, sha)
      end
    end

    def test_find_branch_base_skips_a_candidate_naming_the_current_branch
      Dir.mktmpdir("mbeditor_fbb_self_") do |dir|
        make_repo(dir)

        # On `develop`, neither `origin/develop` nor `develop` is its own base.
        _sha, ref = GitService.find_branch_base(dir, "develop", candidates: %w[origin/develop develop])
        assert_nil ref

        assert GitService.base_branch?("develop", candidates: %w[origin/develop main]),
               "the caller needs to know this is a base branch so it can use the upstream instead"
      end
    end

    # Regression: a branch fully contained in its base used to be *skipped*
    # (merge-base == HEAD), so resolution fell through to a lower-preference
    # candidate and reported a larger, wrong diff. An empty diff is the truth.
    def test_find_branch_base_keeps_a_base_that_already_contains_this_branch
      Dir.mktmpdir("mbeditor_fbb_merged_") do |dir|
        make_repo(dir)
        commit(dir, "more.txt", "more")
        system("git", "-C", dir, "branch", "release", out: File::NULL, err: File::NULL)
        # Move develop back so `release` is an ancestor of nothing and HEAD is
        # an ancestor of develop.
        system("git", "-C", dir, "checkout", "-b", "topic", "HEAD~1", out: File::NULL, err: File::NULL)

        sha, ref = GitService.find_branch_base(dir, "topic", candidates: %w[develop release])
        head, = Open3.capture2("git", "-C", dir, "rev-parse", "HEAD")

        assert_equal "develop", ref, "the first verifiable candidate wins"
        assert_equal head.strip, sha, "HEAD is an ancestor of develop, so the merge-base IS HEAD"
      end
    end

    def test_find_branch_base_returns_nils_when_no_candidate_exists
      Dir.mktmpdir("mbeditor_fbb_none_") do |dir|
        make_repo(dir)
        system("git", "-C", dir, "checkout", "-b", "feature", out: File::NULL, err: File::NULL)

        assert_equal [nil, nil], GitService.find_branch_base(dir, "feature", candidates: %w[origin/nope nope])
      end
    end

    def test_base_branch_recognises_both_bare_and_origin_prefixed_candidates
      candidates = %w[origin/develop origin/main develop main]

      assert GitService.base_branch?("develop", candidates: candidates)
      assert GitService.base_branch?("main", candidates: candidates)
      refute GitService.base_branch?("feature/x", candidates: candidates)
      refute GitService.base_branch?("HEAD", candidates: candidates), "detached HEAD is not a base branch"
      refute GitService.base_branch?("", candidates: candidates)
      refute GitService.base_branch?(nil, candidates: candidates)
    end
  end
end
