# frozen_string_literal: true

module Mbeditor
  module Rack
    # Serves mbeditor's own traffic from a private, isolated route set so the
    # editor stays reachable even when the host config/routes.rb is broken.
    #
    # Sibling of HandlePendingMigrations: both intercept mbeditor requests when
    # the normal path is blocked. This one sits above ActionDispatch::Reloader,
    # so a prefix-matching request is dispatched before any route reload can
    # raise. Requests that don't match the mount prefix pass through untouched.
    #
    # The matched request is rewritten to mirror how Rails mounts an engine:
    # the prefix is stripped from PATH_INFO and moved to SCRIPT_NAME, so the
    # private set sees the un-prefixed path while the rendered base path stays
    # correct. Dispatch still flows through the mbeditor controllers, so
    # verify_mbeditor_client and resolve_path run unchanged.
    #
    # Because this middleware sits above the Reloader — and therefore above the
    # host's Cookies/Session/Flash middleware — a bare dispatch would leave
    # resilient-routed requests without a session, breaking session-based
    # authenticate_with. To keep parity with the normal mount, the private set
    # is wrapped in the host app's own cookies/session/flash middleware. The
    # crypto config (key generator, secret_key_base, serializer) is already in
    # env, merged by Rails::Application#call before the stack runs.
    class ResilientRouter
      def initialize(app)
        @app = app
      end

      def call(env)
        prefix = Mbeditor::MountPath.resolve
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"

        return @app.call(env) unless matches_prefix?(path, prefix)

        # Only hijack the request when the host route table is actually broken
        # (a raising routes.rb wipes every registered route set, including the
        # engine's). On a healthy request, fall through to the normal engine
        # mount so the host stack handles it with the correct SCRIPT_NAME and a
        # working main_app proxy — dispatching healthy traffic through the
        # private set instead makes the host's own url helpers (e.g. an
        # authenticate_with redirect) inherit SCRIPT_NAME="/mbeditor" and
        # wrongly prepend the mount prefix.
        return @app.call(env) unless host_routes_broken?

        remainder = path[prefix.length..] || ""
        remainder = "/" if remainder.empty?
        env["SCRIPT_NAME"] = prefix
        env["PATH_INFO"] = remainder

        dispatch.call(env)
      end

      private

      # True when the engine's own route set has been wiped — the signature of a
      # broken host config/routes.rb, whose failed reload clears every route set
      # the RoutesReloader knows about. When healthy, the engine routes are
      # populated and the request belongs on the normal mount.
      def host_routes_broken?
        Mbeditor::Engine.routes.routes.empty?
      end

      def matches_prefix?(path, prefix)
        path == prefix || path.start_with?("#{prefix}/")
      end

      # The private route set wrapped in the host's session middleware, so a
      # resilient-routed request has the same session support as one that
      # reaches mbeditor through the normal mount. Built lazily and memoized;
      # the middleware instance lives for the process, so a benign double-build
      # under a startup race is harmless.
      def dispatch
        @dispatch ||= build_dispatch
      end

      def build_dispatch
        app = Mbeditor::PrivateRoutes.route_set
        config = Rails.application.config
        store = config.session_store
        # config.session_store is the store class normally, but :disabled (a
        # symbol) when sessions are off — in which case dispatch the bare set.
        return app unless store.is_a?(Class)

        app = ActionDispatch::Flash.new(app)
        app = store.new(app, config.session_options)
        ActionDispatch::Cookies.new(app)
      end
    end
  end
end
