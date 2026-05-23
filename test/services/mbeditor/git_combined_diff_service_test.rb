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

    def test_call_branch_scope_matches_branch_base_diff_when_available
      dir = build_branch_base_repo
      branch = GitService.current_branch(dir)
      base_sha, = GitService.find_branch_base(dir, branch)
      skip "branch base not resolved" unless base_sha

      expected, = Open3.capture2("git", "-C", dir, "diff", "#{base_sha}..HEAD")
      result = GitCombinedDiffService.new(repo_path: dir, scope: :branch).call

      assert_equal expected, result
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    def test_call_branch_scope_uses_upstream_when_no_branch_base
      current = GitService.current_branch(REPO_PATH)
      base_sha, = GitService.find_branch_base(REPO_PATH, current)
      skip "branch base found; this test covers the upstream-fallback path" if base_sha

      upstream = GitService.upstream_branch(REPO_PATH)
      skip "no upstream configured" unless upstream

      expected, = Open3.capture2("git", "-C", REPO_PATH, "diff", "#{upstream}..HEAD")
      result = GitCombinedDiffService.new(repo_path: REPO_PATH, scope: :branch).call

      assert_equal expected, result
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
