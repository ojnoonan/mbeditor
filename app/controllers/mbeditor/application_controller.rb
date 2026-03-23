module Mbeditor
  class ApplicationController < ActionController::Base
    private

    def ensure_allowed_environment!
      allowed = Array(Mbeditor.configuration.allowed_environments).map(&:to_sym)
      render plain: 'Not found', status: :not_found unless allowed.include?(Rails.env.to_sym)
    end
  end
end
