# frozen_string_literal: true

module Mbeditor
  class GitCombinedDiffService
    include GitService

    # Response-size bound for pathological diffs (e.g. a committed lockfile
    # regeneration). Truncated at the last complete per-file diff boundary so
    # the output remains a parseable diff document.
    MAX_DIFF_BYTES = 5 * 1024 * 1024

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
      status.success? ? cap_diff(out) : ""
    end

    def branch_diff
      branch  = GitService.current_branch(repo_path)
      base_sha, = GitService.find_branch_base(repo_path, branch)

      if base_sha.present?
        out, status = GitService.run_git(repo_path, "diff", "#{base_sha}..HEAD")
        return status.success? ? cap_diff(out) : ""
      end

      upstream = GitService.upstream_branch(repo_path)
      return "" unless upstream.present?

      out, status = GitService.run_git(repo_path, "diff", "#{upstream}..HEAD")
      status.success? ? cap_diff(out) : ""
    end

    def cap_diff(out)
      return out if out.bytesize <= MAX_DIFF_BYTES

      head = out.byteslice(0, MAX_DIFF_BYTES)
      boundary = head.rindex("\ndiff --git ")
      boundary ? head[0...boundary] : head
    end
  end
end
