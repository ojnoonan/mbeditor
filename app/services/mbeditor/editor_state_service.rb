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
      read_json(workspace_path)
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def read_branch_state(branch)
      read_json(branch_states_path)[branch] || {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def write_branch_state(branch, state)
      raise InvalidBranchError, "Invalid branch name" unless branch.match?(SAFE_BRANCH_NAME)
      payload_json = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload_json.bytesize > STATE_MAX_BYTES
      path = branch_states_path
      FileUtils.mkdir_p(path.dirname)
      with_lock(path) do
        existing = read_json(path)
        # Auto-save fires on a timer even with no changes; skip the full-file
        # rewrite when this branch's entry is already identical.
        next if existing[branch] == JSON.parse(payload_json)

        existing[branch] = state
        atomic_write(path, existing.to_json)
      end
      nil
    end

    def prune_branch_states(active_branches:)
      path = branch_states_path
      return [] unless File.exist?(path)
      pruned = []
      with_lock(path) do
        all = begin
          read_json(path)
        rescue JSON::ParserError => e
          Rails.logger.error("[mbeditor] EditorStateService#prune_branch_states: discarding corrupt branch_states JSON at #{path}: #{e.message}")
          {}
        end
        pruned = all.keys - active_branches
        if pruned.any?
          pruned.each { |b| all.delete(b) }
          atomic_write(path, all.to_json)
        end
      end
      pruned
    end

    def write_state(state)
      payload = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload.bytesize > STATE_MAX_BYTES
      path = workspace_path
      FileUtils.mkdir_p(path.dirname)
      with_lock(path) { atomic_write(path, payload) }
      nil
    end

    private

    # Readers take no lock at all: every write lands by rename, so a read sees
    # either the whole previous file or the whole new one — never the empty
    # window a truncate-then-write leaves, which readers swallowed as {}.
    def read_json(path)
      return {} unless File.exist?(path)

      raw = File.read(path)
      raw.empty? ? {} : JSON.parse(raw)
    end

    def atomic_write(path, payload)
      tmp = "#{path}.tmp"
      File.write(tmp, payload)
      File.rename(tmp, path)
    end

    # The lock sits on a sidecar file, not on the state file: the state file is
    # replaced by rename, so a lock held on the inode it had before the write
    # would exclude nobody afterwards.
    def with_lock(path)
      File.open("#{path}.lock", File::RDWR | File::CREAT) do |f|
        lock_exclusive!(f)
        yield
      end
    end

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
