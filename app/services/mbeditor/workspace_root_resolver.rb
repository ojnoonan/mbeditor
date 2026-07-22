# frozen_string_literal: true

require "open3"
require "pathname"

module Mbeditor
  # Single source of truth for locating the workspace root. Used by both the
  # HTTP controllers and the ActionCable channel so the `git rev-parse`
  # subprocess runs at most once per process instead of once per call site.
  module WorkspaceRootResolver
    module_function

    MUTEX = Mutex.new
    private_constant :MUTEX

    def call
      configured = Mbeditor.configuration.workspace_root
      # Configured path intentionally bypasses the memo — tests and initializers
      # may change it at any time.
      return Pathname.new(configured.to_s) if configured.present?

      cached = @resolved_root
      return cached if cached

      MUTEX.synchronize do
        @resolved_root ||= begin
          rails_root = Rails.root.to_s
          out, _err, status = Open3.capture3("git", "-C", rails_root, "rev-parse", "--show-toplevel")
          Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
        rescue StandardError
          Rails.root
        end
      end
    end

    def reset!
      MUTEX.synchronize { @resolved_root = nil }
    end
  end
end
