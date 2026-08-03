# frozen_string_literal: true

module Mbeditor
  # Builds a graph of the host app's ActiveRecord models and the associations
  # between them, for the Models sidebar tab.
  #
  # Reads the associations by *reflection* rather than by parsing model files.
  # mbeditor already runs inside the host app, so `reflect_on_all_associations`
  # is right there — and it resolves `class_name:`, `through:`, polymorphic and
  # inverse sides correctly, which regex or AST parsing of `has_many` lines
  # silently gets wrong. (ruby-lsp cannot help here: its index models constants
  # and methods, not associations.)
  #
  # Deliberately never touches the database connection. Reflections are pure
  # metadata, so this works on an app whose database isn't running or migrated;
  # column counts are only filled in when a connection happens to be live.
  class ModelGraphService
    # Rails' own models — ActiveStorage, ActionText, SolidQueue, schema
    # migrations — are not what you opened this tab to look at.
    IGNORED_NAMESPACES = %w[
      ActiveRecord ActiveStorage ActionText ActionMailbox
      SolidQueue SolidCache SolidCable
    ].freeze

    # Cap on models drawn. 300 was chosen before the layout could handle that
    # many; a schema slightly over it silently lost models and only said
    # "(truncated)". Raised, and configurable for anything larger — the cost of
    # a bigger graph is now the browser's rendering, not the layout.
    DEFAULT_MAX_MODELS = 1000

    def self.max_models
      value = Mbeditor.configuration.model_graph_max_models.to_i
      value.positive? ? value : DEFAULT_MAX_MODELS
    end

    # Only the first few columns travel: the diagram box shows that many and the
    # full list is a click away in the schema modal, which fetches its own data
    # from /model_schema.
    MAX_COLUMNS_SENT = 8

    class << self
      def call(workspace_root)
        root = workspace_root.to_s
        fingerprint = fingerprint_for(root)

        cached = MUTEX.synchronize { @cache }
        return cached[:payload] if cached && cached[:fingerprint] == fingerprint && cached[:root] == root

        payload = build(root)
        payload[:fingerprint] = fingerprint
        MUTEX.synchronize { @cache = { root: root, fingerprint: fingerprint, payload: payload } }
        write_artifacts(root, payload)
        payload
      end

      # Only needed for an explicit refresh: ordinary saves are picked up by
      # the fingerprint below, so there is no file-change hook to keep in sync.
      def invalidate(_root = nil)
        MUTEX.synchronize { @cache = nil }
        nil
      end

      # A cheap stand-in for "have the models changed": the newest mtime and the
      # file count across the model and migration directories. Avoids
      # eager-loading the app just to decide whether the cache is stale.
      def fingerprint_for(root)
        dirs = [File.join(root, "app", "models"), File.join(root, "db", "migrate")]
        newest = 0
        count = 0
        dirs.each do |dir|
          next unless File.directory?(dir)

          Dir.glob(File.join(dir, "**", "*.rb")).each do |f|
            count += 1
            mtime = File.mtime(f).to_i
            newest = mtime if mtime > newest
          end
        end
        "#{newest}:#{count}"
      rescue StandardError
        "unknown"
      end

      private

      MUTEX = Mutex.new
      private_constant :MUTEX

      def build(root)
        unless defined?(::ActiveRecord::Base)
          return unavailable("This app does not use ActiveRecord, so there are no models to graph.")
        end

        eager_load!
        classes = model_classes
        return unavailable("No ActiveRecord models found in this application.") if classes.empty?

        limit = max_models
        models = classes.first(limit).map { |klass| describe_model(klass, root) }
        known = models.map { |m| m[:name] }.to_set

        {
          ok: true,
          models: models,
          # Edges to classes outside the graph (a gem's model, or a typo in
          # class_name:) would render as arrows into nowhere.
          edges: models.flat_map { |m| m.delete(:edges) }.select { |e| known.include?(e[:to]) }.uniq,
          truncated: classes.length > limit,
          generatedAt: Time.now.utc.iso8601
        }
      rescue StandardError => e
        unavailable("Could not read the model graph: #{e.class}: #{e.message}")
      end

      def unavailable(message)
        { ok: false, error: message, models: [], edges: [], generatedAt: Time.now.utc.iso8601 }
      end

      # In development the host app is lazily loaded, so most models are not
      # constants yet. This is the one genuinely expensive step.
      def eager_load!
        Rails.application.eager_load! if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      rescue StandardError => e
        # A model that raises on load shouldn't cost you the whole diagram —
        # whatever did load is still worth drawing.
        Rails.logger.warn("[mbeditor] eager_load for the model graph failed: #{e.class}: #{e.message}") if defined?(Rails)
      end

      def model_classes
        ::ActiveRecord::Base.descendants.reject do |klass|
          klass.name.nil? ||
            klass.abstract_class? ||
            IGNORED_NAMESPACES.any? { |ns| klass.name.start_with?("#{ns}::") }
        end.sort_by(&:name)
      rescue StandardError
        []
      end

      def describe_model(klass, root)
        columns = column_list(klass)
        {
          name: klass.name,
          table: safe(-> { klass.table_name }),
          columns: columns.first(MAX_COLUMNS_SENT),
          columnCount: columns.length,
          superclass: klass.superclass&.name,
          file: model_file(klass, root),
          edges: associations_for(klass)
        }
      end

      # Needs a live database connection, so it degrades to an empty list rather
      # than failing: the graph is still worth drawing against a database that
      # isn't running or migrated.
      def column_list(klass)
        klass.columns.map { |c| { name: c.name, type: c.type.to_s } }
      rescue StandardError
        []
      end

      # Where the class was defined, made workspace-relative so the editor can
      # open it. Models outside the workspace (a gem, or an engine) get no file
      # and simply aren't clickable.
      def model_file(klass, root)
        location = Object.const_source_location(klass.name)
        path = location && location.first
        return nil unless path

        prefix = root.end_with?("/") ? root : "#{root}/"
        path.start_with?(prefix) ? path.delete_prefix(prefix) : nil
      rescue StandardError
        nil
      end

      def associations_for(klass)
        klass.reflect_on_all_associations.filter_map do |reflection|
          # A polymorphic belongs_to has no single target class — there is no
          # edge to draw.
          next if safe(-> { reflection.polymorphic? })

          target = safe(-> { reflection.class_name })
          next if target.nil?

          {
            from: klass.name,
            to: target,
            macro: reflection.macro.to_s,
            name: reflection.name.to_s,
            through: safe(-> { reflection.options[:through]&.to_s })
          }
        end
      rescue StandardError
        []
      end

      # Reflection can raise for half-configured associations; one bad
      # association must not take out the whole graph.
      def safe(callable)
        callable.call
      rescue StandardError
        nil
      end

      # The user asked for a file in tmp. The JSON is what the editor reads back
      # if it wants to; the .mmd is a Mermaid ER diagram that GitHub, VS Code
      # and mermaid.live all render, for when you want a prettier picture than
      # the sidebar draws.
      def write_artifacts(root, payload)
        dir = File.join(root, "tmp")
        return unless File.directory?(dir)

        File.write(File.join(dir, "mbeditor_model_graph.json"), JSON.pretty_generate(payload))
        File.write(File.join(dir, "mbeditor_model_graph.mmd"), to_mermaid(payload))
      rescue StandardError => e
        Rails.logger.debug("[mbeditor] could not write model graph artifacts: #{e.message}") if defined?(Rails)
      end

      MERMAID_CARDINALITY = {
        "belongs_to" => "}o--||",
        "has_one" => "||--o|",
        "has_many" => "||--o{",
        "has_and_belongs_to_many" => "}o--o{"
      }.freeze

      def to_mermaid(payload)
        lines = ["erDiagram"]
        payload[:models].each { |m| lines << "  #{mermaid_id(m[:name])} {" << "  }" }
        payload[:edges].each do |e|
          arrow = MERMAID_CARDINALITY.fetch(e[:macro], "||--||")
          label = e[:through] ? "#{e[:name]} (through #{e[:through]})" : e[:name]
          lines << %(  #{mermaid_id(e[:from])} #{arrow} #{mermaid_id(e[:to])} : "#{label}")
        end
        "#{lines.join("\n")}\n"
      end

      # Mermaid entity names can't contain ::
      def mermaid_id(name)
        name.to_s.gsub("::", "_")
      end
    end
  end
end
