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

    def initialize(workspace_root, lock_timeout: DEFAULT_LOCK_TIMEOUT)
      @root = workspace_root
      @lock_timeout = lock_timeout
    end

    def read_state
      locked_json_file(workspace_path).read
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def read_branch_state(branch)
      locked_json_file(branch_states_path).read[branch] || {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def write_branch_state(branch, state)
      raise InvalidBranchError, "Invalid branch name" unless branch.match?(SAFE_BRANCH_NAME)
      payload_json = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload_json.bytesize > STATE_MAX_BYTES
      file = locked_json_file(branch_states_path)
      file.with_lock do
        existing = file.read
        # Auto-save fires on a timer even with no changes; skip the full-file
        # rewrite when this branch's entry is already identical.
        next if existing[branch] == JSON.parse(payload_json)

        existing[branch] = state
        file.write(existing)
      end
      nil
    end

    def prune_branch_states(active_branches:)
      path = branch_states_path
      return [] unless File.exist?(path)
      file = locked_json_file(path)
      pruned = []
      file.with_lock do
        all = begin
          file.read
        rescue JSON::ParserError => e
          Rails.logger.error("[mbeditor] EditorStateService#prune_branch_states: discarding corrupt branch_states JSON at #{path}: #{e.message}")
          {}
        end
        pruned = all.keys - active_branches
        if pruned.any?
          pruned.each { |b| all.delete(b) }
          file.write(all)
        end
      end
      pruned
    end

    def write_state(state)
      payload = state.to_json
      raise PayloadTooLargeError, "State payload too large" if payload.bytesize > STATE_MAX_BYTES
      file = locked_json_file(workspace_path)
      file.with_lock { file.write(payload) }
      nil
    end

    private

    def locked_json_file(path)
      LockedJsonFile.new(path, lock_timeout: @lock_timeout, error_class: LockTimeoutError)
    end

    def workspace_path
      @root.join("tmp", "mbeditor_workspace.json")
    end

    def branch_states_path
      @root.join("tmp", "mbeditor_branch_states.json")
    end
  end
end
