# frozen_string_literal: true

require "open3"

module Mbeditor
  module GitInfoService
    module_function

    GIT_INFO_MUTEX = Mutex.new
    private_constant :GIT_INFO_MUTEX

    def call(repo_path)
      cached = cached_git_info(repo_path)
      return cached if cached

      branch = GitService.current_branch(repo_path)
      unless branch
        return { ok: false, error: "Unable to determine current branch" }
      end

      # Wave 1: all independent git reads run in parallel
      status_t   = Thread.new { Open3.capture3("git", "-C", repo_path, "status", "--porcelain") }
      numstat_t  = Thread.new { Open3.capture3("git", "-C", repo_path, "diff", "--numstat", "HEAD") }
      upstream_t = Thread.new { Open3.capture3("git", "-C", repo_path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") }
      base_t     = Thread.new { GitService.find_branch_base(repo_path, branch) }

      working_output, _err, working_status = status_t.value
      working_tree = working_status.success? ? GitService.parse_porcelain_status(working_output) : []

      numstat_out = numstat_t.value.first
      numstat_map = GitService.parse_numstat(numstat_out)
      working_tree = working_tree.map { |f| f.merge(numstat_map.fetch(f[:path], {})) }

      upstream_output, _err, upstream_status = upstream_t.value
      upstream_branch = upstream_status.success? ? upstream_output.strip : nil
      upstream_branch = nil unless upstream_branch&.match?(%r{\A[\w./-]+\z})

      base_sha, base_ref = base_t.value

      ahead_count    = 0
      behind_count   = 0
      unpushed_files = []
      unpushed_commits = []
      diff_base = base_sha || upstream_branch

      # Wave 2: conditional parallel reads that depend on Wave 1 results
      wave2 = {}
      wave2[:counts]    = Thread.new { Open3.capture3("git", "-C", repo_path, "rev-list", "--left-right", "--count", "HEAD...#{upstream_branch}") } if upstream_branch.to_s != ""
      wave2[:unp_log]   = Thread.new { Open3.capture3("git", "-C", repo_path, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e") } if upstream_branch.to_s != ""
      wave2[:diff_name] = Thread.new { Open3.capture3("git", "-C", repo_path, "diff", "--name-status", "#{diff_base}..HEAD") } if diff_base.to_s != ""
      wave2[:diff_num]  = Thread.new { Open3.capture3("git", "-C", repo_path, "diff", "--numstat", "#{diff_base}..HEAD") } if diff_base.to_s != ""
      wave2[:branch_log] = Thread.new do
        if base_sha
          Open3.capture3("git", "-C", repo_path, "log", "--first-parent", "#{base_sha}..HEAD",
                         "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        else
          Open3.capture3("git", "-C", repo_path, "log", "--first-parent", branch, "-n", "100",
                         "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        end
      end

      wave2.each_value(&:join)

      if (ct = wave2[:counts])
        counts_output, _err, counts_status = ct.value
        if counts_status.success?
          ahead_str, behind_str = counts_output.strip.split("\t", 2)
          ahead_count  = ahead_str.to_i
          behind_count = behind_str.to_i
        end
      end

      if (ul = wave2[:unp_log])
        unpushed_log_output, _err, unpushed_log_status = ul.value
        unpushed_commits = GitService.parse_git_log(unpushed_log_output) if unpushed_log_status.success?
      end

      if (dn = wave2[:diff_name]) && (dnum = wave2[:diff_num])
        diff_name_out, _err, diff_name_status = dn.value
        if diff_name_status.success?
          unpushed_files  = GitService.parse_name_status(diff_name_out)
          unp_numstat_out = dnum.value.first
          unp_numstat_map = GitService.parse_numstat(unp_numstat_out)
          unpushed_files  = unpushed_files.map { |f| f.merge(unp_numstat_map.fetch(f[:path], {})) }
        end
      end

      branch_log_output, _err, branch_log_status = wave2[:branch_log].value
      branch_commits = branch_log_status.success? ? GitService.parse_git_log(branch_log_output) : []

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
      { ok: false, error: e.message }
    end

    def invalidate(repo_path)
      GIT_INFO_MUTEX.synchronize do
        cache = instance_variable_get(:@git_info_cache) || {}
        cache.delete(repo_path)
        instance_variable_set(:@git_info_cache, cache)
      end
    end

    def cached_git_info(repo_path, ttl: 5)
      GIT_INFO_MUTEX.synchronize do
        cache = instance_variable_get(:@git_info_cache) || {}
        entry = cache[repo_path]
        return entry[:data] if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < ttl
      end
      nil
    end

    def store_git_info(repo_path, data)
      GIT_INFO_MUTEX.synchronize do
        cache = instance_variable_get(:@git_info_cache) || {}
        cache[repo_path] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
        instance_variable_set(:@git_info_cache, cache)
      end
    end
  end
end
