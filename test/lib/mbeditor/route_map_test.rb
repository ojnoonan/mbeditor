# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class RouteMapTest < ActiveSupport::TestCase
    test 'a route set drawn from ROUTE_MAP exposes the same paths as the engine route set' do
      shadow = ActionDispatch::Routing::RouteSet.new
      shadow.draw(&Mbeditor::ROUTE_MAP)

      assert_equal path_specs(Mbeditor::Engine.routes), path_specs(shadow)
    end

    private

    def path_specs(route_set)
      route_set.routes.map { |route| route.path.spec.to_s }.sort
    end
  end
end
