# frozen_string_literal: true

require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
    include ChannelAuthentication

    def subscribed
      return unless mbeditor_authenticated?

      stream_from "mbeditor_editor" if respond_to?(:stream_from)
    end

    def unsubscribed
      # Announce that this participant has left so peers can drop them from the
      # roster. Only meaningful once we've seen a presence heartbeat.
      return if @presence_client_id.nil?

      relay("type" => "presence", "status" => "leave", "client_id" => @presence_client_id)
    end

    # Presence heartbeat: relay this participant's identity + which file they are
    # in to every other peer on the global stream. The channel adds the envelope
    # (type/status); the rest is opaque relay. Resilient like CollaborationChannel
    # — a broadcast failure must never crash the socket.
    def presence(data)
      @presence_client_id = data["client_id"]
      relay(
        "type"         => "presence",
        "status"       => "here",
        "client_id"    => data["client_id"],
        "name"         => data["name"],
        "colour"       => data["colour"],
        "current_file" => data["current_file"]
      )
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

    def relay(payload)
      return unless defined?(ActionCable) && ActionCable.respond_to?(:server)

      ActionCable.server.broadcast("mbeditor_editor", payload)
    rescue StandardError
      # Never let a relay failure crash the WebSocket connection.
    end

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
