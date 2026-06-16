# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  # End-to-end coverage for the Rails log viewer: a line written to the active
  # environment's log file must show up in the bottom log drawer once it is
  # toggled open.
  class LogViewerSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_log_")
      File.write(File.join(@workspace, "README.md"), "# Hello\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      Capybara.reset_sessions!
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    test "opening the log panel shows freshly logged lines" do
      marker = "LOGVIEWER-MARKER-#{SecureRandom.hex(4)}"

      # The viewer tails Rails.root/log/<env>.log, so emit the marker both via the
      # logger and straight to that file to guarantee it is present on disk
      # regardless of the test-env logger configuration.
      log_path = Rails.root.join("log", "#{Rails.env}.log")
      Rails.logger.info(marker)
      Rails.logger.flush if Rails.logger.respond_to?(:flush)
      File.write(log_path, "#{marker}\n", mode: "a")

      visit "/mbeditor"
      assert_selector ".statusbar-btn", wait: 15

      find(".statusbar-btn[title^='Toggle Rails log']").click
      assert_selector ".ide-log-drawer", wait: 10
      assert_text marker, wait: 10
    end
  end
end
