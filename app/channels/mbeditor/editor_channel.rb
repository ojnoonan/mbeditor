# frozen_string_literal: true

require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
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
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    private

    def workspace_root
      configured = Mbeditor.configuration.workspace_root
      return Pathname.new(configured.to_s) if configured.present?

      rails_root = Rails.root.to_s
      out, _err, status = Open3.capture3("git", "-C", rails_root, "rev-parse", "--show-toplevel")
      Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
    rescue StandardError
      Rails.root
    end
  end
end
