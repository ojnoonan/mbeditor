# frozen_string_literal: true

module Mbeditor
  # No `rescue_from StandardError` here, and the repeated
  # `rescue StandardError => e; render json: { error: e.message },
  # status: :unprocessable_content` at the foot of ~29 actions is deliberate,
  # not something waiting to be dried up. Most actions in this engine have no
  # rescue at all and rely on an unhandled error surfacing as a real 500:
  # resilient_routing_test.rb asserts exactly that, to prove ResilientRouter
  # sits below Rails' own exception middleware. A blanket handler swallows that
  # signal for 18 actions here plus `tail` in LogsController. Collapsing it to
  # one handler plus a per-controller allowlist was tried and reverted: it saved
  # 21 lines, moved each action's error behaviour a thousand lines away from the
  # action, and left the same action names duplicated in the allowlist.
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
    # Before the auth hook, and on every controller: a disallowed environment is
    # "this engine is not here", so it must 404 without running the host app's
    # authenticate_with proc. Declaring it per-controller meant LogsController
    # missed it entirely and served the environment's log file anywhere.
    before_action :ensure_allowed_environment!
    before_action :run_authentication

    private

    def run_authentication
      auth = Mbeditor.configuration.authenticate_with
      return unless auth
      ttl = Mbeditor.configuration.authentication_cache_ttl.to_i
      if ttl > 0
        last = session[:mbeditor_authed_at].to_i
        return if last > 0 && (Time.now.to_i - last) < ttl
      end
      instance_exec(&auth)
      session[:mbeditor_authed_at] = Time.now.to_i if ttl > 0 && !performed?
    end

    def ensure_allowed_environment!
      allowed = Array(Mbeditor.configuration.allowed_environments).map(&:to_sym)
      render plain: 'Not found', status: :not_found unless allowed.include?(Rails.env.to_sym)
    end

    def workspace_root
      WorkspaceRootResolver.call
    end

    # Expand path and confirm it's inside workspace_root.
    #
    # Containment is judged lexically, on the path as spelled. File.expand_path
    # collapses "..", so no request can name anything outside the workspace, and
    # an absolute path is rejected outright.
    #
    # Symlinks are followed, the way a file manager does: an app that links a
    # shared config directory or a sibling engine into its tree gets those files
    # opening like any other. The link itself has to already exist inside the
    # workspace, which means a developer put it there — the sandbox is about
    # what a request may *name*, not about second-guessing the checkout.
    def resolve_path(raw)
      return nil if raw.blank?

      root = workspace_root.to_s
      full = File.expand_path(raw.to_s, root)
      return nil unless full.start_with?("#{root}/") || full == root

      full
    rescue Errno::EACCES, ArgumentError
      # ArgumentError: File.expand_path rejects a null byte in the path. Every
      # caller already treats nil as "refuse this path", so a rejected path
      # becomes a clean 4xx instead of escaping as a 500 — and in a batch
      # operation like #import it stays scoped to the one bad entry.
      nil
    end

    def relative_path(full)
      root = workspace_root.to_s
      return "" if full == root

      full.delete_prefix(root + "/")
    end
  end
end
