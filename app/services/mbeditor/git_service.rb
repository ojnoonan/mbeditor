# frozen_string_literal: true

require_relative "process_runner"

module Mbeditor
  # Shared helpers for running git CLI commands read-only inside a repo.
  # All public methods accept +repo_path+ as their first argument so services
  # stay stateless and composable.
  module GitService
    module_function

    # Safe pattern for git ref names (branch, remote/branch, tag).
    # Excludes @ to prevent reflog syntax like @{-1} or @{u}, and a leading -
    # so a ref can never be read as a command-line option by the git it is
    # interpolated into.
    SAFE_GIT_REF = %r{\A(?!-)[\w./-]+\z}

    # Run an arbitrary git command inside +repo_path+.
    # Returns [stdout, Process::Status]. stderr is discarded to prevent git
    # diagnostic messages from leaking into the Rails server log.
    # Honors config.git_timeout (seconds) when set.
    def run_git(repo_path, *args, max_bytes: nil)
      timeout_secs = Mbeditor.configuration.git_timeout&.to_i
      timeout = timeout_secs && timeout_secs > 0 ? timeout_secs : nil
      result = ProcessRunner.call(["git", "-C", repo_path, *args], timeout: timeout, max_bytes: max_bytes)
      [result[:stdout], result[:exit_status]]
    rescue ProcessRunner::TimeoutError
      raise Timeout::Error, "git timed out after #{timeout_secs}s"
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

    # Returns [merge_base_sha, ref_name] of the first candidate base branch that
    # exists, or [nil, nil] when none does.
    #
    # Candidates are tried in preference order and the FIRST one that resolves
    # wins, even when the merge-base turns out to be HEAD itself. That case
    # means the branch is fully contained in its base — an empty "changes in
    # branch" diff is then the truthful answer, and walking on to a
    # lower-preference candidate would report a larger, wrong diff instead.
    #
    # A candidate naming the current branch is skipped: `develop` is not its own
    # base. Callers handle that case by comparing against the upstream instead
    # (see GitCombinedDiffService#branch_diff).
    def find_branch_base(repo_path, current_branch, candidates: nil)
      candidates ||= Mbeditor.configuration.base_branch_candidates

      # One listing instead of a rev-parse per candidate: with six defaults
      # that was up to twelve sequential spawns on a path the git panel polls.
      refs_out, refs_st = run_git(repo_path, "for-each-ref", "--format=%(refname:short)",
                                  "refs/heads", "refs/remotes")
      return [nil, nil] unless refs_st.success?

      existing = refs_out.split("\n").map(&:strip)

      candidates.each do |ref|
        short = ref.delete_prefix("origin/")
        next if short == current_branch || ref == current_branch
        next unless existing.include?(ref)

        base_out, base_st = run_git(repo_path, "merge-base", "HEAD", ref)
        next unless base_st.success?

        sha = base_out.strip
        next unless sha.match?(/\A[0-9a-f]{40}\z/)

        return [sha, ref]
      end

      [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    # True when the branch is itself one of the configured base branches, in
    # which case "changes in branch" means "commits not yet pushed" and
    # comparing against its own upstream is correct rather than degenerate.
    def base_branch?(current_branch, candidates: nil)
      return false if current_branch.to_s.empty? || current_branch == "HEAD"

      candidates ||= Mbeditor.configuration.base_branch_candidates
      candidates.any? { |ref| ref == current_branch || ref.delete_prefix("origin/") == current_branch }
    end

    # Parse `git status --porcelain` output, in either the newline form or the
    # NUL-delimited `-z` form.
    #
    # Only `-z` gives usable paths: without it git quotes anything containing a
    # space or a non-ASCII byte (`"caf\303\251.rb"`) and writes a rename as
    # `old -> new`, so the path came back unopenable and never matched numstat.
    # In `-z` a rename/copy spans two records and the NEW name comes first.
    #
    # Returns Array of { status: String, path: String }.
    def parse_porcelain_status(output)
      nul = output.include?("\0")
      records = nul ? output.split("\0") : output.lines.map(&:chomp)

      result = []
      i = 0
      while i < records.length
        record = records[i]
        i += 1
        next if record.length < 4

        status = record[0..1].strip
        i += 1 if nul && status.start_with?("R", "C") # skip the old name
        path = nul ? record[3..].to_s : record[3..].to_s.strip
        next if path.blank?

        result << { status: status, path: path }
      end
      result
    end

    # Parse `git diff --name-status` output.
    # Returns Array of { status: String, path: String }.
    def parse_name_status(output)
      output.lines.filter_map do |line|
        parts = line.strip.split("\t")
        next if parts.empty?

        status = parts[0].to_s.strip
        path = parts.last.to_s.strip
        next if path.blank?

        { status: status, path: path }
      end
    end

    # Parse `git diff --numstat` output, in either the newline form or the
    # NUL-delimited `-z` form (which is what pairs with `status --porcelain -z`,
    # since only it leaves non-ASCII paths unquoted).
    # Returns Hash of path => { added: Integer, removed: Integer }.
    def parse_numstat(output)
      out = (output || "")
      return parse_numstat_z(out) if out.include?("\0")

      out.lines.each_with_object({}) do |line, map|
        parts = line.strip.split("\t", 3)
        next if parts.length < 3 || parts[0] == "-"

        map[parts[2].strip] = { added: parts[0].to_i, removed: parts[1].to_i }
      end
    end

    # In `-z` form a rename leaves the path field empty and follows the record
    # with the old name then the new name, each NUL-terminated.
    def parse_numstat_z(output)
      records = output.split("\0")
      map = {}
      i = 0
      while i < records.length
        added, removed, path = records[i].split("\t", 3)
        i += 1
        if path.to_s.empty?
          path = records[i + 1]
          i += 2
        end
        next if path.nil? || added == "-"

        map[path] = { added: added.to_i, removed: removed.to_i }
      end
      map
    end

    # Parse compact `git log --pretty=format:%H%x1f%P%x1f%s%x1f%an%x1f%aI%x1e` output.
    # Returns Array of hashes with string keys.
    def self.parse_git_log_with_parents(raw_output)
      parse_log_entries(raw_output, with_parents: true)
    end

    # Parse compact `git log --pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e` output.
    # Returns Array of hashes with string keys.
    def self.parse_git_log(raw_output)
      parse_log_entries(raw_output, with_parents: false)
    end

    # Resolve a file path safely within repo_path.  Returns full path string or
    # nil if the path escapes the root.
    #
    # Resolves symlinks (via SafePath, including dangling ones) so that a
    # symlink inside the repo cannot escape it.  Deliberately stricter than
    # ApplicationController#resolve_path, which follows links out of the
    # workspace so linked-in files open: git has nothing to say about a file
    # outside its own repo, so there is no feature to lose here.
    # When repo_path is not a real directory
    # (e.g. unit tests with synthetic roots) the symlink check is skipped, since
    # there is nothing on disk to resolve and repo_path is server-controlled.
    def resolve_path(repo_path, relative)
      return nil if relative.blank?

      root = repo_path.to_s
      full = File.expand_path(relative.to_s, root)
      return nil unless full.start_with?("#{root}/") || full == root
      return full unless File.directory?(root)
      return nil unless SafePath.within?(root, full)

      full
    rescue Errno::EACCES
      nil
    end

    def self.parse_log_entries(raw_output, with_parents:)
      field_count = with_parents ? 5 : 4
      raw_output.split("\x1e").filter_map do |entry|
        fields = entry.strip.split("\x1f", field_count)
        next unless fields.length == field_count

        if with_parents
          {
            "hash"    => fields[0],
            "parents" => fields[1].split.reject(&:blank?),
            "title"   => fields[2],
            "author"  => fields[3],
            "date"    => fields[4]
          }
        else
          {
            "hash"   => fields[0],
            "title"  => fields[1],
            "author" => fields[2],
            "date"   => fields[3]
          }
        end
      end
    end
    private_class_method :parse_log_entries
  end
end
