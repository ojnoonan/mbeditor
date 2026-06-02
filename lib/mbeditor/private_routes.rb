# frozen_string_literal: true

module Mbeditor
  # The private, isolated route set mbeditor dispatches to when the host route
  # table is broken.
  #
  # It is built from Mbeditor::ROUTE_MAP — the same source the engine's own
  # route set draws from — so the two can never drift apart. Crucially, this set
  # is created with ActionDispatch::Routing::RouteSet.new and is *never*
  # registered with the host RoutesReloader. The reloader's clear! wipes every
  # route set it knows about when a host route draw raises; because this set is
  # unknown to it, it survives the wipe and keeps mbeditor reachable.
  #
  # ROUTE_MAP declares controllers without a namespace (e.g. "editors#index").
  # The engine resolves those under "mbeditor/" via isolate_namespace; a plain
  # RouteSet does not, so we reproduce the namespacing with scope module:.
  module PrivateRoutes
    @mutex = Mutex.new

    class << self
      def route_set
        @mutex.synchronize { @route_set ||= build }
      end

      private

      def build
        set = ActionDispatch::Routing::RouteSet.new
        set.draw do
          scope module: 'mbeditor' do
            instance_exec(&Mbeditor::ROUTE_MAP)
          end
        end
        set
      end
    end
  end
end
