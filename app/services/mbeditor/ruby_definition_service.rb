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
  class RubyDefinitionService
    MAX_RESULTS = 20
    MAX_COMMENT_LOOKAHEAD = 15
    MAX_FILES_SCANNED = 10_000

    # In-process file-index cache.
    # Structure: { absolute_path => { mtime: Float, lines: [String], all_defs: { method_name => [line, ...] } } }
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
              mtime:    entry["mtime"].to_f,
              lines:    entry["lines"],
              all_defs: entry["all_defs"]
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
    end

    def initialize(workspace_root, symbol, excluded_dirnames: [], excluded_paths: [])
      @workspace_root   = workspace_root.to_s.chomp("/")
      @symbol           = symbol
      @excluded_dirnames = Array(excluded_dirnames)
      @excluded_paths    = Array(excluded_paths)
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

          hit_lines = cached[:all_defs][@symbol]
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
      return cached if cached && cached[:mtime] == mtime

      source   = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      lines    = source.split("\n", -1)
      sexp     = Ripper.sexp(source)
      all_defs = sexp ? collect_all_defs(sexp) : {}
      entry    = { mtime: mtime, lines: lines, all_defs: all_defs }
      self.class.mutex.synchronize { self.class.file_cache[path] = entry }
      @new_entries = true
      entry
    rescue StandardError
      nil
    end

    # Walk the Ripper sexp once and collect every method definition, returning
    # a hash of the form { "method_name" => [line_number, ...] }.
    def collect_all_defs(sexp)
      defs = Hash.new { |h, k| h[k] = [] }
      walk_all(sexp, defs)
      defs
    end

    def walk_all(node, defs)
      return unless node.is_a?(Array)

      case node[0]
      when :def
        name_node = node[1]
        if name_node.is_a?(Array) && name_node[1].is_a?(String)
          line = name_node[2]&.first
          defs[name_node[1]] << line if line
        end
        node[1..].each { |child| walk_all(child, defs) }

      when :defs
        name_node = node[3]
        if name_node.is_a?(Array) && name_node[1].is_a?(String)
          line = name_node[2]&.first
          defs[name_node[1]] << line if line
        end
        node[1..].each { |child| walk_all(child, defs) }

      else
        node.each { |child| walk_all(child, defs) }
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
