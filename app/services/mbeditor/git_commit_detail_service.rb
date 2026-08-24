# frozen_string_literal: true

module Mbeditor
  class GitCommitDetailService
    include GitService

    attr_reader :repo_path, :sha

    def initialize(repo_path:, sha:)
      @repo_path = repo_path.to_s
      @sha       = sha.to_s
    end

    EMPTY = { "title" => "", "author" => "", "date" => "", "files" => [] }.freeze
    private_constant :EMPTY

    # Two spawns per commit click, not three: `git show --name-status` prints
    # the pretty header then the raw name-status body. The numstat still needs
    # its own call — asking for --name-status and --numstat together makes git
    # emit only the former. --no-renames keeps a rename as the D+A pair the
    # two-field parse below expects, rather than a three-field R100 record.
    def call
      out, status = GitService.run_git(repo_path, "show", "--no-color", "--no-renames", "--name-status",
                                       "--pretty=format:%s%x1f%an%x1f%aI", "--end-of-options", sha)
      return EMPTY.merge("sha" => sha) unless status.success?

      header, body = out.split("\n", 2)
      fields = header.to_s.split("\x1f", 3)
      { "sha" => sha, "title" => fields[0].to_s, "author" => fields[1].to_s, "date" => fields[2].to_s,
        "files" => parse_files(body.to_s) }
    end

    private

    def parse_files(body)
      num_out, num_st = GitService.run_git(repo_path, "show", "--no-color", "--no-renames", "--numstat",
                                           "--pretty=format:", "--end-of-options", sha)
      numstat = num_st.success? ? GitService.parse_numstat(num_out) : {}

      body.lines.filter_map do |line|
        parts = line.strip.split("\t", 2)
        next if parts.length < 2

        path = parts[1].strip
        stats = numstat.fetch(path, { added: 0, removed: 0 })
        { "status" => parts[0].strip, "path" => path, "added" => stats[:added], "removed" => stats[:removed] }
      end
    end
  end
end
