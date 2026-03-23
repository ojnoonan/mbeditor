# frozen_string_literal: true

require "time"

module Mbeditor
  # Wraps `git blame --porcelain` and returns structured per-line blame data.
  #
  # Each result entry:
  #   {
  #     "line"    => Integer,   # 1-indexed line number
  #     "sha"     => String,    # full 40-char commit sha
  #     "author"  => String,
  #     "email"   => String,
  #     "date"    => String,    # ISO-8601
  #     "summary" => String,    # commit subject line
  #     "content" => String     # raw source line (without trailing newline)
  #   }
  class GitBlameService
    include GitService

    attr_reader :repo_path, :file_path

    def initialize(repo_path:, file_path:)
      @repo_path = repo_path.to_s
      @file_path = file_path.to_s
    end

    # Returns Array of line blame hashes, or raises RuntimeError.
    def call
      output, status = GitService.run_git(repo_path, "blame", "--porcelain", "--", file_path)
      raise "git blame failed for #{file_path}" unless status.success?

      parse_porcelain(output)
    end

    private

    def parse_porcelain(output)
      results   = []
      commits   = {}  # sha -> metadata cache (porcelain repeats sha for first occurrence only)
      current   = {}

      output.each_line do |raw|
        line = raw.chomp

        # Header line: "<sha> <orig-line> <result-line> [<num-lines>]"
        if line =~ /\A([0-9a-f]{40}) \d+ (\d+)/
          sha        = Regexp.last_match(1)
          result_num = Regexp.last_match(2).to_i
          commits[sha] ||= {}
          current = { "sha" => sha, "line" => result_num }.merge(commits[sha])
          next
        end

        # Content line (starts with TAB)
        if line.start_with?("\t")
          current["content"] = line[1..-1] # strip leading tab
          commits[current["sha"]] = current.slice("author", "email", "date", "summary") if current["author"]
          results << current.dup
          current = {}
          next
        end

        # Metadata lines
        case line
        when /\Aauthor (.+)/
          current["author"] = Regexp.last_match(1)
          commits[current["sha"]] ||= {}
          commits[current["sha"]]["author"] = current["author"]
        when /\Aauthor-mail <(.+)>/
          current["email"] = Regexp.last_match(1)
          commits[current["sha"]] ||= {}
          commits[current["sha"]]["email"] = current["email"]
        when /\Aauthor-time (\d+)/
          ts = Regexp.last_match(1).to_i
          current["date"] = Time.at(ts).utc.iso8601
          commits[current["sha"]] ||= {}
          commits[current["sha"]]["date"] = current["date"]
        when /\Asummary (.+)/
          current["summary"] = Regexp.last_match(1)
          commits[current["sha"]] ||= {}
          commits[current["sha"]]["summary"] = current["summary"]
        end

        # Merge cached metadata for repeat shas so every entry is complete
        if current["sha"] && commits[current["sha"]]
          cached = commits[current["sha"]]
          current["author"]  ||= cached["author"]
          current["email"]   ||= cached["email"]
          current["date"]    ||= cached["date"]
          current["summary"] ||= cached["summary"]
        end
      end

      results
    end
  end
end
