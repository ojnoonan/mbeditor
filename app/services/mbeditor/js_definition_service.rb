# frozen_string_literal: true

require "open3"

module Mbeditor
  # Searches JS/JSX/TS/TSX files in the workspace for definitions of a named
  # JavaScript global (variable, function, class, or window property assignment).
  #
  # Uses ripgrep (falling back to grep) to locate lines matching common
  # definition patterns, then returns workspace-relative results.
  #
  # Returns an array of hashes:
  #   { file: String, line: Integer, snippet: String }
  class JsDefinitionService
    MAX_RESULTS = 20

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
      # Matches the most common JS global-definition forms, anchored so we
      # don't pick up every usage — only assignment / declaration lines.
      "(?:window\\.#{s}\\s*=|\\b(?:var|let|const)\\s+#{s}[\\s=;,]|\\bfunction\\s+#{s}[\\s({]|\\bclass\\s+#{s}\\b|\\bexport\\s+(?:default\\s+)?(?:var|let|const|function|class)\\s+#{s}\\b)"
    end

    def glob_args
      JS_GLOBS.flat_map { |g| ["-g", g] }
    end

    def run_search(pattern)
      if rg_available?
        run_rg(pattern)
      else
        run_grep(pattern)
      end
    end

    def rg_available?
      system("which rg > /dev/null 2>&1")
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
      lines.each do |raw|
        raw = raw.chomp
        # ripgrep/grep output: /abs/path/file.js:42:  window.ReactWindow = ...
        m = raw.match(/\A(.+?):(\d+):(.+)\z/)
        next unless m

        abs_path = m[1]
        line_num = m[2].to_i
        snippet  = m[3].strip

        next unless abs_path.start_with?(@workspace_root)

        rel_path = abs_path.delete_prefix(@workspace_root).delete_prefix("/")
        results << { file: rel_path, line: line_num, snippet: snippet }
        break if results.length >= MAX_RESULTS
      end
      results
    end
  end
end
