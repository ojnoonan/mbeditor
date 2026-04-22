# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class EditorChannelTest < ActionCable::Channel::TestCase
    tests Mbeditor::EditorChannel

    def setup
      @workspace = File.expand_path("../../..", __dir__)
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
      end
    end

    test "subscribes and streams from mbeditor_editor" do
      subscribe
      assert subscription.confirmed?
      assert_has_stream "mbeditor_editor"
    end

    test "unsubscribing does not raise" do
      subscribe
      assert_nothing_raised { unsubscribe }
    end

    # ── save_state ─────────────────────────────────────────────────────────────

    test "save_state writes workspace state to disk" do
      subscribe
      state_dir = workspace_root.join("tmp")
      FileUtils.mkdir_p(state_dir)

      perform :save_state, state: { openTabs: ["foo.rb"] }

      path = workspace_root.join("tmp", "mbeditor_workspace.json")
      assert File.exist?(path), "mbeditor_workspace.json should be written"
      data = JSON.parse(File.read(path))
      assert_equal ["foo.rb"], data["openTabs"]
    ensure
      File.delete(workspace_root.join("tmp", "mbeditor_workspace.json")) rescue nil
    end

    test "save_state silently ignores oversized payloads" do
      subscribe
      big = { data: "x" * (Mbeditor::EditorChannel::STATE_MAX_BYTES + 1) }
      assert_nothing_raised { perform :save_state, state: big }
    end

    # ── save_branch_state ──────────────────────────────────────────────────────

    test "save_branch_state writes branch state to disk" do
      subscribe
      FileUtils.mkdir_p(workspace_root.join("tmp"))

      perform :save_branch_state, branch: "main", state: { panes: [] }

      path = workspace_root.join("tmp", "mbeditor_branch_states.json")
      assert File.exist?(path), "mbeditor_branch_states.json should be written"
      data = JSON.parse(File.read(path))
      assert data.key?("main")
      assert_equal [], data["main"]["panes"]
    ensure
      File.delete(workspace_root.join("tmp", "mbeditor_branch_states.json")) rescue nil
    end

    test "save_branch_state rejects invalid branch names" do
      subscribe
      assert_nothing_raised { perform :save_branch_state, branch: "bad name!", state: {} }
      path = workspace_root.join("tmp", "mbeditor_branch_states.json")
      assert_not File.exist?(path), "should not create state file for invalid branch"
    end

    private

    def workspace_root
      Pathname.new(@workspace)
    end
  end
end
