# frozen_string_literal: true

require "open3"
require "pathname"

module Mbeditor
  class ApplicationController < ActionController::Base
    private

    def ensure_allowed_environment!
      allowed = Array(Mbeditor.configuration.allowed_environments).map(&:to_sym)
      render plain: 'Not found', status: :not_found unless allowed.include?(Rails.env.to_sym)
    end

    def workspace_root
      configured_root = Mbeditor.configuration.workspace_root
      if configured_root.present?
        Pathname.new(configured_root.to_s)
      else
        self.class.instance_variable_get(:@workspace_root_cache) ||
          self.class.instance_variable_set(:@workspace_root_cache, begin
            rails_root = Rails.root.to_s
            out, status = Open3.capture2("git", "-C", rails_root, "rev-parse", "--show-toplevel")
            Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
          rescue StandardError
            Rails.root
          end)
      end
    end

    # Expand path and confirm it's inside workspace_root.
    # For existing paths we also resolve symlinks so that a symlink inside the
    # workspace that points outside cannot be used to escape the sandbox.
    def resolve_path(raw)
      return nil if raw.blank?

      root = workspace_root.to_s
      full = File.expand_path(raw.to_s, root)
      return nil unless full.start_with?("#{root}/") || full == root

      if File.exist?(full)
        real_root = File.realpath(root)
        real = File.realpath(full)
        return nil unless real.start_with?("#{real_root}/") || real == real_root
      end

      full
    rescue Errno::EACCES
      nil
    end

    def relative_path(full)
      root = workspace_root.to_s
      return "" if full == root

      full.delete_prefix(root + "/")
    end
  end
end
