# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

module Mbeditor
  class GitCombinedDiffServiceTest < Minitest::Test
    REPO_PATH = File.expand_path("../../..", __dir__)

    def build_branch_base_repo
      dir = Dir.mktmpdir("mbeditor_gcds_")
      cmds = [
        ["git", "-C", dir, "init", "-b", "main"],
        ["git", "-C", dir, "config", "user.email", "test@example.com"],
        ["git", "-C", dir, "config", "user.name", "Test"],
      ]
      cmds.each { |cmd| system(*cmd, out: File::NULL, err: File::NULL) }
      File.write("#{dir}/base.txt", "base\n")
      system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-m", "base", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "checkout", "-b", "feature", out: File::NULL, err: File::NULL)
      File.write("#{dir}/feature.txt", "feature\n")
      system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-m", "feature work", out: File::NULL, err: File::NULL)
      dir
    end

    # Point <branch> at refs/remotes/origin/<branch>. The fetch refspec matters:
    # without it `@{u}` fails with "not stored as a remote-tracking branch",
    # even though the ref exists.
    def track_upstream(dir, branch)
      [["git", "-C", dir, "remote", "add", "origin", "https://example.invalid/r.git"],
       ["git", "-C", dir, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
       ["git", "-C", dir, "config", "branch.#{branch}.remote", "origin"],
       ["git", "-C", dir, "config", "branch.#{branch}.merge", "refs/heads/#{branch}"]].each do |cmd|
        system(*cmd, out: File::NULL, err: File::NULL)
      end
    end

    def test_call_returns_string_for_local_scope
      result = GitCombinedDiffService.new(repo_path: REPO_PATH, scope: :local).call

      assert_kind_of String, result
    end

    def test_call_does_not_raise_for_local_scope
      assert_silent do
        GitCombinedDiffService.new(repo_path: REPO_PATH, scope: :local).call
      end
    end

    def test_call_returns_string_for_branch_scope
      result = GitCombinedDiffService.new(repo_path: REPO_PATH, scope: :branch).call

      assert_kind_of String, result
    end

    def test_call_does_not_raise_for_branch_scope
      assert_silent do
        GitCombinedDiffService.new(repo_path: REPO_PATH, scope: :branch).call
      end
    end

    # Asserts against the diff content itself rather than re-deriving the
    # expectation from find_branch_base — the previous version of this test did
    # the latter, so it passed for any base the code happened to choose,
    # including a wrong one.
    def test_call_branch_scope_diffs_against_the_base_branch_not_the_branch_itself
      dir = build_branch_base_repo
      # Give `feature` a remote-tracking ref of its own, which is what made the
      # old upstream fallback compare the branch to itself.
      system("git", "-C", dir, "update-ref", "refs/remotes/origin/feature", "HEAD",
             out: File::NULL, err: File::NULL)

      result = GitCombinedDiffService.new(repo_path: dir, scope: :branch).call

      assert_includes result, "feature.txt", "the commit made on this branch must appear in the diff"
      assert_includes result, "+feature"
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    def test_call_branch_scope_reports_the_base_it_compared_against
      dir = build_branch_base_repo
      service = GitCombinedDiffService.new(repo_path: dir, scope: :branch)
      service.call

      assert_equal "main", service.base_ref
      assert_nil service.error
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    # The bug this whole change exists for: with no base branch available, the
    # old code fell back to `origin/<current-branch>..HEAD` — the branch against
    # its own remote copy — which is reliably empty and rendered as "No changes"
    # on a branch that was many commits ahead of develop.
    def test_call_branch_scope_never_compares_a_feature_branch_to_its_own_upstream
      dir = build_branch_base_repo
      # Remove every base candidate so only the branch's own upstream is left.
      system("git", "-C", dir, "branch", "-D", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "update-ref", "refs/remotes/origin/feature", "HEAD",
             out: File::NULL, err: File::NULL)
      track_upstream(dir, "feature")

      service = GitCombinedDiffService.new(repo_path: dir, scope: :branch)
      result = service.call

      assert_equal "", result
      assert_nil service.base_ref, "a self-comparison must not be reported as a base"
      assert_match(/base branch/i, service.error.to_s,
                   "the user needs to know why the diff is empty")
      assert_includes service.error, "feature"
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    # ...but on a base branch, comparing to its own upstream IS the right
    # answer: "changes in branch" there means "not yet pushed".
    def test_call_branch_scope_uses_upstream_when_the_branch_is_itself_a_base_branch
      dir = build_branch_base_repo
      system("git", "-C", dir, "checkout", "main", out: File::NULL, err: File::NULL)
      # origin/main sits one commit behind local main.
      base_sha, = Open3.capture2("git", "-C", dir, "rev-parse", "HEAD")
      system("git", "-C", dir, "update-ref", "refs/remotes/origin/main", base_sha.strip,
             out: File::NULL, err: File::NULL)
      File.write("#{dir}/unpushed.txt", "unpushed\n")
      system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-m", "local only", out: File::NULL, err: File::NULL)
      track_upstream(dir, "main")

      service = GitCombinedDiffService.new(repo_path: dir, scope: :branch)
      result = service.call

      assert_includes result, "unpushed.txt"
      assert_equal "origin/main", service.base_ref
      assert_nil service.error
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    def test_call_branch_scope_returns_empty_string_when_no_base_and_no_upstream
      Dir.mktmpdir("mbeditor_gcds_nobase_") do |dir|
        cmds = [
          ["git", "-C", dir, "init", "-b", "main"],
          ["git", "-C", dir, "config", "user.email", "test@example.com"],
          ["git", "-C", dir, "config", "user.name", "Test"],
        ]
        cmds.each { |cmd| system(*cmd, out: File::NULL, err: File::NULL) }
        File.write("#{dir}/file.txt", "content\n")
        system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
        system("git", "-C", dir, "commit", "-m", "init", out: File::NULL, err: File::NULL)

        result = GitCombinedDiffService.new(repo_path: dir, scope: :branch).call
        assert_equal "", result
      end
    end
  end
end
