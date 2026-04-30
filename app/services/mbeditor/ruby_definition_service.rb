# frozen_string_literal: true

require "find"
require "json"
require "ripper"

module Mbeditor
  # Searches .rb files in a workspace for definitions of a named Ruby method
  # using Ripper's AST parser (no subprocesses).
  #
  # Returns an array of hashes, each describing one definition site:
  #   {
  #     file:      String,  # workspace-relative path
  #     line:      Integer, # 1-based line number of the `def` keyword
  #     signature: String,  # trimmed source text of the def line
  #     comments:  String   # leading # comment lines immediately above the def (may be empty)
  #   }
  #
  # Usage:
  #   results = RubyDefinitionService.call(workspace_root, "my_method",
  #                                        excluded_dirnames: %w[tmp .git])
  #
  # Additional class methods for IntelliSense features:
  #   RubyDefinitionService.defs_in_file(abs_path)
  #     → { "method_name" => [{ line: Integer, signature: String }, ...] }
  #   RubyDefinitionService.module_defined_in(workspace_root, "ModuleName", ...)
  #     → abs_path String or nil
  #   RubyDefinitionService.includes_in_file(abs_path)
  #     → ["ModuleName", ...]  (include/extend/prepend calls)
  class RubyDefinitionService
    MAX_RESULTS = 20
    MAX_COMMENT_LOOKAHEAD = 15
    MAX_FILES_SCANNED = 10_000

    # In-process file-index cache.
    # Structure: { absolute_path => {
    #   mtime: Float, lines: [String],
    #   all_defs: { method_name => [line, ...] },
    #   module_names: [String],    # module/class names defined in the file
    #   include_calls: [String]    # module names passed to include/extend/prepend
    # } }
    # Protected by a Mutex; entries are invalidated lazily via mtime comparison.
    # When +cache_path+ is set (done automatically by the engine initializer), the
    # cache is persisted to disk as JSON so it survives process restarts.
    @file_cache   = {}
    @mutex        = Mutex.new
    @cache_path   = nil
    @cache_loaded = false

    class << self
      attr_reader :file_cache, :mutex
      attr_accessor :cache_path

      def call(workspace_root, symbol, excluded_dirnames: [], excluded_paths: [])
        new(workspace_root, symbol,
            excluded_dirnames: excluded_dirnames,
            excluded_paths: excluded_paths).call
      end

      # Load the JSON cache from disk exactly once per process (double-checked
      # under the mutex so concurrent first-calls don't double-load).
      def load_disk_cache_once
        return if @cache_loaded

        @mutex.synchronize do
          return if @cache_loaded

          @cache_loaded = true
          path = @cache_path.to_s
          return if path.empty? || !File.exist?(path)

          raw = JSON.parse(File.read(path))
          raw.each do |abs_path, entry|
            @file_cache[abs_path] = {
              mtime:         entry["mtime"].to_f,
              lines:         entry["lines"],
              all_defs:      entry["all_defs"],
              module_names:  entry["module_names"],   # nil for old-format entries → triggers re-parse
              include_calls: entry["include_calls"]   # nil for old-format entries → triggers re-parse
            }
          end
        rescue StandardError
          nil # corrupted or incompatible cache file — start fresh
        end
      end

      # Atomically write the in-memory cache to disk (tmp-file + rename).
      def persist_cache
        path = @cache_path.to_s
        return if path.empty?

        snapshot = @mutex.synchronize { @file_cache.dup }
        tmp_path = "#{path}.tmp"
        File.write(tmp_path, JSON.generate(snapshot))
        File.rename(tmp_path, path)
      rescue StandardError
        nil
      end

      # Exposed for tests.
      def clear_cache!
        @mutex.synchronize { @file_cache.clear; @cache_loaded = false }
        path = @cache_path.to_s
        File.delete(path) if !path.empty? && File.exist?(path)
      rescue StandardError
        nil
      end

      # Returns all method defs in a single file from the cache (no workspace walk).
      # The file must already be cached; returns {} if not found.
      # Result: { "method_name" => [{ line: Integer, signature: String }, ...] }
      def defs_in_file(file_path)
        load_disk_cache_once
        entry = @mutex.synchronize { @file_cache[file_path.to_s] }
        return {} unless entry

        entry[:all_defs].transform_values do |lines_arr|
          lines_arr.map { |line| { line: line, signature: (entry[:lines][line - 1] || "").strip } }
        end
      end

      # Searches the cache (and triggers a workspace scan if needed) to find
      # which file in +workspace_root+ defines the given module or class name.
      # Returns the absolute file path string or nil.
      def module_defined_in(workspace_root, module_name, excluded_dirnames: [], excluded_paths: [])
        load_disk_cache_once
        result = @mutex.synchronize do
          @file_cache.find { |_path, entry| entry[:module_names]&.include?(module_name) }
        end
        return result[0] if result

        # Cache miss: scan workspace to populate cache entries with module_names.
        new(workspace_root, nil,
            excluded_dirnames: excluded_dirnames,
            excluded_paths:    excluded_paths).scan_workspace

        result = @mutex.synchronize do
          @file_cache.find { |_path, entry| entry[:module_names]&.include?(module_name) }
        end
        result ? result[0] : nil
      end

      # Returns the list of module/class names passed to include/extend/prepend
      # in the given file, from the cache.  The file must already be cached;
      # returns [] if not found.
      def includes_in_file(file_path)
        load_disk_cache_once
        entry = @mutex.synchronize { @file_cache[file_path.to_s] }
        return [] unless entry

        entry[:include_calls] || []
      end

      # Convenience wrapper: scan the whole workspace to warm the cache.
      # Fast on subsequent calls (only re-parses files whose mtime changed).
      def scan(workspace_root, excluded_dirnames: [], excluded_paths: [])
        new(workspace_root, nil,
            excluded_dirnames: excluded_dirnames,
            excluded_paths:    excluded_paths).scan_workspace
      end
    end

    def initialize(workspace_root, symbol, excluded_dirnames: [], excluded_paths: [])
      @workspace_root   = workspace_root.to_s.chomp("/")
      @symbol           = symbol
      @excluded_dirnames = Array(excluded_dirnames)
      @excluded_paths    = Array(excluded_paths)
    end

    # Walks the entire workspace and populates the per-file cache (including the
    # new module_names and include_calls fields) without filtering by symbol.
    # Used by +module_defined_in+ to ensure the cache is warm.
    def scan_workspace
      self.class.load_disk_cache_once
      @new_entries  = false
      files_scanned = 0
      evict_deleted_cache_entries

      Find.find(@workspace_root) do |path|
        if File.directory?(path)
          dirname = File.basename(path)
          rel_dir = relative_path(path)
          Find.prune if path != @workspace_root && excluded_dir?(dirname, rel_dir)
          next
        end
        next unless path.end_with?(".rb")

        rel = relative_path(path)
        next if excluded_rel_path?(rel, File.basename(path))

        files_scanned += 1
        if files_scanned > MAX_FILES_SCANNED
          Rails.logger.warn("[mbeditor] RubyDefinitionService: workspace exceeds #{MAX_FILES_SCANNED} .rb files; stopping scan early")
          break
        end
        begin
          cache_entry_for(path)
        rescue StandardError
          nil
        end
      end

      self.class.persist_cache if @new_entries
    end

    def call
      self.class.load_disk_cache_once

      results       = []
      @new_entries  = false
      files_scanned = 0

      evict_deleted_cache_entries

      Find.find(@workspace_root) do |path|
        # Prune excluded directories
        if File.directory?(path)
          dirname = File.basename(path)
          rel_dir = relative_path(path)
          if path != @workspace_root && excluded_dir?(dirname, rel_dir)
            Find.prune
          end
          next
        end

        next unless path.end_with?(".rb")

        rel = relative_path(path)
        next if excluded_rel_path?(rel, File.basename(path))

        files_scanned += 1
        if files_scanned > MAX_FILES_SCANNED
          Rails.logger.warn("[mbeditor] RubyDefinitionService: workspace exceeds #{MAX_FILES_SCANNED} .rb files; stopping scan early")
          break
        end

        begin
          cached = cache_entry_for(path)
          next unless cached

          hit_lines = @symbol ? cached[:all_defs].fetch(@symbol, nil) : nil
          next unless hit_lines && hit_lines.any?

          hit_lines.each do |def_line|
            results << {
              file:      rel,
              line:      def_line,
              signature: (cached[:lines][def_line - 1] || "").strip,
              comments:  extract_comments(cached[:lines], def_line)
            }
            return results if results.length >= MAX_RESULTS
          end
        rescue StandardError
          # Malformed file or unreadable; skip silently
        end
      end

      self.class.persist_cache if @new_entries
      results
    end

    private

    # Remove cache entries for files that no longer exist on disk.
    def evict_deleted_cache_entries
      stale_keys = self.class.mutex.synchronize do
        self.class.file_cache.keys.select { |p| !File.exist?(p) }
      end
      return if stale_keys.empty?

      self.class.mutex.synchronize { stale_keys.each { |k| self.class.file_cache.delete(k) } }
      @new_entries = true
    end

    # Returns the cached index entry for +path+, rebuilding it if the file has
    # been modified since the last parse.  Returns nil on any read/parse error.
    def cache_entry_for(path)
      mtime = File.mtime(path).to_f
      cached = self.class.mutex.synchronize { self.class.file_cache[path] }
      return cached if cached && cached[:mtime] == mtime && !cached[:module_names].nil?

      source                              = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      lines                               = source.split("\n", -1)
      sexp                                = Ripper.sexp(source)
      all_defs, module_names, include_calls = sexp ? collect_all_defs(sexp) : [{}, [], []]
      entry = { mtime: mtime, lines: lines, all_defs: all_defs,
                module_names: module_names, include_calls: include_calls }
      self.class.mutex.synchronize { self.class.file_cache[path] = entry }
      @new_entries = true
      entry
    rescue StandardError
      nil
    end

    # Walk the Ripper sexp once and collect method definitions, module/class names,
    # and include/extend/prepend calls.
    # Returns [defs_hash, module_names_array, include_calls_array].
    def collect_all_defs(sexp)
      defs          = Hash.new { |h, k| h[k] = [] }
      module_names  = []
      include_calls = []
      walk_all(sexp, defs, module_names, include_calls)
      [defs, module_names, include_calls]
    end

    def walk_all(node, defs, module_names, include_calls)
      return unless node.is_a?(Array)

      case node[0]
      when :def
        name_node = node[1]
        if name_node.is_a?(Array) && name_node[1].is_a?(String)
          line = name_node[2]&.first
          defs[name_node[1]] << line if line
        end
        node[1..].each { |child| walk_all(child, defs, module_names, include_calls) }

      when :defs
        name_node = node[3]
        if name_node.is_a?(Array) && name_node[1].is_a?(String)
          line = name_node[2]&.first
          defs[name_node[1]] << line if line
        end
        node[1..].each { |child| walk_all(child, defs, module_names, include_calls) }

      when :module, :class
        # Collect the module/class constant name.
        # sexp: [:module, [:const_ref, [:@const, "Name", [line, col]]], body]
        #   or: [:class,  [:const_ref, [:@const, "Name", [line, col]]], superclass, body]
        const_ref = node[1]
        if const_ref.is_a?(Array)
          inner = const_ref[0] == :const_ref ? const_ref[1] : const_ref
          if inner.is_a?(Array) && inner[0] == :@const && inner[1].is_a?(String)
            module_names << inner[1]
          end
        end
        node[1..].each { |child| walk_all(child, defs, module_names, include_calls) }

      when :command
        # Collect include/extend/prepend calls.
        # sexp: [:command, [:@ident, "include", [line, col]],
        #          [:args_add_block, [[:var_ref, [:@const, "Name", ...]], ...], false]]
        ident_node = node[1]
        if ident_node.is_a?(Array) && ident_node[0] == :@ident &&
           %w[include extend prepend].include?(ident_node[1])
          args_node = node[2]
          if args_node.is_a?(Array) && args_node[0] == :args_add_block
            Array(args_node[1]).each do |arg|
              if arg.is_a?(Array) && arg[0] == :var_ref
                const_node = arg[1]
                if const_node.is_a?(Array) && const_node[0] == :@const && const_node[1].is_a?(String)
                  include_calls << const_node[1]
                end
              end
            end
          end
        end
        node[1..].each { |child| walk_all(child, defs, module_names, include_calls) }

      else
        node.each { |child| walk_all(child, defs, module_names, include_calls) }
      end
    end

    # Walk backwards from def_line collecting contiguous # comment lines.
    # Stops on blank lines or non-comment lines.
    def extract_comments(lines, def_line)
      comment_lines = []
      idx = def_line - 2  # 0-based index of the line immediately above the def

      MAX_COMMENT_LOOKAHEAD.times do
        break if idx < 0

        line = lines[idx].to_s.strip
        break if line.empty?
        break unless line.start_with?("#")

        comment_lines.unshift(line)
        idx -= 1
      end

      comment_lines.join("\n")
    end

    def relative_path(full_path)
      full_path.to_s.delete_prefix(@workspace_root).delete_prefix("/")
    end

    def excluded_dir?(dirname, rel_dir)
      @excluded_dirnames.include?(dirname) ||
        @excluded_paths.any? do |pattern|
          if pattern.include?("/")
            rel_dir == pattern || rel_dir.start_with?("#{pattern}/")
          else
            dirname == pattern
          end
        end
    end

    def excluded_rel_path?(rel, name)
      @excluded_paths.any? do |pattern|
        if pattern.include?("/")
          rel == pattern || rel.start_with?("#{pattern}/")
        else
          name == pattern || rel.split("/").include?(pattern)
        end
      end
    end
  end
end
