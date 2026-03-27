# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    session[:authenticated] = true
    head :ok
  end

  def destroy
    session.delete(:authenticated)
    head :ok
  end
end
