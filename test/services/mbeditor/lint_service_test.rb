# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # LintService.rubocop_diagnostics/haml_diagnostics/autocorrect spawn real
  # rubocop/haml-lint subprocesses and are already covered end-to-end by
  # editors_controller_test.rb's lint/quick_fix/format_file tests (which
  # exercise the real toolchain, matching this codebase's existing convention
  # of not mocking subprocess execution). Duplicating that here would mean a
  # second real subprocess invocation for the same coverage. This file covers
  # what's actually unit-shaped: the pure severity mappers and the env helper.
  class LintServiceTest < ActiveSupport::TestCase
    test "cop_severity maps rubocop severities into the marker severity domain" do
      assert_equal "error",   LintService.cop_severity("error")
      assert_equal "error",   LintService.cop_severity("fatal")
      assert_equal "warning", LintService.cop_severity("warning")
      assert_equal "hint",    LintService.cop_severity("info")
      assert_equal "info",    LintService.cop_severity("convention")
      assert_equal "info",    LintService.cop_severity("refactor")
      assert_equal "info",    LintService.cop_severity(nil)
    end

    test "haml_lint_severity maps error and warning, and degrades everything else to info" do
      assert_equal "error",   LintService.haml_lint_severity("error")
      assert_equal "warning", LintService.haml_lint_severity("warning")
      assert_equal "info",    LintService.haml_lint_severity("info")
      assert_equal "info",    LintService.haml_lint_severity(nil)
      assert_equal "info",    LintService.haml_lint_severity("something-unknown")
    end

    test "rubocop_env points RUBOCOP_CACHE_ROOT at a rubocop subdirectory of the system tmpdir" do
      env = LintService.rubocop_env
      assert_equal File.join(Dir.tmpdir, "rubocop"), env["RUBOCOP_CACHE_ROOT"]
    end
  end
end
