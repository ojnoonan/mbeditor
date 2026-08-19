# frozen_string_literal: true

module Mbeditor
  # Searches JS/JSX/TS/TSX files for properties/methods attached to a named
  # global object (direct assignment and prototype assignment patterns).
  #
  # Examples matched for symbol "ReactWindow":
  #   ReactWindow.open = function() { ... }
  #   ReactWindow.prototype.close = function() { ... }
  #
  # Delegates subprocess execution to CodeSearchService (rg/grep).
  #
  # Returns an array of hashes:
  #   { name: String, snippet: String, file: String, line: Integer }
  class JsMembersService
    MAX_RESULTS = 50

    def initialize(symbol, workspace_root)
      @symbol         = symbol.to_s
      @workspace_root = workspace_root.to_s.chomp("/")
      # Compiled once: this is matched against every line of search output.
      @member_regex   = /#{Regexp.escape(@symbol)}\.(?:prototype\.)?([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=/
    end

    def call
      return [] if @symbol.empty? || @workspace_root.empty?
      return [] unless File.directory?(@workspace_root)

      lines = CodeSearchService.call(build_pattern, @workspace_root)
      parse_results(lines)
    end

    private

    def build_pattern
      s = Regexp.escape(@symbol)
      # Pure POSIX ERE — see JsDefinitionService: git grep rejects (?: and
      # treats \s as a literal.
      "#{s}\\.(prototype\\.)?[a-zA-Z_$][a-zA-Z0-9_$]*[ \\t]*="
    end

    def parse_results(lines)
      results = []
      seen    = {}
      lines.each do |raw|
        raw = raw.chomp
        m = raw.match(/\A(.+?):(\d+):(.+)\z/)
        next unless m

        abs_path = m[1]
        line_num = m[2].to_i
        snippet  = m[3].strip
        next unless abs_path.start_with?(@workspace_root)

        member_match = snippet.match(@member_regex)
        next unless member_match

        name = member_match[1]
        next if seen[name]

        seen[name] = true
        results << {
          name: name,
          snippet: snippet,
          file: abs_path.delete_prefix(@workspace_root).delete_prefix("/"),
          line: line_num
        }
        break if results.length >= MAX_RESULTS
      end
      results
    end
  end
end
