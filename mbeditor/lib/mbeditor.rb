require "mbeditor/version"
require "mbeditor/configuration"
require "mbeditor/engine"

module Mbeditor
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end
  end
end

MBEditor = Mbeditor unless defined?(MBEditor)
