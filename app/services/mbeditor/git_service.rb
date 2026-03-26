# frozen_string_literal: true

require "open3"

module Mbeditor
  # Shared helpers for running git CLI commands read-only inside a repo.
  # All public methods accept +repo_path+ as their first argument so services
  # stay stateless and composable.
  module GitService
    module_function

    # Safe pattern for git ref names (branch, remote/branch, tag).
    # Rejects refs containing whitespace, NUL, shell metacharacters, or
    # git reflog syntax (e.g. "@{" sequences beyond the trailing "@{u}").
    SAFE_GIT_REF = %r{\A[\w./-]+\z}

    # Run an arbitrary git command inside +repo_path+.
    # Returns [stdout, Process::Status]. stderr is captured and discarded to
    # prevent git diagnostic messages from leaking into the Rails server log.
    def run_git(repo_path, *args)
      out, _err, status = Open3.capture3("git", "-C", repo_path, *args)
      [out, status]
    end

    # Current branch name, or nil if not in a git repo.
    # Uses rev-parse for compatibility with Git < 2.22 (which lacks --show-current).
    def current_branch(repo_path)
      out, status = run_git(repo_path, "rev-parse", "--abbrev-ref", "HEAD")
      status.success? ? out.strip : nil
    end

    # Upstream tracking branch for the current branch, e.g. "origin/main".
    # Returns nil if the branch name contains characters outside SAFE_GIT_REF.
    def upstream_branch(repo_path)
      out, status = run_git(repo_path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      return nil unless status.success?

      ref = out.strip
      ref.match?(SAFE_GIT_REF) ? ref : nil
    end

    # Returns [ahead_count, behind_count] relative to upstream, or [0,0].
    def ahead_behind(repo_path, upstream)
      return [0, 0] if upstream.blank?
      return [0, 0] unless upstream.match?(SAFE_GIT_REF)

      out, status = run_git(repo_path, "rev-list", "--left-right", "--count", "HEAD...#{upstream}")
      return [0, 0] unless status.success?

      parts = out.strip.split("\t", 2)
      [parts[0].to_i, parts[1].to_i]
    end

    # Parse compact `git log --pretty=format:%H%x1f%P%x1f%s%x1f%an%x1f%aI%x1e` output.
    # Returns Array of hashes.
    def self.parse_git_log_with_parents(raw_output)
      raw_output.split("\x1e").map do |entry|
        fields = entry.strip.split("\x1f", 5)
        next unless fields.length == 5

        {
          "hash"    => fields[0],
          "parents" => fields[1].split.reject(&:blank?),
          "title"   => fields[2],
          "author"  => fields[3],
          "date"    => fields[4]
        }
      end.compact
    end

    # Parse compact `git log --pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e` output.
    def self.parse_git_log(raw_output)
      raw_output.split("\x1e").map do |entry|
        fields = entry.strip.split("\x1f", 4)
        next unless fields.length == 4

        {
          "hash"   => fields[0],
          "title"  => fields[1],
          "author" => fields[2],
          "date"   => fields[3]
        }
      end.compact
    end

    # Resolve a file path safely within repo_path.  Returns full path string or
    # nil if the path escapes the root.
    def resolve_path(repo_path, relative)
      return nil if relative.blank?

      full = File.expand_path(relative.to_s, repo_path.to_s)
      full.start_with?(repo_path.to_s + "/") || full == repo_path.to_s ? full : nil
    end
  end
end
