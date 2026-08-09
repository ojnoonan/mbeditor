# frozen_string_literal: true

require "test_helper"

module Mbeditor
  module Rack
    class SilencePingRequestTest < ActiveSupport::TestCase
      FakeLogger = Struct.new(:silenced, :silence_level) do
        def silence(severity = ::Logger::ERROR)
          self.silenced = true
          self.silence_level = severity
          yield
        end
      end

      setup do
        @original_logger = Rails.logger
      end

      teardown do
        Rails.logger = @original_logger
      end

      def build_middleware
        Mbeditor::Rack::SilencePingRequest.new(->(_env) { [200, {}, ["ok"]] })
      end

      test "keeps the engine root GET visible" do
        logger = FakeLogger.new(false)
        Rails.logger = logger

        status, _headers, body = build_middleware.call(
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => "/mbeditor"
        )

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal false, logger.silenced
      end

      # Silencing at the default ERROR swallowed anything a host app logged from
      # inside authenticate_with or user_name_callback, since those procs run
      # within the request — so a developer debugging their own hook saw nothing
      # and had no way to know why. WARN still hides Rails' own INFO-level
      # "Started"/"Completed" lines, which is all this is meant to do.
      test "silences to WARN so host-app warnings from hooks still appear" do
        logger = FakeLogger.new(false, nil)
        Rails.logger = logger
        app = ->(_env) { [200, {}, ["ok"]] }
        middleware = SilencePingRequest.new(app)

        middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/mbeditor/client_config")

        assert_equal true, logger.silenced
        assert_equal ::Logger::WARN, logger.silence_level
      end

      test "silences editor asset requests" do
        logger = FakeLogger.new(false)
        Rails.logger = logger

        status, _headers, body = build_middleware.call(
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => "/assets/react.min.js",
          "HTTP_REFERER" => "http://example.test/mbeditor"
        )

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal true, logger.silenced
      end

      test "silences editor state requests" do
        logger = FakeLogger.new(false)
        Rails.logger = logger

        status, _headers, body = build_middleware.call(
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => "/mbeditor/state"
        )

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal true, logger.silenced
      end

      test "silences /assets/mbeditor/ requests unconditionally" do
        logger = FakeLogger.new(false)
        Rails.logger = logger

        status, _headers, body = build_middleware.call(
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => "/assets/mbeditor/application-abc123.css"
        )

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal true, logger.silenced
      end

      test "does not silence unrelated direct asset requests" do
        logger = FakeLogger.new(false)
        Rails.logger = logger

        status, _headers, body = build_middleware.call(
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => "/assets/react.min.js"
        )

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal false, logger.silenced
      end
    end
  end
end