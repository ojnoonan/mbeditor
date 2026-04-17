# frozen_string_literal: true

require "set"

module Mbeditor
  # Builds commit graph data for rendering a VSCode-style commit graph.
  #
  # Each commit entry:
  #   {
  #     "hash"     => String,          # full 40-char sha
  #     "parents"  => Array<String>,   # parent sha(s) — enables line drawing
  #     "title"    => String,
  #     "author"   => String,
  #     "date"     => String,          # ISO-8601
  #     "isLocal"  => Boolean          # true if commit is ahead of upstream
  #   }
  class GitCommitGraphService
    include GitService

    MAX_COMMITS = 150

    attr_reader :repo_path

    def initialize(repo_path:)
      @repo_path = repo_path.to_s
    end

    def call
      output, status = GitService.run_git(
        repo_path,
        "log",
        "--all",
        "-n", MAX_COMMITS.to_s,
        "--pretty=format:%H%x1f%P%x1f%s%x1f%an%x1f%aI%x1e"
      )

      raise "git log failed" unless status.success?

      commits = GitService.parse_git_log_with_parents(output)
      local_shas = local_commit_shas

      commits.map do |c|
        c.merge("isLocal" => local_shas.include?(c["hash"]))
      end
    end

    private

    # Returns a Set of commit shas that are ahead of the upstream (i.e. not yet pushed).
    def local_commit_shas
      upstream = GitService.upstream_branch(repo_path)
      return Set.new if upstream.blank?

      out, status = GitService.run_git(repo_path, "rev-list", "HEAD...#{upstream}", "--left-only")
      return Set.new unless status.success?

      Set.new(out.lines.map(&:strip).reject(&:blank?))
    rescue StandardError
      Set.new
    end
  end
end
