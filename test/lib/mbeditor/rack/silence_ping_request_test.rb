# frozen_string_literal: true

require "test_helper"

module Mbeditor
  module Rack
    class SilencePingRequestTest < ActiveSupport::TestCase
      FakeLogger = Struct.new(:silenced) do
        def silence
          self.silenced = true
          yield
        end
      end

      def build_middleware
        Mbeditor::Rack::SilencePingRequest.new(->(_env) { [200, {}, ["ok"]] })
      end

      test "keeps the engine root GET visible" do
        logger = FakeLogger.new(false)

        Rails.stub(:logger, logger) do
          status, _headers, body = build_middleware.call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor"
          )

          assert_equal 200, status
          assert_equal ["ok"], body
          assert_equal false, logger.silenced
        end
      end

      test "silences editor asset requests" do
        logger = FakeLogger.new(false)

        Rails.stub(:logger, logger) do
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
      end

      test "silences editor state requests" do
        logger = FakeLogger.new(false)

        Rails.stub(:logger, logger) do
          status, _headers, body = build_middleware.call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor/state"
          )

          assert_equal 200, status
          assert_equal ["ok"], body
          assert_equal true, logger.silenced
        end
      end

      test "does not silence unrelated direct asset requests" do
        logger = FakeLogger.new(false)

        Rails.stub(:logger, logger) do
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
end