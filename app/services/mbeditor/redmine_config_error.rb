# frozen_string_literal: true

module Mbeditor
  # Raised by RedmineService when the integration is enabled but misconfigured.
  class RedmineConfigError < StandardError; end
end
