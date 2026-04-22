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
        __getobj__.tagged(*tags) { block.call }
      else
        block.call
      end
    end
  end
end
