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

    # What the last #call actually compared against, for the UI to display.
    # Set by #branch_diff; nil for :local scope.
    attr_reader :base_ref

    # Set when branch scope could not establish a base branch at all, so the
    # caller can say why instead of rendering an empty diff as "No changes".
    attr_reader :error

    private

    def local_diff
      out, status = git_diff("HEAD")
      status.success? ? cap_diff(out) : ""
    end

    # --no-color/--no-ext-diff on every invocation: a host gitconfig with
    # color.ui = always, or a diff.external driver, otherwise feeds escape
    # codes or foreign output into the viewer's parser. max_bytes stops a
    # pathological diff being fully materialised just for cap_diff to throw
    # most of it away.
    def git_diff(*revs)
      GitService.run_git(repo_path, "diff", "--no-color", "--no-ext-diff", *revs,
                         max_bytes: MAX_DIFF_BYTES)
    end

    def branch_diff
      branch = GitService.current_branch(repo_path)
      base_sha, ref = GitService.find_branch_base(repo_path, branch)

      if base_sha.present?
        @base_ref = ref
        out, status = git_diff("#{base_sha}..HEAD")
        return status.success? ? cap_diff(out) : ""
      end

      # No base branch resolved. Comparing against the upstream is only
      # meaningful when this branch IS a base branch (develop vs origin/develop
      # = "not yet pushed"). For a feature branch the upstream is
      # origin/<same-branch>, so that diff compares the branch to itself and is
      # reliably empty — which is how "Changes in Branch" came to show nothing
      # on a branch that was many commits ahead of develop.
      upstream = GitService.upstream_branch(repo_path)
      if GitService.base_branch?(branch) && upstream.present?
        @base_ref = upstream
        out, status = git_diff("#{upstream}..HEAD")
        return status.success? ? cap_diff(out) : ""
      end

      @error = base_unavailable_message(branch)
      ""
    end

    def base_unavailable_message(branch)
      if GitService.base_branch?(branch)
        return "#{branch.inspect} is itself a base branch and has no upstream to compare against, " \
               "so there is nothing to show here. Use \"Changes\" for uncommitted work."
      end

      candidates = Mbeditor.configuration.base_branch_candidates.join(", ")
      "Could not determine a base branch to compare #{branch.inspect} against. " \
        "None of these exist locally: #{candidates}. " \
        "Fetch the base branch (git fetch origin) or set config.mbeditor.base_branch_candidates."
    end

    def cap_diff(out)
      return out if out.bytesize <= MAX_DIFF_BYTES

      head = out.byteslice(0, MAX_DIFF_BYTES)
      boundary = head.rindex("\ndiff --git ")
      boundary ? head[0...boundary] : head
    end
  end
end
