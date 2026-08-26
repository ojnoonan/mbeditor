# frozen_string_literal: true

module Mbeditor
  # Translates ruby-lsp results for the definition/hover/completion/raw-passthrough
  # kinds into the shapes their existing consumers expect. Diagnostics have
  # their own translator (LspDiagnosticsTranslator) with a different interface
  # — no workspace_root, a different result shape — and are not handled here;
  # see CLAUDE.md's "Ruby intelligence: ruby-lsp" section for why the two
  # conventions live side by side.
  #
  # +workspace_root+ is a Pathname, the same one EditorsController#workspace_root
  # resolves. This is the trust boundary every one of these methods sits on:
  # an in-workspace file:// URI becomes a workspace-relative path, anything
  # else is dropped — a reference in a gem is not something this editor can
  # open, and a path outside the root is not something it should hand to the
  # browser at all.
  module RubyLspResultTranslator
    module_function

    # Recursion bound for #raw: the payload comes from a subprocess, and a
    # cyclic or pathologically nested one must not take the request thread
    # down with it.
    MAX_LSP_DEPTH = 32

    URI_KEYS = %w[uri targetUri].freeze

    # URI::DEFAULT_PARSER became the RFC3986 parser in Ruby 4.0, where #unescape
    # is deprecated; URI::RFC2396_PARSER only exists from Ruby 3.4. The gem
    # supports >= 3.0, so take whichever this Ruby has.
    URI_UNESCAPER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

    LSP_COMPLETION_KINDS = {
      2 => "Method", 3 => "Function", 4 => "Constructor", 5 => "Field",
      6 => "Variable", 7 => "Class", 8 => "Interface", 9 => "Module",
      10 => "Property", 14 => "Keyword", 15 => "Snippet", 21 => "Constant"
    }.freeze

    # ruby-lsp renders its "Definitions" line as VS Code file links, e.g.
    # `[user.rb](file:///abs/path/user.rb#L3,1-9,4)`. Monaco renders those as
    # links but clicking one does nothing, since nothing can open a file:// URI
    # here. Point in-workspace links at the `mbeditor.openDefinition` Monaco
    # command (registered in editor_plugins.js) and demote gem/stdlib links —
    # which the editor cannot open at all — to plain code spans.
    LSP_HOVER_FILE_LINK = %r{\[([^\]\n]+)\]\(file://([^)\s#]+)(?:\#L(\d+),\d+(?:-\d+,\d+)?)?\)}

    def definition(result, workspace_root:)
      { results: translate_lsp_locations(result, workspace_root) }
    end

    def hover(result, workspace_root:)
      { markdown: translate_lsp_hover(result, workspace_root) }
    end

    def completion(result)
      { suggestions: translate_lsp_completions(result) }
    end

    # The one trust boundary for every raw-passthrough method (references,
    # documentHighlight, documentSymbol, foldingRange, formatting,
    # signatureHelp, selectionRange, prepareRename). Walks the LSP response and
    # rewrites each file:// URI to a workspace-relative path, dropping any
    # object that points outside the workspace.
    def raw(result, workspace_root:)
      { result: sanitize_lsp_uris(result, workspace_root) }
    end

    def sanitize_lsp_uris(node, workspace_root, depth = 0)
      return nil if depth > MAX_LSP_DEPTH

      case node
      when Array
        node.filter_map { |child| sanitize_lsp_uris(child, workspace_root, depth + 1) }
      when Hash
        sanitized = {}
        node.each do |key, value|
          if URI_KEYS.include?(key) && value.is_a?(String)
            rel = workspace_relative_uri(value, workspace_root)
            # A URI we can't place inside the workspace disqualifies its object.
            return nil unless rel

            sanitized[key] = rel
          else
            child = sanitize_lsp_uris(value, workspace_root, depth + 1)
            sanitized[key] = child unless child.nil? && !value.nil?
          end
        end
        sanitized
      when String
        sanitize_lsp_markdown(node, workspace_root)
      else
        node
      end
    end

    # URIs also turn up *inside* strings: ruby-lsp's signatureHelp and hover
    # documentation embed a "Definitions" line of file:// markdown links. Those
    # would leak absolute host paths and render as links that go nowhere, so
    # they get the same treatment hover already gives them.
    def sanitize_lsp_markdown(text, workspace_root)
      return text unless text.include?("file://")

      rewritten = rewrite_lsp_hover_links(text, workspace_root)
      return rewritten unless rewritten.include?("file://")

      # Backstop for any file:// URI that wasn't in markdown-link form. An
      # absolute host path must never reach the browser, linkable or not.
      rewritten.gsub(%r{file://\S*}) do |raw|
        workspace_relative_uri(raw.sub(/[)\]\s].*\z/m, ""), workspace_root) || "(external)"
      end
    end

    def workspace_relative_uri(uri, workspace_root)
      return nil unless uri.start_with?("file://")

      # ruby-lsp percent-escapes its URIs; workspace_root is a raw path. A
      # checkout with a space (or any other escaped character) in its path
      # matched nothing here, so every result was silently dropped.
      path = URI_UNESCAPER.unescape(uri.delete_prefix("file://"))
      prefix = "#{workspace_root}/"
      return nil unless path.start_with?(prefix)

      path.delete_prefix(prefix)
    end

    def translate_lsp_locations(result, workspace_root)
      items = result.is_a?(Array) ? result : [result].compact
      root = workspace_root.to_s
      items.filter_map do |loc|
        next unless loc.is_a?(Hash)

        uri   = loc["uri"] || loc["targetUri"]
        range = loc["range"] || loc["targetSelectionRange"] || loc["targetRange"]
        next unless uri.to_s.start_with?("file://")

        fpath = URI_UNESCAPER.unescape(uri.delete_prefix("file://"))
        # Drop gem/stdlib locations the editor can't open; an empty list makes
        # the frontend fall back to the legacy services (ri covers stdlib).
        next unless fpath.start_with?("#{root}/")

        start_line = (range&.dig("start", "line") || 0) + 1
        {
          file: fpath.delete_prefix("#{root}/"),
          line: start_line,
          # Columns and the end of the range are additive: existing consumers
          # only read :file and :line, but peek-definition needs a real range
          # to highlight rather than the start of the line.
          col: (range&.dig("start", "character") || 0) + 1,
          endLine: (range&.dig("end", "line") || range&.dig("start", "line") || 0) + 1,
          endCol: (range&.dig("end", "character") || range&.dig("start", "character") || 0) + 1
        }
      end
    end

    def translate_lsp_hover(result, workspace_root)
      contents = result.is_a?(Hash) ? result["contents"] : nil
      return nil if contents.nil?

      markdown =
        case contents
        when Hash  then contents["value"].to_s
        when Array then contents.map { |c| c.is_a?(Hash) ? c["value"].to_s : c.to_s }.join("\n\n")
        else contents.to_s
        end

      neutralize_comment_headings(rewrite_lsp_hover_links(markdown, workspace_root))
    end

    # ruby-lsp renders a doc comment by stripping exactly one leading "# " from
    # each line, then hands the result to the editor as markdown. A `##`-opened
    # doc block — a very common Ruby convention — therefore arrives as
    # "# Title" and renders as an <h1> filling the hover.
    #
    # Ruby comments are not markdown, so escape a `#` that opens a line and let
    # it render as the text it is. Fenced code blocks are left alone: `#` inside
    # them is Ruby source, not a heading, and needs no escaping.
    #
    # This deliberately diverges from other ruby-lsp clients, which show the
    # heading.
    def neutralize_comment_headings(markdown)
      in_fence = false
      markdown.lines.map do |line|
        in_fence = !in_fence if line.start_with?("```")
        next line if in_fence || line.start_with?("```")

        line.sub(/\A(\s*)(#+)(?=\s|\z)/) { "#{Regexp.last_match(1)}\\#{Regexp.last_match(2)}" }
      end.join
    end

    def rewrite_lsp_hover_links(markdown, workspace_root)
      prefix = "#{workspace_root}/"
      markdown.gsub(LSP_HOVER_FILE_LINK) do
        label, raw_path, line = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3).to_i
        # Percent-decode by hand: URI's unescape helpers are deprecated on new
        # Rubies and their replacements are missing on the old ones we support.
        # (Must come after reading the other captures — gsub resets last_match.)
        path = raw_path.gsub(/%\h\h/) { |esc| esc[1..].hex.chr }.force_encoding(Encoding::UTF_8)

        if path.start_with?(prefix)
          args = [path.delete_prefix(prefix), line.positive? ? line : 1]
          "[#{label}](command:mbeditor.openDefinition?#{ERB::Util.url_encode(args.to_json)})"
        else
          "`#{label}`"
        end
      end
    end

    def translate_lsp_completions(result)
      items = result.is_a?(Hash) ? Array(result["items"]) : Array(result)
      items.first(100).filter_map do |item|
        next unless item.is_a?(Hash)

        {
          label: item["label"].to_s,
          kind: lsp_completion_kind(item["kind"]),
          insertText: (item.dig("textEdit", "newText") || item["insertText"] || item["label"]).to_s,
          detail: item["detail"].to_s,
          isSnippet: item["insertTextFormat"] == 2
        }
      end
    end

    def lsp_completion_kind(kind)
      LSP_COMPLETION_KINDS[kind] || "Text"
    end
  end
end
