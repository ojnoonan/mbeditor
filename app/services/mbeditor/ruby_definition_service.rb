# frozen_string_literal: true

require "find"
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

    def self.call(workspace_root, symbol, excluded_dirnames: [], excluded_paths: [])
      new(workspace_root, symbol,
          excluded_dirnames: excluded_dirnames,
          excluded_paths: excluded_paths).call
    end

    def initialize(workspace_root, symbol, excluded_dirnames: [], excluded_paths: [])
      @workspace_root   = workspace_root.to_s.chomp("/")
      @symbol           = symbol
      @excluded_dirnames = Array(excluded_dirnames)
      @excluded_paths    = Array(excluded_paths)
    end

    def call
      results = []

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

        begin
          source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
          lines  = source.split("\n", -1)
          hits   = find_definitions(source, @symbol)

          hits.each do |def_line|
            results << {
              file:      rel,
              line:      def_line,
              signature: (lines[def_line - 1] || "").strip,
              comments:  extract_comments(lines, def_line)
            }
            return results if results.length >= MAX_RESULTS
          end
        rescue StandardError
          # Malformed file or unreadable; skip silently
        end
      end

      results
    end

    private

    # Parse `source` with Ripper and return sorted array of 1-based line numbers
    # where a method named `symbol` is defined (handles both `def foo` and `def self.foo`).
    def find_definitions(source, symbol)
      sexp = Ripper.sexp(source)
      return [] unless sexp

      lines = []
      walk(sexp, symbol, lines)
      lines.sort
    end

    # Recursive sexp walker.  Ripper represents:
    #   def foo(...)   as  [:def,  [:@ident, "foo",  [line, col]], ...]
    #   def self.foo   as  [:defs, receiver, [:@ident, "foo", [line, col]], ...]
    def walk(node, symbol, lines)
      return unless node.is_a?(Array)

      case node[0]
      when :def
        # node[1] is the method name node: [:@ident, "name", [line, col]]
        name_node = node[1]
        if name_node.is_a?(Array) && name_node[1].to_s == symbol
          line = name_node[2]&.first
          lines << line if line
        end
        # Still walk children in case of nested defs
        node[1..].each { |child| walk(child, symbol, lines) }

      when :defs
        # node[3] is the method name node for `def self.foo`
        name_node = node[3]
        if name_node.is_a?(Array) && name_node[1].to_s == symbol
          line = name_node[2]&.first
          lines << line if line
        end
        node[1..].each { |child| walk(child, symbol, lines) }

      else
        node.each { |child| walk(child, symbol, lines) }
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
