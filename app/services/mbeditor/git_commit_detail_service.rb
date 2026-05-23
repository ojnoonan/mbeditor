# frozen_string_literal: true

module Mbeditor
  class GitCommitDetailService
    include GitService

    attr_reader :repo_path, :sha

    def initialize(repo_path:, sha:)
      @repo_path = repo_path.to_s
      @sha       = sha.to_s
    end

    def call
      meta = fetch_meta
      { "sha" => sha, "title" => meta["title"], "author" => meta["author"], "date" => meta["date"], "files" => fetch_files }
    end

    private

    def fetch_files
      name_out, name_st = GitService.run_git(repo_path, "diff-tree", "--no-commit-id", "-r", "--name-status", sha)
      return [] unless name_st.success?

      num_out, num_st = GitService.run_git(repo_path, "diff-tree", "--no-commit-id", "-r", "--numstat", sha)
      numstat = num_st.success? ? GitService.parse_numstat(num_out) : {}

      name_out.lines.filter_map do |line|
        parts = line.strip.split("\t", 2)
        next if parts.length < 2

        path = parts[1].strip
        stats = numstat.fetch(path, { added: 0, removed: 0 })
        { "status" => parts[0].strip, "path" => path, "added" => stats[:added], "removed" => stats[:removed] }
      end
    end

    def fetch_meta
      out, status = GitService.run_git(repo_path, "log", "-1", "--pretty=format:%s%x1f%an%x1f%aI", sha)
      return { "title" => "", "author" => "", "date" => "" } unless status.success?

      fields = out.strip.split("\x1f", 3)
      { "title" => fields[0].to_s, "author" => fields[1].to_s, "date" => fields[2].to_s }
    end
  end
end
