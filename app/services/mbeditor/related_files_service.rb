# frozen_string_literal: true

module Mbeditor
  # Everything in the workspace related to one resource ("User"), for the AI
  # export picker's "Related to..." search.
  #
  # Direct hits (the resource's own files and the migrations that touch its
  # table) start ticked in the picker; one-step-out hits (associated models,
  # files that merely mention it) start unticked.
  module RelatedFilesService
    module_function

    MAX_REFERENCE_FILES = 200
    # Matched lines, not files: one hot file can eat many rows before 200
    # distinct files are seen.
    MAX_REFERENCE_LINES = 2000
    SCHEMA_FILES = %w[db/schema.rb db/structure.sql].freeze

    GROUP_REASONS = {
      controller: "controller", model: "model", views: "view", helper: "helper",
      tests: "test", concerns: "concern"
    }.freeze

    # Returns { files: [{path:, reason:, direct:}], capped: bool }. Dedupes by
    # path, keeping the most direct reason (then the first found).
    def call(workspace_root, query, excluded_paths:)
      root = workspace_root.to_s
      name = query.to_s.strip.camelize
      graph = ModelGraphService.call(root)
      model = graph[:ok] ? graph[:models].find { |m| m[:name] == name } : nil
      table = model&.dig(:table) || name.demodulize.underscore.pluralize

      found = convention_files(root, name) + migration_files(root, name, table)
      found += associated_models(graph, name) if model
      references, capped = reference_files(root, name, table, excluded_paths)
      found += references

      matcher = ExclusionMatcher.new(excluded_paths, root: root)
      files = found.select { |f| usable?(root, f[:path], matcher) }
                   .group_by { |f| f[:path] }
                   .map { |_, hits| hits.find { |f| f[:direct] } || hits.first }
                   .sort_by { |f| [f[:direct] ? 0 : 1, f[:path]] }
      { files: files, capped: capped }
    end

    # The same grouping the Rails panel shows, taken from the model's path.
    def convention_files(root, name)
      groups = RailsRelatedFilesService.find(root, "app/models/#{name.underscore}.rb")
      groups.except(:custom).flat_map do |group, entries|
        entries.map { |e| hit(e[:path], GROUP_REASONS.fetch(group, group.to_s), true) }
      end
    end

    # Reflection already resolved class_name:, through: and inverse sides.
    def associated_models(graph, name)
      # No source file (model defined outside the workspace): fall back to the
      # conventional path; usable? drops it if it is not there.
      files = graph[:models].to_h { |m| [m[:name], m[:file] || "app/models/#{m[:name].underscore}.rb"] }
      graph[:edges].filter_map do |e|
        if e[:from] == name
          hit(files[e[:to]], "#{e[:macro]} :#{e[:name]}", false)
        elsif e[:to] == name
          hit(files[e[:from]], "#{e[:macro]} :#{e[:name]} (#{e[:from]})", false)
        end
      end
    end

    def migration_files(root, name, table)
      t = Regexp.escape(table)
      singular = name.demodulize.underscore
      ref = Regexp.escape(singular)
      own = /\b(?:create_table|change_table|drop_table|add_column|remove_column|rename_column|change_column|add_index|remove_index|add_reference|remove_reference|add_belongs_to)\s*\(?\s*[:"']#{t}\b/
      other = /\b(?:add_reference|add_belongs_to|references|belongs_to)\s*\(?\s*(?:[:"']\w+["']?\s*,\s*)?[:"']#{ref}\b/
      schema = /create_table\s+["']#{t}["']|CREATE TABLE\s+(?:\w+\.)?"?#{t}\b/i

      paths = Dir.glob(File.join(root, "db", "migrate", "*.rb")).map { |abs| abs.delete_prefix("#{root}/") }
      hits = paths.filter_map do |rel|
        text = File.read(File.join(root, rel))
        if text.match?(own)
          hit(rel, "alters #{table}", true)
        elsif text.match?(other)
          hit(rel, "adds #{singular} reference", true)
        end
      rescue SystemCallError
        nil
      end
      SCHEMA_FILES.each do |rel|
        abs = File.join(root, rel)
        hits << hit(rel, "defines #{table}", true) if File.file?(abs) && File.read(abs).match?(schema)
      rescue SystemCallError
        next
      end
      hits
    end

    # Word-boundary matches for the constant and the table name, through the
    # same rg / git grep / grep tiers the search panel uses.
    def reference_files(root, name, table, excluded_paths)
      seen = {}
      lines = 0
      [name, table].uniq.each do |term|
        rows = SearchReplaceService.search(root, term, limit: MAX_REFERENCE_LINES, use_regex: false,
                                                       match_case: true, whole_word: true, excluded_paths: excluded_paths)
        lines += rows.length
        rows.each { |r| seen[r[:file]] ||= "references #{term}" }
      end
      capped = seen.length > MAX_REFERENCE_FILES || lines >= MAX_REFERENCE_LINES
      [seen.first(MAX_REFERENCE_FILES).map { |path, reason| hit(path, reason, false) }, capped]
    end

    def hit(path, reason, direct)
      { path: path, reason: reason, direct: direct } if path
    end

    # Workspace-relative, an existing file, and not under an exclusion: the
    # same gate the export applies, so nothing here can name what it would refuse.
    def usable?(root, path, matcher)
      return false if path.nil? || path.start_with?("/")

      full = File.expand_path(path, root)
      full.start_with?("#{root}/") && File.file?(full) && !matcher.excluded?(path)
    end

    private_class_method :convention_files, :associated_models, :migration_files, :reference_files, :hit, :usable?
  end
end
