# frozen_string_literal: true

module Mbeditor
  # Translates an LSP DocumentDiagnosticReport into the marker shape the editor
  # already uses for RuboCop offenses, so ruby-lsp diagnostics flow through the
  # existing pipeline (markers state -> setModelMarkers -> quick-fix lightbulbs)
  # with no frontend changes beyond honouring `source`.
  #
  # LSP ranges are 0-based; editor markers are 1-based.
  module LspDiagnosticsTranslator
    module_function

    # LSP DiagnosticSeverity -> the severity strings cop_severity also emits.
    # Mirrors ruby-lsp's own RUBOCOP_TO_LSP_SEVERITY in reverse: rubocop's
    # `info` becomes HINT(4) and convention/refactor become INFORMATION(3), so
    # the two must map back to distinct editor severities.
    SEVERITIES = { 1 => "error", 2 => "warning", 3 => "info", 4 => "hint" }.freeze

    # ruby-lsp appends this to non-correctable RuboCop messages; it's noise in
    # a Monaco hover.
    UNCORRECTABLE_SUFFIX = "This offense is not auto-correctable."

    # Cops whose offense means "this code does nothing" rather than "this code
    # is wrong". Monaco fades these out (MarkerTag.Unnecessary) instead of
    # squiggling them, which is the whole point of greying out dead code.
    #
    # ruby-lsp emits no DiagnosticTag of its own, so the cop name is the only
    # signal available — and it's the same signal on the plain-rubocop /lint
    # path, which is why this predicate is public and shared by both.
    #
    # ponytail: name heuristic, not an enumeration. Upgrade path is an explicit
    # cop list if a badly-named cop ever gets faded by mistake.
    UNNECESSARY_COP = /Unused|Useless|Redundant|Unreachable|Deprecat/.freeze

    # Prism reports the same dead code as Lint/UselessAssignment and
    # Lint/UnreachableCode, but as a parser warning with no cop name — so both
    # markers land on the same range. Fading only the RuboCop one leaves the
    # Prism squiggle drawn on top and nothing looks greyed out at all.
    UNNECESSARY_MESSAGE = /\Aassigned but unused variable|\Astatement not reached|\Aunused literal/.freeze

    # Most actions a diagnostic can carry. RuboCop sends two (autocorrect and
    # disable-for-this-line); the cap is a bound on a payload we don't control.
    MAX_CODE_ACTIONS = 5

    # Refuse to ship an absurd replacement into the browser. RuboCop's
    # replacements are a few characters; anything near this is a bug or an
    # attack, not a quick fix.
    MAX_EDIT_BYTES = 64 * 1024

    # +uri+ is the request's own document URI. Code actions are only accepted
    # when every edit they carry targets exactly that document — see
    # sanitize_code_actions.
    def call(result, uri = nil)
      items = case result
              when Hash  then Array(result["items"])
              when Array then result
              else []
              end

      markers = items.filter_map { |diag| translate_one(diag, uri) }
      { markers: markers, summary: { "offense_count" => markers.length } }
    end

    def translate_one(diag, uri = nil)
      return nil unless diag.is_a?(Hash)

      range      = diag["range"] || {}
      start_line = (range.dig("start", "line") || 0) + 1
      start_col  = (range.dig("start", "character") || 0) + 1
      end_line   = (range.dig("end", "line") || range.dig("start", "line") || 0) + 1
      end_col    = (range.dig("end", "character") || range.dig("start", "character") || 0) + 1
      end_line   = start_line if end_line < start_line
      end_col    = start_col + 1 if end_line == start_line && end_col <= start_col

      cop_name = extract_code(diag["code"])
      message  = clean_message(diag["message"])
      fixes    = sanitize_code_actions(diag, uri)

      {
        severity: SEVERITIES.fetch(diag["severity"], "info"),
        copName: cop_name,
        correctable: diag.dig("data", "correctable") == true,
        # Only RuboCop-sourced markers may claim the 'rubocop' source: the
        # quick-fix provider filters on it and sends copName to /quick_fix,
        # which runs `rubocop -A`. A Prism syntax error must not get a
        # lightbulb that can't fix anything.
        source: rubocop_source?(diag["source"]) ? "rubocop" : diag["source"].to_s.downcase,
        message: cop_name.empty? ? message : "[#{cop_name}] #{message}",
        startLine: start_line, startCol: start_col,
        endLine: end_line, endCol: end_col,
        unnecessary: unnecessary?(cop_name, message),
        # RuboCop >= 1.64 ships a docs URL per cop; Monaco renders it as a link
        # on the marker's code. Absent for non-RuboCop diagnostics.
        # NB: the LSP wire key is camelCase.
        codeHref: diag.dig("codeDescription", "href")
      }.tap { |marker| marker[:fixes] = fixes if fixes.any? }
    end

    # ruby-lsp embeds the complete edits for each RuboCop fix in the diagnostic
    # itself. Its textDocument/codeAction handler does nothing but echo these
    # back (see Requests::CodeActions#perform), so lifting them here lets the
    # editor apply a fix with no further request at all -- no codeAction call
    # and no `rubocop -A` subprocess.
    #
    # This is a trust boundary: the payload arrives from a subprocess and is
    # applied to the user's buffer. An action is taken only if every edit in it
    # targets the very document we asked about.
    def sanitize_code_actions(diag, uri)
      return [] if uri.nil?

      Array(diag.dig("data", "code_actions")).first(MAX_CODE_ACTIONS).filter_map do |action|
        next unless action.is_a?(Hash)

        changes = Array(action.dig("edit", "documentChanges"))
        next if changes.empty?
        # Any edit aimed at another file disqualifies the whole action. RuboCop
        # fixes are always single-file, so this rejects nothing legitimate.
        next unless changes.all? { |c| c.is_a?(Hash) && c.dig("textDocument", "uri") == uri }

        edits = changes.flat_map { |c| Array(c["edits"]) }.filter_map { |edit| sanitize_edit(edit) }
        next if edits.empty?

        { title: action["title"].to_s, edits: edits }
      end
    end

    # One LSP TextEdit -> the 1-based shape the rest of the marker uses.
    def sanitize_edit(edit)
      return nil unless edit.is_a?(Hash)

      text = edit["newText"].to_s
      return nil if text.bytesize > MAX_EDIT_BYTES

      range = edit["range"]
      return nil unless range.is_a?(Hash)

      {
        startLine: (range.dig("start", "line") || 0) + 1,
        startCol:  (range.dig("start", "character") || 0) + 1,
        endLine:   (range.dig("end", "line") || range.dig("start", "line") || 0) + 1,
        endCol:    (range.dig("end", "character") || range.dig("start", "character") || 0) + 1,
        text: text
      }
    end

    def unnecessary?(cop_name, message = nil)
      return true if UNNECESSARY_COP.match?(cop_name.to_s)

      # Only consult the message when there is no cop to go on, so a RuboCop
      # offense is never faded because of a phrase inside its description.
      cop_name.to_s.empty? && UNNECESSARY_MESSAGE.match?(message.to_s)
    end

    def rubocop_source?(source)
      source.to_s.match?(/rubocop/i)
    end

    def extract_code(code)
      case code
      when Hash then code["value"].to_s
      when nil  then ""
      else code.to_s
      end
    end

    def clean_message(message)
      message.to_s.sub(UNCORRECTABLE_SUFFIX, "").strip
    end
  end
end
