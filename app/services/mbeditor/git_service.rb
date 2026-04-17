# frozen_string_literal: true

require "open3"
require "timeout"

module Mbeditor
  # Shared helpers for running git CLI commands read-only inside a repo.
  # All public methods accept +repo_path+ as their first argument so services
  # stay stateless and composable.
  module GitService
    module_function

    # Safe pattern for git ref names (branch, remote/branch, tag).
    # Excludes @ to prevent reflog syntax like @{-1} or @{u}.
    SAFE_GIT_REF = %r{\A[\w./-]+\z}

    # Run an arbitrary git command inside +repo_path+.
    # Returns [stdout, Process::Status]. stderr is captured and discarded to
    # prevent git diagnostic messages from leaking into the Rails server log.
    # Honors config.git_timeout (seconds) when set.
    def run_git(repo_path, *args)
      timeout_secs = Mbeditor.configuration.git_timeout&.to_i
      out = +""; timed_out = false; exit_status = nil

      Open3.popen3("git", "-C", repo_path, *args, pgroup: true) do |stdin, stdout, _stderr, wait_thr|
        stdin.close

        timer = if timeout_secs && timeout_secs > 0
          Thread.new do
            sleep timeout_secs
            timed_out = true
            Process.kill("-KILL", wait_thr.pid)
          rescue Errno::ESRCH
            nil
          end
        end

        out = stdout.read
        exit_status = wait_thr.value
        timer&.kill
      end

      raise Timeout::Error, "git timed out after #{timeout_secs}s" if timed_out
      [out, exit_status]
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

    # Returns [merge_base_sha, ref_name] of the first candidate base branch found,
    # or [nil, nil] if none can be determined.  Candidates are tried in preference
    # order; skips the current branch and refs whose merge-base equals HEAD.
    def find_branch_base(repo_path, current_branch, candidates: nil)
      candidates ||= Mbeditor.configuration.base_branch_candidates
      head_sha_out, = run_git(repo_path, "rev-parse", "HEAD")
      head_sha = head_sha_out.strip

      candidates.each do |ref|
        short = ref.delete_prefix("origin/")
        next if short == current_branch || ref == current_branch

        _o, st = run_git(repo_path, "rev-parse", "--verify", "--quiet", ref)
        next unless st.success?

        base_out, base_st = run_git(repo_path, "merge-base", "HEAD", ref)
        next unless base_st.success?

        sha = base_out.strip
        next unless sha.match?(/\A[0-9a-f]{40}\z/)
        next if sha == head_sha

        return [sha, ref]
      end

      [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    # Parse `git diff --numstat` output.
    # Returns Hash of path => { added: Integer, removed: Integer }.
    def parse_numstat(output)
      (output || "").lines.each_with_object({}) do |line, map|
        parts = line.strip.split("\t", 3)
        next if parts.length < 3 || parts[0] == "-"

        map[parts[2].strip] = { added: parts[0].to_i, removed: parts[1].to_i }
      end
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
    def resolve_path(repo_path, relative)
      return nil if relative.blank?

      full = File.expand_path(relative.to_s, repo_path.to_s)
      full.start_with?(repo_path.to_s + "/") || full == repo_path.to_s ? full : nil
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
