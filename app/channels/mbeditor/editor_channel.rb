# frozen_string_literal: true

require "fileutils"
require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
    STATE_MAX_BYTES    = 1 * 1024 * 1024
    SAFE_BRANCH_NAME   = /\A[a-zA-Z0-9._\-\/]+\z/

    def subscribed
      stream_from "mbeditor_editor" if respond_to?(:stream_from)
    end

    def unsubscribed
      # no-op
    end

    # Called via WebSocketService.perform('save_state', { state: ... })
    def save_state(data)
      Rails.logger.silence do
        payload = (data["state"] || data).to_json
        return if payload.bytesize > STATE_MAX_BYTES

        root = workspace_root
        path = root.join("tmp", "mbeditor_workspace.json")
        FileUtils.mkdir_p(root.join("tmp"))
        File.open(path, File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          f.truncate(0)
          f.rewind
          f.write(payload)
        end
      end
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    # Called via WebSocketService.perform('save_branch_state', { branch: ..., state: ... })
    def save_branch_state(data)
      Rails.logger.silence do
        branch = data["branch"].to_s.strip
        return unless branch.match?(SAFE_BRANCH_NAME)

        state_data = data["state"]
        payload_json = state_data.to_json
        return if payload_json.bytesize > STATE_MAX_BYTES

        root = workspace_root
        path = root.join("tmp", "mbeditor_branch_states.json")
        FileUtils.mkdir_p(root.join("tmp"))
        File.open(path, File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          existing = f.size > 0 ? JSON.parse(f.read) : {}
          existing[branch] = state_data
          f.truncate(0)
          f.rewind
          f.write(existing.to_json)
        end
      end
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    private

    def workspace_root
      configured = Mbeditor.configuration.workspace_root
      return Pathname.new(configured.to_s) if configured.present?

      # Fall back to git root, same logic as ApplicationController
      rails_root = Rails.root.to_s
      out, _err, status = Open3.capture3("git", "-C", rails_root, "rev-parse", "--show-toplevel")
      Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
    rescue StandardError
      Rails.root
    end
  end
end
