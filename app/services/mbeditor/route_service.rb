# frozen_string_literal: true

module Mbeditor
  # Which routes reach a controller's actions, for the inline hints shown beside
  # each `def` in a controller file.
  #
  # Read from the host app's own route set rather than by parsing config/routes.rb.
  # mbeditor runs inside the host app, so the routes are already built — and they
  # are the only source that accounts for `resources` expansion, `member`/
  # `collection` blocks, scopes, constraints, mounted engines and anything a
  # routes file does in plain Ruby. Parsing the file would get all of that wrong.
  module RouteService
    module_function

    # "app/controllers/admin/users_controller.rb" -> "admin/users", which is the
    # key Rails stores in a route's defaults.
    def controller_key(relative_path)
      path = relative_path.to_s.sub(%r{\A/+}, "")
      match = path.match(%r{\Aapp/controllers/(.+)_controller\.rb\z})
      return nil unless match

      match[1]
    end

    MUTEX = Mutex.new
    private_constant :MUTEX

    # Matches the other read-through caches in this engine (FileTreeService 15s,
    # GitInfoService 10s). A write invalidates it outright, so the TTL only ever
    # bounds staleness from a route change made outside the editor.
    CACHE_TTL = 10

    # => { "show" => [{ verb:, path:, name: }], ... }
    #
    # Cached because every call walks the host app's ENTIRE route set, and the
    # caller is the inline route hints — which re-request on every activation of
    # a controller tab and on every external content change. Switching between
    # two controllers repeatedly was therefore a full O(routes) scan per switch,
    # and a large app has thousands of routes. The scan itself is unchanged;
    # it just stops happening once per glance.
    def for_controller(key)
      return {} if key.nil? || key.empty?
      return {} unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      cached = cached_routes(key)
      return cached if cached

      # Built outside the mutex: it runs arbitrary host-app route code, and
      # holding the lock across it would serialise every other controller's
      # lookup behind the slowest one.
      computed = routes_for(key)
      store_routes(key, computed)
      computed
    rescue StandardError
      # A broken route set must not take the editor down with it — the file still
      # opens, just without hints.
      {}
    end

    # Controllers that belong to Rails or to this engine, not to the host app.
    INTERNAL_CONTROLLER = %r{\A(?:rails|active_storage|action_mailbox|mbeditor)(?:/|\z)}

    # Every host-app route for the Routes panel:
    # [{ verb:, path:, name:, controller:, action:, file:, line: }].
    # `file` is the workspace-relative controller file when it exists, `line`
    # the line of its `def <action>` (nil when not found).
    def all(workspace_root)
      return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      cache_key = "all:#{workspace_root}"
      cached = cached_routes(cache_key)
      return cached if cached

      computed = build_all(workspace_root.to_s)
      store_routes(cache_key, computed)
      computed
    rescue StandardError
      []
    end

    def invalidate
      MUTEX.synchronize { @cache = {} }
      nil
    end

    def cached_routes(key)
      MUTEX.synchronize do
        entry = (@cache ||= {})[key]
        return entry[:data] if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < CACHE_TTL
      end
      nil
    end
    private_class_method :cached_routes

    def store_routes(key, data)
      MUTEX.synchronize do
        (@cache ||= {})[key] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
      end
    end
    private_class_method :store_routes

    def routes_for(key)
      out = {}
      Rails.application.routes.routes.each do |route|
        defaults = route.defaults
        next unless defaults[:controller] == key

        action = defaults[:action].to_s
        next if action.empty?

        (out[action] ||= []) << {
          verb: verb_for(route),
          path: path_for(route),
          name: route.name
        }
      end
      out
    end
    private_class_method :routes_for

    def build_all(root)
      lines = {}
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller].to_s
        action = route.defaults[:action].to_s
        next if controller.empty? || action.empty? || controller.match?(INTERNAL_CONTROLLER)

        file = "app/controllers/#{controller}_controller.rb"
        file = nil unless File.file?(File.join(root, file))
        line = file && ((lines[file] ||= def_lines(File.join(root, file)))[action])
        { verb: verb_for(route), path: path_for(route), name: route.name,
          controller: controller, action: action, file: file, line: line }
      end
    end
    private_class_method :build_all

    # { "show" => 12, ... } — first `def` of each name, 1-based.
    def def_lines(path)
      File.foreach(path, encoding: "utf-8").with_index(1).each_with_object({}) do |(text, n), out|
        name = text[/^\s*def\s+(?:self\.)?([\w?!]+)/, 1]
        out[name] ||= n if name
      end
    end
    private_class_method :def_lines

    # Rails has moved this between a String and a Regexp across versions; both
    # stringify usefully, but a Regexp needs its slashes stripped.
    def verb_for(route)
      verb = route.verb
      verb = verb.source.gsub(%r{[$^]}, "") if verb.is_a?(Regexp)
      verb = verb.to_s
      verb.empty? ? "ANY" : verb
    end
    private_class_method :verb_for

    # "(.:format)" is noise in a hint that has to fit on one line.
    def path_for(route)
      route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
    end
    private_class_method :path_for
  end
end
