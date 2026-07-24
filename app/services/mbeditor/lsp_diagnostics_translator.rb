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
    SEVERITIES = { 1 => "error", 2 => "warning", 3 => "info", 4 => "info" }.freeze

    # ruby-lsp appends this to non-correctable RuboCop messages; it's noise in
    # a Monaco hover.
    UNCORRECTABLE_SUFFIX = "This offense is not auto-correctable."

    def call(result)
      items = case result
              when Hash  then Array(result["items"])
              when Array then result
              else []
              end

      markers = items.filter_map { |diag| translate_one(diag) }
      { markers: markers, summary: { "offense_count" => markers.length } }
    end

    def translate_one(diag)
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
        endLine: end_line, endCol: end_col
      }
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
