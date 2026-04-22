# frozen_string_literal: true

require "active_support/logger_silence"
require "uri"

module Mbeditor
  module Rack
    # Silence editor traffic so development logs stay readable, while leaving
    # the initial GET to the engine root visible as a signal that a developer
    # opened Mbeditor.
    class SilencePingRequest
      def initialize(app)
        @app = app
      end

      def call(env)
        path = normalized_request_path(env)
        if root_request?(env, path)
          @app.call(env)
        elsif mbeditor_request?(path) || cable_request?(path) || editor_asset_request?(env, path)
          Rails.logger.silence { @app.call(env) }
        else
          @app.call(env)
        end
      end

      private

      def mbeditor_request?(path)
        path.start_with?("/mbeditor/")
      end

      def cable_request?(path)
        path == "/cable" || path.start_with?("/cable/")
      end
      # Silence asset pipeline requests that belong to the editor:
      # - /assets/mbeditor/... is always an editor asset (CSS/JS bundle)
      # - other /assets/... requests are silenced only when the browser is
      #   currently on the editor page (Referer contains /mbeditor)
      def editor_asset_request?(env, path)
        return true if path.start_with?("/assets/mbeditor/")
        return false unless path.start_with?("/assets/")

        env["HTTP_REFERER"].to_s.include?("/mbeditor")
      end

      def root_request?(env, path)
        env["REQUEST_METHOD"] == "GET" && path == "/mbeditor"
      end

      def normalized_request_path(env)
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        path = env["PATH_INFO"].to_s if path.empty?
        path = "/" if path.empty?
        path.chomp("/")
      end
    end
  end
end
