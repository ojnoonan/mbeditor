# frozen_string_literal: true

require "mbeditor/rack/silence_ping_request"
require "mbeditor/rack/handle_pending_migrations"
require "mbeditor/rack/resilient_router"
require "mbeditor/cable_log_filter"

module Mbeditor
  class Engine < ::Rails::Engine
    isolate_namespace Mbeditor

    initializer "mbeditor.silence_ping_request" do |app|
      app.middleware.insert_before Rails::Rack::Logger, Mbeditor::Rack::SilencePingRequest
    end

    initializer "mbeditor.resilient_routing" do |app|
      # Serve mbeditor's own traffic from middleware that dispatches to a
      # private, isolated route set, so the editor survives a broken host
      # config/routes.rb. Disabling the flag is the escape hatch: no middleware
      # is inserted and the private set is never built.
      next unless Mbeditor.configuration.resilient_routing

      # ActionDispatch::Reloader is only in the stack when reloading is enabled
      # (the same condition Rails uses to add it). Sitting just above it means
      # mbeditor requests are intercepted before any route reload can raise,
      # while staying below DebugExceptions/ShowExceptions (mbeditor's own
      # errors still get Rails error pages) and below Executor (dispatch runs
      # inside app.executor's connection management).
      if app.config.reloading_enabled?
        app.middleware.insert_before ActionDispatch::Reloader, Mbeditor::Rack::ResilientRouter
      end

      # Build the private set at boot so it is ready before the first request
      # and before the host route table can ever break.
      Mbeditor::PrivateRoutes.route_set

      # Auto-detect the mount prefix from each *healthy* route load and cache it,
      # so resilient routing works at a custom mount with zero configuration.
      # after_routes_loaded fires only after a successful load — a raising
      # routes.rb skips it — so the cache is never populated from the wiped
      # break-time table. MountPath.refresh! is a no-op when the engine isn't
      # found, so a stray load can never clobber a prefix from an earlier
      # healthy one.
      #
      # The hook's yielded receiver is NOT reliably Rails.application — the
      # reloader's to_run path fires it with the reloader callback context as
      # self — so read the live route set through Rails.application directly.
      app.config.after_routes_loaded do
        Mbeditor::MountPath.refresh!(Rails.application.routes)
      end
    end

    initializer "mbeditor.handle_pending_migrations" do |app|
      # Insert before CheckPending so our middleware wraps it and can rescue
      # the error it raises. Falls back silently if CheckPending is absent
      # (e.g. host app does not use ActiveRecord).
      # Note: app.middleware is a MiddlewareStackProxy during initializers and
      # does not support .to_a — rely solely on defined? to detect ActiveRecord.
      if defined?(ActiveRecord::Migration::CheckPending)
        app.middleware.insert_before ActiveRecord::Migration::CheckPending,
                                     Mbeditor::Rack::HandlePendingMigrations
      end
    end

    config.after_initialize do
      # Silence ActionCable framework logs for Mbeditor channels (subscription
      # confirmations, streaming notices, action invocations, disconnect messages).
      # We wrap the existing ActionCable logger in a filter proxy rather than
      # replacing it, so the host app's non-Mbeditor channel logs are unaffected.
      if defined?(ActionCable)
        original_logger = ActionCable.server.config.logger || Rails.logger
        ActionCable.server.config.logger = Mbeditor::CableLogFilter.new(original_logger)
      end

      Mbeditor::RubyDefinitionService.cache_path =
        Rails.root.join("tmp", "mbeditor_ruby_defs.json").to_s

      cfg = Mbeditor.configuration

      if cfg.workspace_root.present? && !File.directory?(cfg.workspace_root.to_s)
        raise ArgumentError, "[mbeditor] config.workspace_root is set to '#{cfg.workspace_root}' but that path is not a directory"
      end

      if cfg.redmine_enabled
        require "uri"
        if cfg.redmine_url.blank?
          Rails.logger.warn("[mbeditor] redmine_enabled is true but redmine_url is not configured")
        else
          begin
            uri = URI.parse(cfg.redmine_url.to_s)
            unless %w[http https].include?(uri.scheme)
              Rails.logger.warn("[mbeditor] redmine_url must use http or https scheme")
            end
          rescue URI::InvalidURIError
            Rails.logger.warn("[mbeditor] redmine_url is not a valid URI")
          end
        end
        if cfg.redmine_api_key.blank?
          Rails.logger.warn("[mbeditor] redmine_enabled is true but redmine_api_key is not configured")
        end
      end
    end

    initializer "mbeditor.assets.precompile" do |app|
      app.config.assets.precompile += %w[
        mbeditor/application.css
        mbeditor/application.js
        fontawesome.min.css
        react.min.js
        react-dom.min.js
        axios.min.js
        lodash.min.js
        minisearch.min.js
        marked.min.js
        prettier-standalone.js
        prettier-plugin-babel.js
        prettier-plugin-estree.js
        prettier-plugin-html.js
        prettier-plugin-postcss.js
        prettier-plugin-markdown.js
        monaco-vim.js
        emmet.js
        monaco-themes-bundle.js
        fa-brands-400.woff2
        fa-regular-400.woff2
        fa-solid-900.woff2
      ]
    end
  end
end
