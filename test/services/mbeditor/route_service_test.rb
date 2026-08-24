# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RouteServiceTest < ActiveSupport::TestCase
    test "derives the controller key from a file path" do
      assert_equal "orders", RouteService.controller_key("app/controllers/orders_controller.rb")
    end

    test "derives a namespaced controller key" do
      assert_equal "admin/users", RouteService.controller_key("app/controllers/admin/users_controller.rb")
    end

    test "tolerates a leading slash" do
      assert_equal "orders", RouteService.controller_key("/app/controllers/orders_controller.rb")
    end

    test "returns nil for anything that is not a controller" do
      assert_nil RouteService.controller_key("app/models/order.rb")
      assert_nil RouteService.controller_key("app/controllers/concerns/authable.rb")
      assert_nil RouteService.controller_key("")
    end

    test "maps each action to the routes that reach it" do
      actions = RouteService.for_controller("orders")

      assert_equal %w[GET], actions["index"].map { |r| r[:verb] }
      assert_equal ["/orders"], actions["index"].map { |r| r[:path] }
      assert_equal ["/orders/:id"], actions["show"].map { |r| r[:path] }
    end

    test "includes member and collection routes" do
      actions = RouteService.for_controller("orders")

      assert_equal ["/orders/:id/cancel"], actions["cancel"].map { |r| r[:path] }
      assert_equal ["/orders/search"],     actions["search"].map { |r| r[:path] }
    end

    test "an action with no route is simply absent" do
      refute RouteService.for_controller("orders").key?("unreachable")
    end

    test "resolves a namespaced controller" do
      actions = RouteService.for_controller("admin/users")

      assert_equal ["/admin/users"], actions["index"].map { |r| r[:path] }
      assert actions.key?("show")
    end

    test "the format suffix is stripped so a hint fits on one line" do
      RouteService.for_controller("orders").each_value do |routes|
        routes.each { |r| refute_includes r[:path], "(.:format)" }
      end
    end

    test "carries the route name when there is one" do
      assert_equal "orders", RouteService.for_controller("orders")["index"].first[:name]
    end

    test "an unknown controller yields no actions rather than raising" do
      assert_empty RouteService.for_controller("nope/not/here")
    end

    test "a nil or blank key yields no actions" do
      assert_empty RouteService.for_controller(nil)
      assert_empty RouteService.for_controller("")
    end

    # The cache exists because the inline route hints re-request on every
    # activation of a controller tab, and each miss walks the host app's whole
    # route set. A cache that never invalidates would be worse than none: it
    # would answer a routes.rb edit with the pre-edit routes, forever.
    # A rebuild constructs a fresh Hash, so identity is what separates a cache
    # hit from a re-scan — equality alone cannot tell them apart here.
    test "a repeat lookup is served without walking the route set again" do
      RouteService.invalidate
      first = RouteService.for_controller("orders")

      assert_same first, RouteService.for_controller("orders")
    end

    test "invalidate forces the next lookup to rebuild" do
      first = RouteService.for_controller("orders")
      RouteService.invalidate
      rebuilt = RouteService.for_controller("orders")

      refute_same first, rebuilt, "expected a fresh scan after invalidate"
      assert_equal first, rebuilt, "the rebuilt payload should still be correct"
      assert rebuilt.key?("index")
    end

    test "each controller key is cached separately" do
      RouteService.invalidate
      orders = RouteService.for_controller("orders")
      admin  = RouteService.for_controller("admin/users")

      refute_equal orders, admin
      assert_equal orders, RouteService.for_controller("orders")
      assert_equal admin, RouteService.for_controller("admin/users")
    end
  end
end
