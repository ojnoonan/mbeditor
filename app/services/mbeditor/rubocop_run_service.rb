# frozen_string_literal: true

require "json"
require "tmpdir"

module Mbeditor
  # Whole-workspace `rubocop` run — the counterpart to the per-buffer /lint
  # endpoint, which can only report on files Monaco already has open.
  #
  # `-a` (safe autocorrect) rather than `-A`: unsafe corrections can change
  # behaviour, and this runs over every file in the project at once, so an
  # unreviewed `-A` is a much bigger blast radius than the per-buffer quick fix.
  module RubocopRunService
    module_function

    def run(workspace_root, mode: :check, timeout: 300)
      matcher = ExclusionMatcher.new(Mbeditor.configuration.excluded_paths, root: workspace_root)
      cmd = AvailabilityProbe.rubocop_command(workspace_root) +
            [AvailabilityProbe.rubocop_server_flag(workspace_root), "--format", "json", "--no-color"]
      cmd << "-a" if mode.to_sym == :autocorrect

      result = ProcessRunner.call(
        cmd,
        timeout: timeout,
        chdir: workspace_root.to_s,
        env: { "RUBOCOP_CACHE_ROOT" => File.join(Dir.tmpdir, "rubocop") }
      )
      parse(result[:stdout], result[:stderr], matcher)
    rescue ProcessRunner::TimeoutError
      error("RuboCop timed out after #{timeout}s")
    rescue StandardError => e
      error(e.message)
    end

    # RuboCop writes its JSON to stdout, but anything the host app prints while
    # loading (a deprecation warning, a bundler notice) lands in front of it —
    # hence the seek to the first brace, same as the /lint path.
    # +matcher+ drops offenses in paths the workspace excludes — vendored gems
    # above all. RuboCop's own defaults exclude `vendor/**/*`, but a host
    # .rubocop.yml that sets AllCops/Exclude without `inherit_mode: merge`
    # silently replaces them, and the panel then fills with gem source.
    #
    # ponytail: filtered after the fact, so a host in that state still pays for
    # the walk. Generate a config that inherits from theirs and re-adds the
    # excludes if the run time ever becomes the complaint.
    def parse(stdout, stderr = nil, matcher = nil)
      idx = stdout.index("{")
      return error(stderr.to_s.strip.split("\n").last || "RuboCop produced no output") unless idx

      data = JSON.parse(stdout[idx..])
      files = (data["files"] || []).filter_map do |file|
        next if matcher&.excluded?(file["path"].to_s)

        offenses = file["offenses"] || []
        next if offenses.empty?

        { path: file["path"], offenses: offenses.map { |o| offense(o) } }
      end

      {
        ok: true,
        files: files.sort_by { |f| f[:path].to_s },
        summary: data["summary"] || {},
        correctable: files.sum { |f| f[:offenses].count { |o| o[:correctable] } }
      }
    rescue JSON::ParserError => e
      error(e.message)
    end

    def offense(o)
      {
        copName: o["cop_name"],
        message: o["message"],
        severity: o["severity"],
        correctable: o["correctable"] == true,
        corrected: o["corrected"] == true,
        line: o.dig("location", "start_line") || o.dig("location", "line") || 1,
        column: o.dig("location", "start_column") || o.dig("location", "column") || 1
      }
    end

    def error(message)
      { ok: false, error: message, files: [], summary: {}, correctable: 0 }
    end
  end
end
