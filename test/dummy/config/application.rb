# frozen_string_literal: true

require_relative 'boot'

require 'rails'
# ActiveRecord only when a database adapter is actually installed. sqlite3 is
# gated on Ruby >= 3.2 in the Gemfile (its native extension does not build on
# the older CI legs), and without an adapter Rails cannot connect at all. The
# app runs happily without it — which is worth exercising anyway, since plenty
# of host apps have no ActiveRecord and the model graph has to say so.
begin
  require 'sqlite3'
  require 'active_record/railtie'
rescue LoadError
  # No adapter on this leg; carry on without ActiveRecord.
end
require 'action_controller/railtie'
require 'action_view/railtie'
require 'action_cable/engine'
require 'sprockets/railtie'

require 'mbeditor'

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.secret_key_base = 'test-secret-for-dummy-app'
    config.action_cable.cable = { 'adapter' => 'async' }
  end
end
