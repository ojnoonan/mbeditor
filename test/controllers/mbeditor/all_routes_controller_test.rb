# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class AllRoutesControllerTest < ActionDispatch::IntegrationTest
    setup do
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = Rails.root.to_s
        c.authenticate_with    = nil
      end
    end

    test "GET /all_routes returns the host app's routes" do
      get "/mbeditor/all_routes"
      assert_response :success
      routes = JSON.parse(response.body)["routes"]
      show = routes.find { |r| r["controller"] == "orders" && r["action"] == "show" }
      assert_equal "app/controllers/orders_controller.rb", show["file"]
      assert_equal 11, show["line"]
    end
  end
end
