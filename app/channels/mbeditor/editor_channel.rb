# frozen_string_literal: true

require "open3"
require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
    WORKSPACE_ROOT_MUTEX = Mutex.new
    private_constant :WORKSPACE_ROOT_MUTEX
    def subscribed
      stream_from "mbeditor_editor" if respond_to?(:stream_from)
    end

    def unsubscribed
      # no-op
    end

    def save_state(data)
      state = data["state"] || data
      EditorStateService.new(workspace_root).write_state(state)
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    def save_branch_state(data)
      branch = data["branch"].to_s.strip
      state  = data["state"]
      EditorStateService.new(workspace_root).write_branch_state(branch, state)
    rescue EditorStateService::InvalidBranchError
      # A misbehaving client sent a malformed branch name. Don't crash the
      # connection, but log it so the misconfiguration is observable.
      Rails.logger.warn("[mbeditor] EditorChannel#save_branch_state: rejected invalid branch name #{branch.inspect}")
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    private

    def workspace_root
      configured = Mbeditor.configuration.workspace_root
      return Pathname.new(configured.to_s) if configured.present?

      # Fast path: already cached on this channel class.
      cached = self.class.instance_variable_get(:@workspace_root_cache)
      return cached if cached

      # Slow path: compute once under a mutex so heavy auto-save traffic doesn't
      # spawn a `git rev-parse` subprocess on every WebSocket action.
      WORKSPACE_ROOT_MUTEX.synchronize do
        self.class.instance_variable_get(:@workspace_root_cache) ||
          self.class.instance_variable_set(:@workspace_root_cache, begin
            rails_root = Rails.root.to_s
            out, _err, status = Open3.capture3("git", "-C", rails_root, "rev-parse", "--show-toplevel")
            Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
          rescue StandardError
            Rails.root
          end)
      end
    end
  end
end
