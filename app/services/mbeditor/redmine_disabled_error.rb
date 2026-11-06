# frozen_string_literal: true

module Mbeditor
  # Raised by RedmineService when the integration is switched off.
  class RedmineDisabledError < StandardError
    def initialize
      super("Redmine integration is not enabled. Set config.mbeditor.redmine_enabled = true.")
    end
  end
end
