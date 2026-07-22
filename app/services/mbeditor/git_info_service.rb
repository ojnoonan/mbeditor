# frozen_string_literal: true

module Mbeditor
  module GitInfoService
    module_function

    GIT_INFO_MUTEX = Mutex.new
    private_constant :GIT_INFO_MUTEX

    # How long a computed payload stays fresh. Must exceed the frontend's
    # lite-poll interval (5s) so steady-state polls never trigger the full
    # multi-subprocess fan-out below.
    CACHE_TTL = 10

    def call(repo_path)
      cached = cached_git_info(repo_path)
      return cached if cached

      owner = nil
      GIT_INFO_MUTEX.synchronize do
        @git_info_flights ||= {}
        owner = @git_info_flights[repo_path]
        @git_info_flights[repo_path] = Thread.current unless owner
      end

      if owner
        # Another thread is already running the fan-out; don't duplicate it.
        stale = stale_git_info(repo_path)
        return stale if stale

        owner.join(CACHE_TTL)
        return cached_git_info(repo_path) || stale_git_info(repo_path) ||
               { ok: false, error: "git info computation in progress" }
      end

      begin
        compute(repo_path)
      ensure
        GIT_INFO_MUTEX.synchronize { @git_info_flights.delete(repo_path) }
      end
    end

    def compute(repo_path)
      branch = GitService.current_branch(repo_path)
      unless branch
        return stale_or_error(repo_path, "Unable to determine current branch")
      end

      # Wave 1: all independent git reads run in parallel
      status_t   = Thread.new { safe_git(repo_path, "status", "--porcelain") }
      numstat_t  = Thread.new { safe_git(repo_path, "diff", "--numstat", "HEAD") }
      upstream_t = Thread.new { safe_git(repo_path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") }
      base_t     = Thread.new { GitService.find_branch_base(repo_path, branch) }

      working_output, working_ok = status_t.value
      working_tree = working_ok ? GitService.parse_porcelain_status(working_output) : []

      numstat_out, = numstat_t.value
      numstat_map = GitService.parse_numstat(numstat_out)
      working_tree = working_tree.map { |f| f.merge(numstat_map.fetch(f[:path], {})) }

      upstream_output, upstream_ok = upstream_t.value
      upstream_branch = upstream_ok ? upstream_output.strip : nil
      upstream_branch = nil unless upstream_branch&.match?(%r{\A[\w./-]+\z})

      base_sha, base_ref = base_t.value

      ahead_count    = 0
      behind_count   = 0
      unpushed_files = []
      unpushed_commits = []
      diff_base = base_sha || upstream_branch

      # Wave 2: conditional parallel reads that depend on Wave 1 results
      wave2 = {}
      wave2[:counts]    = Thread.new { safe_git(repo_path, "rev-list", "--left-right", "--count", "HEAD...#{upstream_branch}") } if upstream_branch.to_s != ""
      wave2[:unp_log]   = Thread.new { safe_git(repo_path, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e") } if upstream_branch.to_s != ""
      wave2[:diff_name] = Thread.new { safe_git(repo_path, "diff", "--name-status", "#{diff_base}..HEAD") } if diff_base.to_s != ""
      wave2[:diff_num]  = Thread.new { safe_git(repo_path, "diff", "--numstat", "#{diff_base}..HEAD") } if diff_base.to_s != ""
      wave2[:branch_log] = Thread.new do
        if base_sha
          safe_git(repo_path, "log", "--first-parent", "#{base_sha}..HEAD",
                   "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        else
          safe_git(repo_path, "log", "--first-parent", branch, "-n", "100",
                   "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        end
      end

      wave2.each_value(&:join)

      if (ct = wave2[:counts])
        counts_output, counts_ok = ct.value
        if counts_ok
          ahead_str, behind_str = counts_output.strip.split("\t", 2)
          ahead_count  = ahead_str.to_i
          behind_count = behind_str.to_i
        end
      end

      if (ul = wave2[:unp_log])
        unpushed_log_output, unpushed_log_ok = ul.value
        unpushed_commits = GitService.parse_git_log(unpushed_log_output) if unpushed_log_ok
      end

      if (dn = wave2[:diff_name]) && (dnum = wave2[:diff_num])
        diff_name_out, diff_name_ok = dn.value
        if diff_name_ok
          unpushed_files  = GitService.parse_name_status(diff_name_out)
          unp_numstat_out = dnum.value.first
          unp_numstat_map = GitService.parse_numstat(unp_numstat_out)
          unpushed_files  = unpushed_files.map { |f| f.merge(unp_numstat_map.fetch(f[:path], {})) }
        end
      end

      branch_log_output, branch_log_ok = wave2[:branch_log].value
      branch_commits = branch_log_ok ? GitService.parse_git_log(branch_log_output) : []

      redmine_ticket_id = nil
      if Mbeditor.configuration.redmine_enabled
        if Mbeditor.configuration.redmine_ticket_source == :branch
          m = branch.match(/\A(\d+)/)
          redmine_ticket_id = m[1] if m
        else
          branch_commits.each do |commit|
            m = commit["title"]&.match(/#(\d+)/)
            if m
              redmine_ticket_id = m[1]
              break
            end
          end
        end
      end

      payload = {
        ok: true,
        branch: branch,
        upstreamBranch: upstream_branch,
        ahead: ahead_count,
        behind: behind_count,
        workingTree: working_tree,
        unpushedFiles: unpushed_files,
        unpushedCommits: unpushed_commits,
        branchCommits: branch_commits,
        branchBaseRef: base_ref,
        redmineTicketId: redmine_ticket_id
      }
      store_git_info(repo_path, payload)
      payload
    rescue StandardError => e
      stale_or_error(repo_path, e.message)
    end

    # Run a git command via GitService.run_git (which honors config.git_timeout
    # through ProcessRunner). Returns [stdout, ok]; a timed-out or failed call
    # degrades to ["", false] so one slow subprocess only blanks its own field
    # instead of failing the whole payload.
    def safe_git(repo_path, *args)
      out, status = GitService.run_git(repo_path, *args)
      [out, status.success?]
    rescue StandardError
      ["", false]
    end

    def invalidate(repo_path)
      GIT_INFO_MUTEX.synchronize do
        cache = @git_info_cache || {}
        cache.delete(repo_path)
        @git_info_cache = cache
      end
    end

    def cached_git_info(repo_path, ttl: CACHE_TTL)
      GIT_INFO_MUTEX.synchronize do
        cache = @git_info_cache || {}
        entry = cache[repo_path]
        return entry[:data] if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < ttl
      end
      nil
    end

    # Last computed payload regardless of TTL; nil if never computed.
    def stale_git_info(repo_path)
      GIT_INFO_MUTEX.synchronize do
        entry = (@git_info_cache || {})[repo_path]
        return entry[:data].merge(stale: true) if entry
      end
      nil
    end

    def stale_or_error(repo_path, message)
      stale_git_info(repo_path) || { ok: false, error: message }
    end

    def store_git_info(repo_path, data)
      GIT_INFO_MUTEX.synchronize do
        cache = @git_info_cache || {}
        cache[repo_path] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
        @git_info_cache = cache
      end
    end
  end
end
