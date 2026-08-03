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

    # Actions with no route are worth calling out, but only for controllers Rails
    # would actually dispatch to. These are the inherited ones every controller
    # has and nobody routes.
    NON_ACTION_METHODS = %w[
      new inspect method_of to_s hash class dup freeze
    ].freeze

    # "app/controllers/admin/users_controller.rb" -> "admin/users", which is the
    # key Rails stores in a route's defaults.
    def controller_key(relative_path)
      path = relative_path.to_s.sub(%r{\A/+}, "")
      match = path.match(%r{\Aapp/controllers/(.+)_controller\.rb\z})
      return nil unless match

      match[1]
    end

    # => { "show" => [{ verb:, path:, name: }], ... }
    def for_controller(key)
      return {} if key.nil? || key.empty?
      return {} unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      routes_for(key)
    rescue StandardError
      # A broken route set must not take the editor down with it — the file still
      # opens, just without hints.
      {}
    end

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
