# frozen_string_literal: true

module Mbeditor
  class EditorStateService
    PayloadTooLargeError = Class.new(StandardError)
    InvalidBranchError   = Class.new(StandardError)
    LockTimeoutError     = Class.new(StandardError)

    STATE_MAX_BYTES   = 1 * 1024 * 1024
    SAFE_BRANCH_NAME  = /\A[a-zA-Z0-9._\-\/]+\z/
    # State writes take an exclusive file lock shared with EditorChannel. A
    # blocking acquire would let a single stuck holder (e.g. a request paused at
    # a breakpoint mid-write) wedge every later save indefinitely, so the lock
    # is acquired non-blocking with a bounded retry and gives up with a clear
    # error rather than hanging the worker.
    DEFAULT_LOCK_TIMEOUT = 5.0
    LOCK_RETRY_INTERVAL  = 0.01

    def initialize(workspace_root, lock_timeout: DEFAULT_LOCK_TIMEOUT)
      @root = workspace_root
      @lock_timeout = lock_timeout
    end

    def read_state
      path = workspace_path
      return {} unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def read_branch_state(branch)
      path = branch_states_path
      return {} unless File.exist?(path)
      all = JSON.parse(File.read(path))
      all[branch] || {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def write_branch_state(branch, state)
      raise InvalidBranchError, "Invalid branch name" unless branch.match?(SAFE_BRANCH_NAME)
      payload_json = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload_json.bytesize > STATE_MAX_BYTES
      path = branch_states_path
      FileUtils.mkdir_p(path.dirname)
      File.open(path, File::RDWR | File::CREAT) do |f|
        lock_exclusive!(f)
        existing = f.size > 0 ? JSON.parse(f.read) : {}
        # Auto-save fires on a timer even with no changes; skip the full-file
        # rewrite when this branch's entry is already identical.
        break if existing[branch] == JSON.parse(payload_json)

        existing[branch] = state
        f.truncate(0)
        f.rewind
        f.write(existing.to_json)
      end
      nil
    end

    def prune_branch_states(active_branches:)
      path = branch_states_path
      return [] unless File.exist?(path)
      pruned = []
      File.open(path, File::RDWR) do |f|
        lock_exclusive!(f)
        all = begin
          JSON.parse(f.read)
        rescue JSON::ParserError => e
          Rails.logger.error("[mbeditor] EditorStateService#prune_branch_states: discarding corrupt branch_states JSON at #{path}: #{e.message}")
          {}
        end
        pruned = all.keys - active_branches
        if pruned.any?
          pruned.each { |b| all.delete(b) }
          f.truncate(0)
          f.rewind
          f.write(all.to_json)
        end
      end
      pruned
    end

    def write_state(state)
      payload = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload.bytesize > STATE_MAX_BYTES
      path = workspace_path
      FileUtils.mkdir_p(path.dirname)
      File.open(path, File::RDWR | File::CREAT) do |f|
        lock_exclusive!(f)
        f.truncate(0)
        f.rewind
        f.write(payload)
      end
      nil
    end

    private

    # Acquire an exclusive lock without blocking forever. Retries the
    # non-blocking flock until @lock_timeout elapses, then raises so the caller
    # fails fast instead of pinning a worker on a stuck holder.
    def lock_exclusive!(file)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise LockTimeoutError, "could not acquire state lock within #{@lock_timeout}s"
        end
        sleep LOCK_RETRY_INTERVAL
      end
    end

    def workspace_path
      @root.join("tmp", "mbeditor_workspace.json")
    end

    def branch_states_path
      @root.join("tmp", "mbeditor_branch_states.json")
    end
  end
end
