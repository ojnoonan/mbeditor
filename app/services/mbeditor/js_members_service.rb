# frozen_string_literal: true

require "open3"

module Mbeditor
  # Searches JS/JSX/TS/TSX files for properties/methods attached to a named
  # global object (direct assignment and prototype assignment patterns).
  #
  # Examples matched for symbol "ReactWindow":
  #   ReactWindow.open = function() { ... }
  #   ReactWindow.prototype.close = function() { ... }
  #
  # Returns an array of hashes:
  #   { name: String, snippet: String }
  class JsMembersService
    MAX_RESULTS = 50

    JS_GLOBS = %w[*.js *.jsx *.ts *.tsx *.js.jsx *.js.erb *.jsx.erb].freeze

    def initialize(symbol, workspace_root)
      @symbol         = symbol.to_s
      @workspace_root = workspace_root.to_s.chomp("/")
    end

    def call
      return [] if @symbol.empty? || @workspace_root.empty?
      return [] unless File.directory?(@workspace_root)

      pattern = build_pattern
      lines   = run_search(pattern)
      parse_results(lines)
    end

    private

    def build_pattern
      s = Regexp.escape(@symbol)
      "#{s}\\.(?:prototype\\.)?([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*="
    end

    def glob_args
      JS_GLOBS.flat_map { |g| ["-g", g] }
    end

    def rg_available?
      system("which rg > /dev/null 2>&1")
    end

    def run_search(pattern)
      if rg_available?
        run_rg(pattern)
      else
        run_grep(pattern)
      end
    end

    def run_rg(pattern)
      args = ["rg", "--no-heading", "-n", "--color=never",
              "-e", pattern] + glob_args + [@workspace_root]
      out, = Open3.capture2(*args)
      out.lines
    rescue StandardError
      []
    end

    def run_grep(pattern)
      globs = JS_GLOBS.map { |g| "--include=#{g}" }
      args  = ["grep", "-rn", "--color=never", "-E", pattern] + globs + [@workspace_root]
      out, = Open3.capture2(*args)
      out.lines
    rescue StandardError
      []
    end

    def parse_results(lines)
      results = []
      seen    = {}
      lines.each do |raw|
        raw = raw.chomp
        m = raw.match(/\A.+?:\d+:(.+)\z/)
        next unless m

        snippet = m[1].strip

        # Extract member name from pattern like ReactWindow.foo = or ReactWindow.prototype.foo =
        s = Regexp.escape(@symbol)
        member_match = snippet.match(/#{s}\.(?:prototype\.)?([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=/)
        next unless member_match

        name = member_match[1]
        next if seen[name]

        seen[name] = true
        results << { name: name, snippet: snippet }
        break if results.length >= MAX_RESULTS
      end
      results
    end
  end
end
