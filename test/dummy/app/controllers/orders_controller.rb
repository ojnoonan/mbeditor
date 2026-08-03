# frozen_string_literal: true

# Demonstrates the inline route hints: each action below is annotated in the
# editor with the verb and path that reach it, and `unreachable` is flagged as
# having no route at all.
class OrdersController < ApplicationController
  def index
    render plain: "orders"
  end

  def show
    render plain: "order #{params[:id]}"
  end

  def create
    head :created
  end

  def cancel
    head :ok
  end

  def search
    render plain: "search"
  end

  # No route points here — the hint says so.
  def unreachable
    head :ok
  end

  private

  def order_params
    params.permit(:number)
  end
end
