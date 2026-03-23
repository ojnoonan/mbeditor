# frozen_string_literal: true

require "open3"

module Mbeditor
  # Shared helpers for running git CLI commands read-only inside a repo.
  # All public methods accept +repo_path+ as their first argument so services
  # stay stateless and composable.
  module GitService
    module_function

    # Run an arbitrary git command inside +repo_path+.
    # Returns [stdout, Process::Status].
    def run_git(repo_path, *args)
      Open3.capture2("git", "-C", repo_path, *args)
    end

    # Current branch name, or nil if not in a git repo.
    def current_branch(repo_path)
      out, status = run_git(repo_path, "branch", "--show-current")
      status.success? ? out.strip : nil
    end

    # Upstream tracking branch for the current branch, e.g. "origin/main".
    def upstream_branch(repo_path)
      out, status = run_git(repo_path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      status.success? ? out.strip : nil
    end

    # Returns [ahead_count, behind_count] relative to upstream, or [0,0].
    def ahead_behind(repo_path, upstream)
      return [0, 0] if upstream.blank?

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
