# frozen_string_literal: true

require "mbeditor/version"
require "mbeditor/configuration"
require "mbeditor/mount_path"
require "mbeditor/route_map"
require "mbeditor/private_routes"
require "mbeditor/editor_bootstrap"
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
