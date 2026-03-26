# frozen_string_literal: true

module Mbeditor
  # Produces original/modified content pairs suitable for Monaco's diff editor.
  #
  # Modes
  # -----
  # 1. Working tree vs HEAD (default when no sha given)
  #    original = HEAD version of the file
  #    modified = current on-disk content
  #
  # 2. Specific commit vs its parent
  #    original = file at <base_sha>
  #    modified = file at <head_sha>
  class GitDiffService
    include GitService

    attr_reader :repo_path, :file_path, :base_sha, :head_sha

    def initialize(repo_path:, file_path:, base_sha: nil, head_sha: nil)
      @repo_path = repo_path.to_s
      @file_path = file_path.to_s
      @base_sha  = base_sha.presence
      @head_sha  = head_sha.presence
    end

    # Returns { original: String, modified: String } or raises RuntimeError.
    def call
      if base_sha && head_sha
        diff_between_commits
      elsif base_sha
        # base_sha provided but head_sha is nil: diff that ref vs the working tree
        { "original" => file_at_ref(base_sha, file_path), "modified" => on_disk_content }
      else
        diff_working_tree_vs_head
      end
    end

    private

    def diff_working_tree_vs_head
      original = file_at_ref("HEAD", file_path)
      modified = on_disk_content

      { "original" => original, "modified" => modified }
    end

    def diff_between_commits
      original = file_at_ref(base_sha, file_path)
      modified = file_at_ref(head_sha, file_path)

      { "original" => original, "modified" => modified }
    end

    # Return the file content at a given git ref, or "" if it doesn't exist.
    def file_at_ref(ref, path)
      out, status = GitService.run_git(repo_path, "show", "#{ref}:#{path}")
      return "" unless status.success?

      out
    rescue StandardError
      ""
    end

    def on_disk_content
      full = GitService.resolve_path(repo_path, file_path)
      return "" unless full && File.file?(full)

      File.read(full, encoding: "UTF-8", invalid: :replace, undef: :replace)
    rescue StandardError
      ""
    end
  end
end
