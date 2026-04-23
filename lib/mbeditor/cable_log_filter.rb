# frozen_string_literal: true

require 'delegate'
require 'logger'

module Mbeditor
  # Wraps the ActionCable logger and suppresses all log lines that mention
  # Mbeditor channels so the development console stays readable.
  # Non-Mbeditor ActionCable messages pass through unchanged.
  class CableLogFilter < SimpleDelegator
    SUPPRESS_PATTERN = /Mbeditor::|mbeditor_editor/

    # Provides no-op tagged logging APIs for plain Ruby formatters.
    class UntaggedFormatter < SimpleDelegator
      def tagged(*_tags)
        return yield self if block_given?

        self
      end

      def current_tags
        []
      end

      def push_tags(*tags)
        tags
      end

      def pop_tags(_count = 1)
        []
      end

      def clear_tags!
        nil
      end
    end

    def formatter
      underlying_formatter = resolve_formatter

      return underlying_formatter if underlying_formatter.respond_to?(:current_tags)

      if defined?(@untagged_formatter_source) && @untagged_formatter_source.equal?(underlying_formatter)
        return @untagged_formatter
      end

      @untagged_formatter_source = underlying_formatter
      @untagged_formatter = UntaggedFormatter.new(underlying_formatter)
    end

    def resolve_formatter
      return Logger::Formatter.new unless __getobj__.respond_to?(:formatter)

      __getobj__.formatter || Logger::Formatter.new
    end

    %w[debug info warn error fatal unknown].each do |level|
      define_method(level) do |message = nil, &block|
        msg = message.nil? && block ? block.call : message.to_s
        return if msg.match?(SUPPRESS_PATTERN)

        super(message, &block)
      end
    end

    # Tagged-logging compat — the block body still passes through the filter.
    def tagged(*tags, &block)
      if __getobj__.respond_to?(:tagged)
        tagged_logger = __getobj__.tagged(*tags, &block)
        block ? tagged_logger : self.class.new(tagged_logger)
      elsif block
        block.call
      else
        self
      end
    end

    # Rails/ActiveSupport logger compatibility. Some logger stacks call these
    # methods even when the underlying logger is not TaggedLogging.
    def current_tags
      return __getobj__.current_tags if __getobj__.respond_to?(:current_tags)

      []
    end

    def push_tags(*tags)
      return __getobj__.push_tags(*tags) if __getobj__.respond_to?(:push_tags)

      tags
    end

    def pop_tags(count = 1)
      return __getobj__.pop_tags(count) if __getobj__.respond_to?(:pop_tags)

      []
    end

    def clear_tags!
      return __getobj__.clear_tags! if __getobj__.respond_to?(:clear_tags!)

      nil
    end

    def flush
      clear_tags!
      __getobj__.flush if __getobj__.respond_to?(:flush)
    end
  end
end
