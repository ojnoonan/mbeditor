# frozen_string_literal: true

module Mbeditor
  # A bounded, in-memory ring of exceptions raised by the host app, so a failed
  # request shows up in the editor instead of only in the log.
  #
  # Lives in lib/ (required from lib/mbeditor.rb, NOT autoloaded) for the same
  # reason as RubyLspClient: a Zeitwerk reload in the host's dev environment
  # must not wipe the buffer you are trying to read.
  #
  # Fed by an ActiveSupport::Notifications subscriber wired up in the engine.
  # A Rack middleware cannot be used here: ActionDispatch::DebugExceptions
  # rescues and renders the error, so nothing outside it ever sees the raise.
  module ExceptionLog
    MAX_ENTRIES = 50

    # Backtraces are mostly framework and gem frames, which this editor cannot
    # open and which push the app's own frames off the end.
    MAX_FRAMES = 10

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      # Returns the recorded entry, or nil when there was nothing to record.
      def record(exception, payload = {}, workspace_root: nil)
        return nil if exception.nil?

        entry = build(exception, payload, workspace_root)
        MUTEX.synchronize do
          @entries ||= []
          @entries << entry
          @entries.shift while @entries.length > MAX_ENTRIES
        end
        entry
      end

      # Newest first — the one you just triggered is the one you want.
      def entries
        MUTEX.synchronize { (@entries || []).reverse }
      end

      def clear!
        MUTEX.synchronize { @entries = [] }
        nil
      end

      private

      def build(exception, payload, workspace_root)
        @seq = (@seq || 0) + 1
        {
          type: "exception",
          id: @seq,
          at: Time.now.utc.iso8601,
          klass: exception.class.name,
          message: exception.message.to_s[0, 2000],
          controller: payload[:controller],
          action: payload[:action],
          path: payload[:path],
          frames: workspace_frames(exception, workspace_root)
        }
      end

      # Only frames inside the workspace, with the root stripped. Absolute host
      # paths are both a leak and useless to an editor that addresses files
      # workspace-relative.
      def workspace_frames(exception, workspace_root)
        root = workspace_root.to_s
        return [] if root.empty?

        prefix = root.end_with?("/") ? root : "#{root}/"
        Array(exception.backtrace).filter_map do |frame|
          next unless frame.start_with?(prefix)

          file, line = frame.delete_prefix(prefix).split(":", 3)
          next if file.nil? || file.empty?

          { file: file, line: line.to_i }
        end.first(MAX_FRAMES)
      end
    end
  end
end
