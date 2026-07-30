# frozen_string_literal: true

module Mbeditor
  # Searches JS/JSX/TS/TSX files in the workspace for definitions of a named
  # JavaScript global (variable, function, class, or window property assignment).
  #
  # Delegates subprocess execution to CodeSearchService (rg/git grep/grep).
  #
  # Ranking: top-level declarations (column 0, `window.X =`, or `export`) are
  # Sprockets globals and sort before nested/indented matches, so go-to-
  # definition prefers the global over a same-named function buried inside an
  # IIFE. When +parent+ is given (the user clicked `Parent.myFunction` or a
  # name destructured from Parent), member definitions are resolved first.
  #
  # Returns an array of hashes:
  #   { file: String, line: Integer, snippet: String, topLevel: Boolean }
  # Member results additionally carry member: true.
  class JsDefinitionService
    MAX_RESULTS = 20
    # Matches parsed before ranking. The cap must be applied AFTER sorting or
    # a flood of nested matches could crowd the top-level definition out.
    SCAN_CAP = 200

    IDENT = /[a-zA-Z_$][a-zA-Z0-9_$]*/

    def initialize(symbol, workspace_root, parent: nil)
      @symbol         = symbol.to_s
      @workspace_root = workspace_root.to_s.chomp("/")
      @parent         = parent.to_s.empty? ? nil : parent.to_s
    end

    def call
      return [] if @symbol.empty? || @workspace_root.empty?
      return [] unless File.directory?(@workspace_root)

      if @parent
        member_results = member_definitions
        return member_results unless member_results.empty?
      end

      ranked_plain_results
    end

    private

    def ranked_plain_results
      lines = CodeSearchService.call(build_pattern, @workspace_root)
      results = parse_results(lines, cap: SCAN_CAP)
      results.sort_by.with_index { |r, i| [r[:topLevel] ? 0 : 1, i] }.first(MAX_RESULTS)
    end

    # Patterns below must be PURE POSIX ERE — they run through rg, git grep,
    # and BSD/GNU grep. git grep's regex engine rejects `(?:`, and treats
    # `\b`/`\s` as literals, so: plain capture groups only, `[ \t]` for
    # whitespace, and `(^|[^A-Za-z0-9_$])` / `([^A-Za-z0-9_$]|$)` for word
    # boundaries.
    NOT_IDENT = "[^A-Za-z0-9_$]"

    # Stage 1: explicit member assignment anywhere in the workspace — the
    # parent name on the line makes the pattern precise enough for a global
    # search. Stage 2: object-literal method forms (`myFunction: function(`,
    # shorthand `myFunction(args) {`), which carry no parent name on the line,
    # restricted to the files where Parent itself is defined.
    def member_definitions
      p = Regexp.escape(@parent)
      s = Regexp.escape(@symbol)

      assignment = "#{p}\\.(prototype\\.)?#{s}[ \\t]*="
      results = parse_results(CodeSearchService.call(assignment, @workspace_root), cap: SCAN_CAP)
      unless results.empty?
        return results.map { |r| r.merge(topLevel: false, member: true) }.first(MAX_RESULTS)
      end

      parent_files = self.class.new(@parent, @workspace_root).call.map { |r| r[:file] }
      return [] if parent_files.empty?

      literal = "(^|#{NOT_IDENT})#{s}[ \\t]*:[ \\t]*(async[ \\t]+)?function(#{NOT_IDENT}|$)" \
                "|(^|#{NOT_IDENT})#{s}[ \\t]*\\([^)]*\\)[ \\t]*\\{"
      candidates = parse_results(CodeSearchService.call(literal, @workspace_root), cap: SCAN_CAP)
      candidates.select { |r| parent_files.include?(r[:file]) }
                .map { |r| r.merge(topLevel: false, member: true) }
                .first(MAX_RESULTS)
    end

    def build_pattern
      s = Regexp.escape(@symbol)
      # Matches the most common JS global-definition forms, anchored so we
      # don't pick up every usage — only assignment / declaration lines.
      "(window\\.#{s}[ \\t]*=" \
        "|(^|#{NOT_IDENT})(var|let|const)[ \\t]+#{s}[ \\t=;,]" \
        "|(^|#{NOT_IDENT})function[ \\t]+#{s}[ \\t({]" \
        "|(^|#{NOT_IDENT})class[ \\t]+#{s}(#{NOT_IDENT}|$)" \
        "|(^|#{NOT_IDENT})export[ \\t]+(default[ \\t]+)?(var|let|const|function|class)[ \\t]+#{s}(#{NOT_IDENT}|$))"
    end

    def parse_results(lines, cap: MAX_RESULTS)
      results = []
      lines.each do |raw|
        raw = raw.chomp
        # ripgrep/grep output: /abs/path/file.js:42:  window.ReactWindow = ...
        m = raw.match(/\A(.+?):(\d+):(.+)\z/)
        next unless m

        abs_path = m[1]
        line_num = m[2].to_i
        body     = m[3]
        indent   = body[/\A[ \t]*/]
        snippet  = body.strip

        next unless abs_path.start_with?(@workspace_root)

        rel_path = abs_path.delete_prefix(@workspace_root).delete_prefix("/")
        results << {
          file: rel_path,
          line: line_num,
          snippet: snippet,
          topLevel: top_level?(indent, snippet)
        }
        break if results.length >= cap
      end
      results
    end

    # Column-0 declarations are Sprockets globals by definition; `window.X =`
    # creates a global even when indented inside an IIFE body; `export` is
    # top-level by grammar.
    def top_level?(indent, snippet)
      return true if indent.empty?
      return true if snippet.match?(/\Awindow\.#{Regexp.escape(@symbol)}\s*=/)
      return true if snippet.start_with?("export ")

      false
    end
  end
end
