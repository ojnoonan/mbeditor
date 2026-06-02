# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class MountPathTest < ActiveSupport::TestCase
    setup do
      Mbeditor.configuration.mount_path = nil
      Mbeditor::MountPath.cached = nil
    end

    teardown do
      Mbeditor.configuration.mount_path = nil
      Mbeditor::MountPath.cached = nil
    end

    test 'resolve falls back to /mbeditor when nothing is configured or cached' do
      assert_equal '/mbeditor', Mbeditor::MountPath.resolve
    end

    test 'resolve returns the configured mount_path when set' do
      Mbeditor.configuration.mount_path = '/admin/editor'

      assert_equal '/admin/editor', Mbeditor::MountPath.resolve
    end

    test 'resolve returns the cached value when mount_path is unset' do
      Mbeditor::MountPath.cached = '/detected/prefix'

      assert_equal '/detected/prefix', Mbeditor::MountPath.resolve
    end

    test 'the configured mount_path wins over a cached value' do
      Mbeditor::MountPath.cached = '/detected/prefix'
      Mbeditor.configuration.mount_path = '/admin/editor'

      assert_equal '/admin/editor', Mbeditor::MountPath.resolve
    end

    test 'detect returns the prefix of the route whose app is the engine' do
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { mount Mbeditor::Engine => '/admin/tools' }

      assert_equal '/admin/tools', Mbeditor::MountPath.detect(route_set)
    end

    test 'detect returns nil when the engine is not mounted in the route set' do
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { get 'something', to: proc { [200, {}, []] } }

      assert_nil Mbeditor::MountPath.detect(route_set)
    end

    test 'refresh! caches the detected prefix from a healthy route set' do
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { mount Mbeditor::Engine => '/admin/tools' }

      Mbeditor::MountPath.refresh!(route_set)

      assert_equal '/admin/tools', Mbeditor::MountPath.cached
    end

    test 'refresh! leaves an existing cached prefix intact when the engine is absent' do
      Mbeditor::MountPath.cached = '/admin/tools'
      engineless = ActionDispatch::Routing::RouteSet.new
      engineless.draw { get 'something', to: proc { [200, {}, []] } }

      Mbeditor::MountPath.refresh!(engineless)

      assert_equal '/admin/tools', Mbeditor::MountPath.cached
    end

    test 'concurrent readers and writers never raise and never observe a torn value' do
      prefixes = (1..20).map { |i| "/p#{i}" }
      observed = Queue.new

      writers = prefixes.map do |prefix|
        Thread.new { 200.times { Mbeditor::MountPath.cached = prefix } }
      end
      readers = Array.new(8) do
        Thread.new { 200.times { observed << Mbeditor::MountPath.resolve } }
      end

      (writers + readers).each(&:join)

      seen = []
      seen << observed.pop until observed.empty?
      assert_empty seen - (prefixes + ['/mbeditor']),
                   'resolve returned a value that was never a valid cache state'
    end
  end
end
