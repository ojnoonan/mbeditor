# frozen_string_literal: true

module Mbeditor
  class EditorStateService
    PayloadTooLargeError = Class.new(StandardError)
    InvalidBranchError   = Class.new(StandardError)

    STATE_MAX_BYTES  = 1 * 1024 * 1024
    SAFE_BRANCH_NAME = /\A[a-zA-Z0-9._\-\/]+\z/

    def initialize(workspace_root)
      @root = workspace_root
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
        f.flock(File::LOCK_EX)
        existing = f.size > 0 ? JSON.parse(f.read) : {}
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
        f.flock(File::LOCK_EX)
        all = JSON.parse(f.read) rescue {}
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
        f.flock(File::LOCK_EX)
        f.truncate(0)
        f.rewind
        f.write(payload)
      end
      nil
    end

    private

    def workspace_path
      @root.join("tmp", "mbeditor_workspace.json")
    end

    def branch_states_path
      @root.join("tmp", "mbeditor_branch_states.json")
    end
  end
end
