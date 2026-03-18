# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'sprockets/railtie'

require 'mbeditor'

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.secret_key_base = 'test-secret-for-dummy-app'
  end
end
