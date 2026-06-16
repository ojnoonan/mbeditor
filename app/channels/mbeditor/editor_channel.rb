# frozen_string_literal: true

require "pathname"

module Mbeditor
  CableBaseClass = defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object

  class EditorChannel < CableBaseClass
    def subscribed
      stream_from "mbeditor_editor" if respond_to?(:stream_from)
    end

    # Push newly appended log lines to this subscriber ~once a second while the
    # client has the log panel open. Guarded so the class still loads when
    # ActionCable is absent (CableBaseClass == Object).
    periodically :push_log_lines, every: 1 if respond_to?(:periodically)

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

    def start_log_tail(data)
      raw = data && data["offset"]
      @log_offset = raw.nil? ? nil : raw.to_i
      @log_watching = true
    end

    def stop_log_tail(_data = nil)
      @log_watching = false
    end

    private

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
