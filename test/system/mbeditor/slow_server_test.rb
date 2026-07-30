# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  # Simulates using the editor against a slow server / slow network connection by
  # injecting per-request latency into the editor's API calls (see
  # test/dummy/lib/mbeditor_test_latency.rb). These tests assert the editor stays
  # usable and — crucially — that data is never lost, reverted, or duplicated
  # when responses arrive late.
  class SlowServerSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    README_PATH = "README.md"
    README_BODY = "# Hello\n"

    def setup
      @workspace = Dir.mktmpdir("mbeditor_slow_")
      File.write(File.join(@workspace, README_PATH), README_BODY)
      File.write(File.join(@workspace, "notes.txt"), "first line\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      MbeditorTestLatency.delay = 0.0
      Capybara.reset_sessions!
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    def open_file(name)
      all(".tree-item-name", text: name).first.click
      assert_selector ".monaco-editor", wait: 20
    end

    def set_editor_value(value)
      page.execute_script(<<~JS, value)
        var v = arguments[0];
        window.__mbeditorActiveEditor.focus();
        window.__mbeditorActiveEditor.setValue(v);
      JS
    end

    def editor_value
      page.evaluate_script("window.__mbeditorActiveEditor.getValue()")
    end

    # Under latency the file content arrives in the editor *after* the Monaco DOM
    # mounts, so poll until the buffer holds the expected value (or time out).
    def wait_for_editor_value(expected, timeout: 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        actual = editor_value
        return if actual == expected
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          assert_equal expected, actual, "editor buffer never loaded the expected content"
        end
        sleep 0.1
      end
    end

    # Count only the real editor tabs (the tab strip), not the OPEN EDITORS
    # sidebar list, which reuses the same item class.
    def tab_count_for(name)
      all(".tab-bar .tab-item-name", text: name, wait: 0).count
    end

    # ── tests ─────────────────────────────────────────────────────────────────

    test "editor boots and lists files even when every API request is slow" do
      MbeditorTestLatency.with(0.4) do
        visit "/mbeditor"
        # Boot fires several XHRs (workspace, tree, state, …), each delayed —
        # the editor must still come up, just later, so use a generous wait.
        assert_selector ".file-tree", wait: 25
        assert_text README_PATH, wait: 25
      end
    end

    test "opening a file against a slow server eventually shows its content" do
      MbeditorTestLatency.with(0.4) do
        visit "/mbeditor"
        assert_selector ".file-tree", wait: 25
        open_file(README_PATH)
        wait_for_editor_value(README_BODY)
      end
    end

    test "a slow save persists the edit to disk, reports Saved, and does not revert the buffer" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 15
      open_file(README_PATH)

      edited = "# Hello\nedited while the server is slow\n"
      set_editor_value(edited)
      assert_selector ".tab-item.active .tab-dirty-dot", wait: 5

      MbeditorTestLatency.with(0.8) do
        find("button.statusbar-btn", text: "Save", match: :first).click
        # Despite the slow round-trip, the save completes and the status settles
        # on "Saved" rather than hanging or erroring.
        assert_selector ".statusbar-msg", text: "Saved", wait: 25
      end

      # Data integrity: the edit reached disk, the live buffer was not reverted to
      # the on-disk-at-open content, and the dirty marker cleared.
      assert_equal edited, File.read(File.join(@workspace, README_PATH))
      assert_equal edited, editor_value
      assert_no_selector ".tab-item.active .tab-dirty-dot", wait: 10
    end

    test "a slow save does not duplicate the open tab" do
      # Use a plain-text file so the count isn't confused by the Markdown preview
      # tab that .md files open in the second pane.
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 15
      open_file("notes.txt")
      assert_equal 1, tab_count_for("notes.txt")

      set_editor_value("first line\nchanged line\n")
      assert_selector ".tab-item.active .tab-dirty-dot", wait: 5

      MbeditorTestLatency.with(0.8) do
        find("button.statusbar-btn", text: "Save", match: :first).click
        assert_selector ".statusbar-msg", text: "Saved", wait: 25
      end

      assert_equal 1, tab_count_for("notes.txt"),
                   "a single slow save must not leave the file open in two tabs"
    end

    test "switching files while requests are slow loads each file's own content" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 15

      MbeditorTestLatency.with(0.4) do
        open_file(README_PATH)
        wait_for_editor_value(README_BODY)

        open_file("notes.txt")
        wait_for_editor_value("first line\n")
      end
    end
  end
end
