# frozen_string_literal: true

# Namespaced, so the controller key is "admin/users" rather than "users".
module Admin
  class UsersController < ApplicationController
    def index
      render plain: "admin users"
    end

    def show
      render plain: "admin user #{params[:id]}"
    end
  end
end
