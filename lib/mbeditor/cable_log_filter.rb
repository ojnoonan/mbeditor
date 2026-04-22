# frozen_string_literal: true

module Mbeditor
  # Wraps the ActionCable logger and suppresses all log lines that mention
  # Mbeditor channels so the development console stays readable.
  # Non-Mbeditor ActionCable messages pass through unchanged.
  class CableLogFilter < SimpleDelegator
    SUPPRESS_PATTERN = /Mbeditor::|mbeditor_editor/

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
        __getobj__.tagged(*tags, &block)
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
  end
end
