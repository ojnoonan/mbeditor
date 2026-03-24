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
        if root_request?(env)
          @app.call(env)
        elsif mbeditor_request?(env)
          Rails.logger.silence { @app.call(env) }
        else
          @app.call(env)
        end
      end

      private

      def mbeditor_request?(env)
        normalized_request_path(env).start_with?("/mbeditor/")
      end

      def root_request?(env)
        env["REQUEST_METHOD"] == "GET" && normalized_request_path(env) == "/mbeditor"
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
