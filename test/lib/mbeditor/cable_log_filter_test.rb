# frozen_string_literal: true

require 'test_helper'
require 'logger'

module Mbeditor
  class CableLogFilterTest < ActiveSupport::TestCase
    class PlainLogger
      attr_reader :messages

      def initialize
        @messages = []
      end

      def info(message = nil)
        @messages << message.to_s
      end
    end

    test 'suppresses mbeditor channel messages' do
      logger = PlainLogger.new
      filter = CableLogFilter.new(logger)

      filter.info('Started Mbeditor::EditorChannel stream')
      filter.info('regular message')

      assert_equal ['regular message'], logger.messages
    end

    test 'suppresses cable websocket lifecycle request log lines' do
      logger = PlainLogger.new
      filter = CableLogFilter.new(logger)

      filter.info('Finished "/cable" [WebSocket] for 127.0.0.1 at 2026-04-23 10:41:34 +1000')
      filter.info('Started "/cable" [WebSocket] for 127.0.0.1 at 2026-04-23 10:41:34 +1000')
      filter.info('normal action cable message')

      assert_equal ['normal action cable message'], logger.messages
    end

    test 'current_tags returns empty array when underlying logger is untagged' do
      logger = PlainLogger.new
      filter = CableLogFilter.new(logger)

      assert_equal [], filter.current_tags
      assert_equal [], filter.formatter.current_tags
      assert_nothing_raised { filter.push_tags('a') }
      assert_nothing_raised { filter.pop_tags }
      assert_nothing_raised { filter.clear_tags! }
    end

    test 'formatter remains tagged-logging compatible when underlying formatter is nil' do
      logger = Logger.new($stdout)
      logger.formatter = nil
      filter = CableLogFilter.new(logger)

      assert_equal [], filter.formatter.current_tags
      assert_same filter, filter.tagged('request-123')
    end

    test 'tagged without block returns self when logger has no tagged support' do
      logger = PlainLogger.new
      filter = CableLogFilter.new(logger)

      assert_same filter, filter.tagged('request-123')
    end

    test 'tagged with block executes block when logger has no tagged support' do
      logger = PlainLogger.new
      filter = CableLogFilter.new(logger)

      called = false
      filter.tagged('request-123') { called = true }

      assert_equal true, called
    end
  end
end
