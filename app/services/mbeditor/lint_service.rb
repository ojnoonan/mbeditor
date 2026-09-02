# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require "json"

module Mbeditor
  # The module CONTEXT.md's glossary already names: mbeditor's linting
  # toolchain, rubocop (diagnostics via --stdin; autocorrect via a
  # workspace-local tempfile so rubocop's config discovery finds the host
  # app's .rubocop.yml) and haml-lint (diagnostics only). Every subprocess
  # runs through ProcessRunner.
  #
  # Diagnostics come back Monaco-marker-shaped (startLine/copName/…) rather
  # than as a neutral intermediate — matching LspDiagnosticsTranslator, the
  # sibling module for ruby-lsp diagnostics, which does the same. Client-side
  # JS linting (JsSyntaxCheckService) and the Monaco-edit shaping in
  # EditorsController#compute_text_edit are presentation-layer concerns and
  # stay out of this module.
  module LintService
    module_function

    def rubocop_diagnostics(workspace_root, path, code)
      cmd = AvailabilityProbe.rubocop_command(workspace_root) +
            [AvailabilityProbe.rubocop_server_flag(workspace_root), "--stdin", path.to_s, "--format", "json", "--no-color"]
      output = run(cmd, env: rubocop_env, stdin_data: code)[:stdout]

      idx = output.index("{")
      result = idx ? JSON.parse(output[idx..]) : {}
      result = {} unless result.is_a?(Hash)
      offenses = result.dig("files", 0, "offenses") || []

      markers = offenses.map do |offense|
        {
          severity: cop_severity(offense["severity"]),
          copName: offense["cop_name"],
          correctable: offense["correctable"] == true,
          message: "[#{offense['cop_name']}] #{offense['message']}",
          startLine: offense.dig("location", "start_line") || offense.dig("location", "line"),
          startCol: offense.dig("location", "start_column") || offense.dig("location", "column") || 1,
          endLine: offense.dig("location", "last_line") || offense.dig("location", "line"),
          endCol: offense.dig("location", "last_column") || offense.dig("location", "column") || 1,
          # Same predicate the ruby-lsp path uses, so dead code fades whichever
          # linter produced the offense. Plain rubocop JSON carries no
          # code_description, so there's no codeHref to pass on here.
          unnecessary: LspDiagnosticsTranslator.unnecessary?(offense["cop_name"])
        }
      end

      { markers: markers, summary: result["summary"] }
    end

    def haml_diagnostics(workspace_root, code)
      markers = []
      Tempfile.create(["mbeditor_haml", ".haml"]) do |f|
        f.write(code)
        f.flush
        cmd = AvailabilityProbe.haml_lint_command(workspace_root) + ["--reporter", "json", "--no-color", f.path]
        output = run(cmd)[:stdout]
        idx = output.index("{")
        result = idx ? JSON.parse(output[idx..]) : {}
        result = {} unless result.is_a?(Hash)
        offenses = result.dig("files", 0, "offenses") || []
        markers = offenses.map do |offense|
          {
            severity: haml_lint_severity(offense["severity"]),
            message: "[#{offense['linter_name']}] #{offense['message']}",
            startLine: offense.dig("location", "line"),
            startCol: (offense.dig("location", "column") || 1) - 1,
            endLine: offense.dig("location", "line"),
            endCol: offense.dig("location", "column") || 1
          }
        end
      end
      markers
    end

    # Runs a full `rubocop -A` pass on +code+ (not the file on disk) via a
    # workspace-local tempfile, and reports whether the pass completed.
    # +ok: false+ means rubocop itself failed (exit status neither 0 nor 1),
    # not that no offense was found — callers that care about an actual diff
    # compare +content+ against the code they passed in.
    def autocorrect(workspace_root, path, code)
      ext = File.extname(File.basename(path))
      Tempfile.create([".mbeditor_autocorrect_", ext], File.dirname(path)) do |f|
        f.write(code)
        f.flush
        tmpfile = f.path

        cmd = AvailabilityProbe.rubocop_command(workspace_root) +
              [AvailabilityProbe.rubocop_server_flag(workspace_root), "-A", "--no-color", tmpfile]
        status = run(cmd, env: rubocop_env)[:exit_status]

        # exit 0 = no offenses, exit 1 = offenses corrected, exit 2 = error
        next { ok: false, content: code } unless status.success? || status.exitstatus == 1

        corrected = File.read(tmpfile, encoding: "UTF-8", invalid: :replace, undef: :replace)
        { ok: true, content: corrected }
      end
    end

    # Kept in step with LspDiagnosticsTranslator::SEVERITIES so a file linted
    # through ruby-lsp and the same file linted through `rubocop --stdin` grade
    # their offenses identically. rubocop's own `info` is the weakest level and
    # maps to hint; convention/refactor fall through to info.
    def cop_severity(severity)
      case severity
      when "error", "fatal" then "error"
      when "warning" then "warning"
      when "info" then "hint"
      else "info"
      end
    end

    def haml_lint_severity(severity)
      case severity
      when "error" then "error"
      when "warning" then "warning"
      else "info"
      end
    end

    def rubocop_env
      { "RUBOCOP_CACHE_ROOT" => File.join(Dir.tmpdir, "rubocop") }
    end

    # Same lint_timeout ceiling for every subprocess this module runs.
    # quick_fix, format_file and haml-lint used to spawn with Open3.capture3
    # and no timeout at all, so a wedged rubocop held a request thread until
    # the client gave up.
    def run(cmd, env: {}, stdin_data: nil)
      timeout_seconds = Mbeditor.configuration.lint_timeout&.to_i
      timeout = timeout_seconds && timeout_seconds > 0 ? timeout_seconds : nil
      ProcessRunner.call(cmd, timeout: timeout, env: env, stdin_data: stdin_data)
    end
  end
end
