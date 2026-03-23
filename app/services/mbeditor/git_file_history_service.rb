# frozen_string_literal: true

module Mbeditor
  # Returns the per-file commit history using `git log --follow`.
  #
  # Each entry:
  #   {
  #     "hash"   => String,
  #     "title"  => String,
  #     "author" => String,
  #     "date"   => String   # ISO-8601
  #   }
  class GitFileHistoryService
    include GitService

    MAX_COMMITS = 200

    attr_reader :repo_path, :file_path

    def initialize(repo_path:, file_path:)
      @repo_path = repo_path.to_s
      @file_path = file_path.to_s
    end

    # Returns Array of commit hashes for the file.
    def call
      output, status = GitService.run_git(
        repo_path,
        "log",
        "--follow",
        "-n", MAX_COMMITS.to_s,
        "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e",
        "--",
        file_path
      )

      raise "git log failed for #{file_path}" unless status.success?

      GitService.parse_git_log(output)
    end
  end
end
