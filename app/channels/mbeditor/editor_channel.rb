# frozen_string_literal: true

require "open3"
require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
    include ChannelAuthentication

    def subscribed
      return unless mbeditor_authenticated?

      stream_from "mbeditor_editor" if respond_to?(:stream_from)
    end

    # Push newly appended log lines to this subscriber ~once a second while the
    # client has the log panel open. Guarded so the class still loads when
    # ActionCable is absent (CableBaseClass == Object).
    periodically :push_log_lines, every: 1 if respond_to?(:periodically)

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
    rescue EditorStateService::InvalidBranchError
      # A misbehaving client sent a malformed branch name. Don't crash the
      # connection, but log it so the misconfiguration is observable.
      Rails.logger.warn("[mbeditor] EditorChannel#save_branch_state: rejected invalid branch name #{branch.inspect}")
    rescue StandardError
      # Never let a state-save failure crash the WebSocket connection
    end

    def start_log_tail(data)
      raw = data && data["offset"]
      @log_offset = raw.nil? ? nil : raw.to_i
      @log_watching = true
    end

    def stop_log_tail(_data = nil)
      @log_watching = false
    end

    private

    def relay(payload)
      return unless defined?(ActionCable) && ActionCable.respond_to?(:server)

      ActionCable.server.broadcast("mbeditor_editor", payload)
    rescue StandardError
      # Never let a relay failure crash the WebSocket connection.
    end

    def push_log_lines
      return unless @log_watching

      result = LogTailService.new(log_path).read_since(@log_offset)
      @log_offset = result[:offset]
      return if result[:lines].empty? && !result[:reset]

      transmit({ type: "log", lines: result[:lines], offset: result[:offset], reset: result[:reset] })
    rescue StandardError
      # Never let a log-tail failure crash the WebSocket connection.
    end

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end

    def workspace_root
      WorkspaceRootResolver.call
    end
  end
end
