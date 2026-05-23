# frozen_string_literal: true

module Mbeditor
  class GitCombinedDiffService
    include GitService

    attr_reader :repo_path, :scope

    def initialize(repo_path:, scope:)
      @repo_path = repo_path.to_s
      @scope     = scope
    end

    def call
      return local_diff if scope == :local

      branch_diff
    end

    private

    def local_diff
      out, status = GitService.run_git(repo_path, "diff", "HEAD")
      status.success? ? out : ""
    end

    def branch_diff
      branch  = GitService.current_branch(repo_path)
      base_sha, = GitService.find_branch_base(repo_path, branch)

      if base_sha.present?
        out, status = GitService.run_git(repo_path, "diff", "#{base_sha}..HEAD")
        return status.success? ? out : ""
      end

      upstream = GitService.upstream_branch(repo_path)
      return "" unless upstream.present?

      out, status = GitService.run_git(repo_path, "diff", "#{upstream}..HEAD")
      status.success? ? out : ""
    end
  end
end
