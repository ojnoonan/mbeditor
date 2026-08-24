# frozen_string_literal: true

module Mbeditor
  # Per-line git status for one file, for colouring the editor's line numbers.
  #
  # Wraps `git diff -U0` (working tree vs HEAD) and turns its hunk headers into
  # line ranges in the *current* file:
  #
  #   {
  #     "added"    => [{ "start" => 12, "end" => 14 }, ...],
  #     "modified" => [{ "start" => 30, "end" => 30 }, ...],
  #     "deleted"  => [{ "start" => 47, "end" => 47 }, ...],
  #     "tracked"  => true
  #   }
  #
  # A deletion has no lines left to mark, so it is reported as the single line
  # the removed content sat after — line 0 when the file's opening lines were
  # the ones deleted, which the frontend renders above the first line.
  #
  # An untracked file has no HEAD side at all, so every line counts as added.
  class GitLineDiffService
    include GitService

    # @@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@
    HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    attr_reader :repo_path, :file_path

    def initialize(repo_path:, file_path:)
      @repo_path = repo_path.to_s
      @file_path = file_path.to_s
    end

    def call
      output, status = GitService.run_git(
        repo_path, "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", file_path
      )

      # ls-files only distinguishes "no changes" from "never tracked", so it
      # runs solely when the diff produced nothing. Asking first doubled the
      # subprocess count on a path the editor polls every 10s.
      return untracked_result if (!status.success? || output.empty?) && untracked?

      # A non-zero status here means the diff could not be produced at all (no
      # HEAD yet, path outside the repo). Report a clean file rather than
      # raising: line colouring is decoration, never a reason to fail a load.
      return empty_result unless status.success?

      parse(output)
    end

    private

    def empty_result
      { "added" => [], "modified" => [], "deleted" => [], "tracked" => true }
    end

    def untracked_result
      line_count = count_lines
      added = line_count.positive? ? [{ "start" => 1, "end" => line_count }] : []
      { "added" => added, "modified" => [], "deleted" => [], "tracked" => false }
    end

    def untracked?
      output, status = GitService.run_git(repo_path, "ls-files", "--error-unmatch", "--", file_path)
      !(status.success? && output.present?)
    end

    def count_lines
      absolute = File.join(repo_path, file_path)
      return 0 unless File.file?(absolute)

      File.foreach(absolute).count
    rescue SystemCallError
      0
    end

    def parse(output)
      result = empty_result

      output.each_line do |line|
        match = HUNK_HEADER.match(line)
        next unless match

        old_count = match[2] ? match[2].to_i : 1
        new_start = match[3].to_i
        new_count = match[4] ? match[4].to_i : 1

        if new_count.zero?
          # Pure deletion. git reports the line the removed block followed, so
          # new_start is already that line (and 0 when it was the file's head).
          result["deleted"] << { "start" => new_start, "end" => new_start }
        elsif old_count.zero?
          result["added"] << { "start" => new_start, "end" => new_start + new_count - 1 }
        else
          result["modified"] << { "start" => new_start, "end" => new_start + new_count - 1 }
        end
      end

      result
    end
  end
end
