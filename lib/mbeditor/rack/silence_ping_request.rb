# frozen_string_literal: true

require "active_support/logger_silence"

module Mbeditor
  module Rack
    # Silence periodic editor heartbeats so development logs stay readable.
    class SilencePingRequest
      def initialize(app)
        @app = app
      end

      def call(env)
        if ping_request?(env)
          Rails.logger.silence { @app.call(env) }
        else
          @app.call(env)
        end
      end

      private

      def ping_request?(env)
        env["REQUEST_METHOD"] == "GET" &&
          env["HTTP_X_MBEDITOR_CLIENT"] == "1" &&
          env["PATH_INFO"].to_s.end_with?("/ping")
      end
    end
  end
end
