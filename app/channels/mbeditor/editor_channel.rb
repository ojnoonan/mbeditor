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
      # Hand the joiner the current roster straight away. Without it they would
      # only learn about a peer who happens to heartbeat after they connected,
      # and would show an empty participant list until then.
      transmit(presence_payload) if respond_to?(:transmit, true)
    end

    # Push newly appended log lines to this subscriber ~once a second while the
    # client has the log panel open. Guarded so the class still loads when
    # ActionCable is absent (CableBaseClass == Object).
    periodically :push_log_lines, every: 1 if respond_to?(:periodically)

    def unsubscribed
      # Action Cable calls this on a clean close *and* on its own connection
      # timeout, which is what makes the registry authoritative: a participant
      # cannot linger past their socket.
      return if @presence_client_id.nil?

      PresenceRegistry.remove(@presence_client_id)
      relay(presence_payload)
    end

    # Presence heartbeat: record this participant and broadcast the whole roster.
    #
    # Whole roster, not just the sender: clients replace theirs outright, so they
    # cannot accumulate a participant the server has already dropped. That is the
    # one guarantee per-participant events could not give, and it also removes the
    # client-side merge, the leave handling and the greet-a-new-peer re-announce
    # that used to stand in for it.
    def presence(data)
      @presence_client_id = data["client_id"]
      PresenceRegistry.record(@presence_client_id, data)
      relay(presence_payload)
    end

    def save_state(data)
      state = data["state"] || data
      EditorStateService.new(workspace_root).write_state(state)
    rescue StandardError => e
      # Never let a state-save failure crash the WebSocket connection — but a
      # silently dropped save looked exactly like a working one.
      Rails.logger.warn("[mbeditor] EditorChannel#save_state failed: #{e.class}: #{e.message}")
    end

    def save_branch_state(data)
      branch = data["branch"].to_s.strip
      state  = data["state"]
      EditorStateService.new(workspace_root).write_branch_state(branch, state)
    rescue EditorStateService::InvalidBranchError
      # A misbehaving client sent a malformed branch name. Don't crash the
      # connection, but log it so the misconfiguration is observable.
      Rails.logger.warn("[mbeditor] EditorChannel#save_branch_state: rejected invalid branch name #{branch.inspect}")
    rescue StandardError => e
      # Never let a state-save failure crash the WebSocket connection
      Rails.logger.warn("[mbeditor] EditorChannel#save_branch_state failed: #{e.class}: #{e.message}")
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

    def presence_payload
      { "type" => "presence", "roster" => PresenceRegistry.roster }
    end

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
