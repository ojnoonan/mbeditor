# frozen_string_literal: true

require "test_helper"

module Mbeditor
  module Rack
    class ResilientRouterTest < ActiveSupport::TestCase
      setup do
        Mbeditor.configuration.mount_path = nil
        Mbeditor::MountPath.cached = nil
      end

      teardown do
        Mbeditor.configuration.mount_path = nil
        Mbeditor::MountPath.cached = nil
      end

      # A host app stand-in that records the env it was called with, so we can
      # assert whether a request reached the host stack or was intercepted.
      def recording_app(status: 200, body: ["host"])
        seen = []
        app = lambda do |env|
          seen << env
          [status, {}, body]
        end
        [app, seen]
      end

      # Temporarily swap Mbeditor::PrivateRoutes.route_set for a recording fake,
      # isolating the middleware's routing decision and env rewrite from the real
      # route dispatch (which the integration test exercises end-to-end).
      def with_private_set(fake)
        original = Mbeditor::PrivateRoutes.method(:route_set)
        Mbeditor::PrivateRoutes.define_singleton_method(:route_set) { fake }
        yield
      ensure
        Mbeditor::PrivateRoutes.singleton_class.send(:remove_method, :route_set)
        Mbeditor::PrivateRoutes.define_singleton_method(:route_set, original)
      end

      # A fake route set that records each env it is dispatched with.
      def recording_route_set
        seen = []
        set = lambda do |env|
          seen << env
          [200, {}, ["private"]]
        end
        [set, seen]
      end

      # The middleware only intercepts when the host route table is broken. Most
      # tests here isolate the routing-decision/env-rewrite for that broken case,
      # so force the broken predicate; a dedicated test below covers the healthy
      # pass-through path.
      def broken_router(host)
        router = Mbeditor::Rack::ResilientRouter.new(host)
        router.define_singleton_method(:host_routes_broken?) { true }
        router
      end

      test "dispatches a prefix-matching request to the private route set with rewritten path" do
        host, host_seen = recording_app
        private_set, private_seen = recording_route_set

        status, _headers, body = with_private_set(private_set) do
          broken_router(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor/ping"
          )
        end

        assert_equal 200, status
        assert_equal ["private"], body, "should be served by the private set, not the host app"
        assert_empty host_seen, "request must not reach the host app"
        assert_equal "/mbeditor", private_seen.last["SCRIPT_NAME"]
        assert_equal "/ping", private_seen.last["PATH_INFO"]
      end

      test "passes a non-matching request through to the host app untouched" do
        host, host_seen = recording_app(status: 201, body: ["host-served"])
        private_set, private_seen = recording_route_set

        status, _headers, body = with_private_set(private_set) do
          Mbeditor::Rack::ResilientRouter.new(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/articles"
          )
        end

        assert_equal 201, status
        assert_equal ["host-served"], body
        assert_empty private_seen, "private set must not see non-matching requests"
        assert_equal 1, host_seen.size
        assert_equal "/articles", host_seen.last["PATH_INFO"], "host env must be untouched"
        assert_equal "", host_seen.last["SCRIPT_NAME"]
      end

      test "does not treat a path that merely starts with the prefix string as a match" do
        host, host_seen = recording_app
        private_set, private_seen = recording_route_set

        with_private_set(private_set) do
          Mbeditor::Rack::ResilientRouter.new(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditorzzz/ping"
          )
        end

        assert_empty private_seen, "/mbeditorzzz is a different app, not under the mount prefix"
        assert_equal 1, host_seen.size
      end

      test "passes a prefix-matching request through to the host when the host routes are healthy" do
        host, host_seen = recording_app(status: 200, body: ["host-served"])
        private_set, private_seen = recording_route_set

        # A real router (no forced predicate); in the booted test app the engine
        # route table is populated, so host_routes_broken? is false.
        status, _headers, body = with_private_set(private_set) do
          Mbeditor::Rack::ResilientRouter.new(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor/ping"
          )
        end

        assert_equal 200, status
        assert_equal ["host-served"], body, "healthy requests must reach the normal host mount"
        assert_empty private_seen, "the private set must not see healthy requests"
        assert_equal 1, host_seen.size
        assert_equal "/mbeditor/ping", host_seen.last["PATH_INFO"], "host env must be untouched"
        assert_equal "", host_seen.last["SCRIPT_NAME"]
      end

      test "rewrites the bare mount prefix to the root path so the root route matches" do
        host, = recording_app
        private_set, private_seen = recording_route_set

        with_private_set(private_set) do
          broken_router(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor"
          )
        end

        assert_equal "/mbeditor", private_seen.last["SCRIPT_NAME"]
        assert_equal "/", private_seen.last["PATH_INFO"]
      end

      test "honors a custom mount prefix resolved from MountPath" do
        Mbeditor.configuration.mount_path = "/admin/editor"
        host, host_seen = recording_app
        private_set, private_seen = recording_route_set

        with_private_set(private_set) do
          broken_router(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/admin/editor/ping"
          )
          # The default prefix is no longer the mount point.
          broken_router(host).call(
            "REQUEST_METHOD" => "GET",
            "SCRIPT_NAME" => "",
            "PATH_INFO" => "/mbeditor/ping"
          )
        end

        assert_equal "/admin/editor", private_seen.last["SCRIPT_NAME"]
        assert_equal "/ping", private_seen.last["PATH_INFO"]
        assert_equal 1, private_seen.size, "only the custom-prefix request should be intercepted"
        assert_equal 1, host_seen.size, "/mbeditor/ping is no longer the mount point and passes through"
      end
    end
  end
end
