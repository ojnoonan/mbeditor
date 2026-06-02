# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class PrivateRoutesTest < ActiveSupport::TestCase
    test 'resolves namespaced paths to mbeditor controllers' do
      assert_equal(
        { controller: 'mbeditor/editors', action: 'files' },
        Mbeditor::PrivateRoutes.route_set.recognize_path('/files', method: :get)
      )
    end

    test 'memoizes the route set across calls' do
      assert_same Mbeditor::PrivateRoutes.route_set, Mbeditor::PrivateRoutes.route_set
    end

    test 'is absent from the host RoutesReloader, so its clear! can never wipe it' do
      registered = Rails.application.routes_reloader.route_sets

      refute_includes registered, Mbeditor::PrivateRoutes.route_set
    end

    test 'exposes the same path specs as the engine route set' do
      assert_equal path_specs(Mbeditor::Engine.routes),
                   path_specs(Mbeditor::PrivateRoutes.route_set)
    end

    private

    def path_specs(route_set)
      route_set.routes.map { |route| route.path.spec.to_s }.sort
    end
  end
end
