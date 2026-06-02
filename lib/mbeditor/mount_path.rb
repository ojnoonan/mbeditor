# frozen_string_literal: true

module Mbeditor
  # Resolves the active URL prefix mbeditor serves from.
  #
  # At break-time the host route table is wiped, so it is the wrong place to
  # ask "where am I mounted?". MountPath answers from a resolution chain that
  # never touches the route table directly:
  #
  #   1. explicit Mbeditor.configuration.mount_path (override)
  #   2. the cached detected value (populated from a healthy route load)
  #   3. the "/mbeditor" default
  #
  # The cache is guarded by a mutex because it is read at break-time from
  # whatever request thread happens to be serving mbeditor.
  module MountPath
    DEFAULT = '/mbeditor'

    @mutex = Mutex.new
    @cached = nil

    class << self
      def resolve
        Mbeditor.configuration.mount_path || cached || DEFAULT
      end

      # Scans a route set for the route that mounts Mbeditor::Engine and returns
      # its path-spec prefix (e.g. "/mbeditor"), or nil if the engine is not
      # mounted in this set. A mounted engine's route.app is a Constraints
      # wrapper whose #app is the engine; an unmounted route's app is something
      # else, so an unwrap-once-then-compare is enough.
      def detect(route_set)
        route_set.routes.each do |route|
          app = route.app
          target = app.respond_to?(:app) ? app.app : app
          return route.path.spec.to_s if target == Mbeditor::Engine
        end
        nil
      end

      # Re-detects from a route set and caches the result. Called from the
      # engine's after_routes_loaded hook, which fires only on a *healthy* route
      # load — never at break-time, when the table is wiped. A nil detection is
      # left as a no-op so a stray refresh from an engine-less set can never
      # clobber a good prefix cached from an earlier healthy load.
      def refresh!(route_set)
        detected = detect(route_set)
        self.cached = detected if detected
      end

      # The cached detected prefix, or nil if nothing has been detected yet.
      def cached
        @mutex.synchronize { @cached }
      end

      # Stores the detected prefix. Passing nil clears the cache.
      def cached=(value)
        @mutex.synchronize { @cached = value }
      end
    end
  end
end
