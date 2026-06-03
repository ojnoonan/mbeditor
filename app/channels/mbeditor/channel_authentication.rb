# frozen_string_literal: true

require "action_dispatch"

module Mbeditor
  # Runs the configured `authenticate_with` hook on the WebSocket handshake (at
  # channel subscribe) and rejects the subscription when it denies. This is the
  # same proc the engine runs as a controller `before_action`; on the cable side
  # there is no controller, so it is evaluated against a probe that mirrors the
  # surface the hook relies on (`session`, `cookies`, `redirect_to`/`render`/
  # `head`). A hook that halts — or raises — denies the socket (fail-closed).
  #
  # The probe reads cookies/session from the upgrade request env when available;
  # because the cable mount can bypass host middleware, hooks that depend on
  # request-scoped state may see less than they do over HTTP. Restricting network
  # exposure (trusted tunnel / LAN) and securing the host's ActionCable connection
  # remain the primary controls — see the README pairing section.
  module ChannelAuthentication
    # True when the connection is allowed (or no hook is configured); otherwise
    # rejects the subscription and returns false.
    def mbeditor_authenticated?
      hook = Mbeditor.configuration.authenticate_with
      return true unless hook

      probe = AuthProbe.new(mbeditor_connection_env)
      probe.instance_exec(&hook)
      return true unless probe.denied?

      mbeditor_reject_subscription
      false
    rescue StandardError
      mbeditor_reject_subscription
      false
    end

    private

    def mbeditor_connection_env
      connection.env
    rescue StandardError
      {}
    end

    def mbeditor_reject_subscription
      reject if respond_to?(:reject, true)
    end

    # Minimal controller-like context for evaluating `authenticate_with` off the
    # cable connection. Any render/redirect/head marks the request as denied,
    # mirroring a controller's `performed?` halt semantics.
    class AuthProbe
      def initialize(env)
        @request = ActionDispatch::Request.new(env || {})
        @denied = false
      end

      def session
        @request.session
      end

      def cookies
        @request.cookie_jar
      end

      def request
        @request
      end

      def params
        @request.params
      end

      def redirect_to(*, **)
        @denied = true
      end

      def render(*, **)
        @denied = true
      end

      def head(*, **)
        @denied = true
      end

      def performed?
        @denied
      end

      def denied?
        @denied
      end
    end
  end
end
