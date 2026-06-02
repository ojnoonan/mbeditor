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

    test "save_state delegates to EditorStateService#write_state with the correct payload" do
      subscribe
      received_state = nil
      fake_service = Object.new
      fake_service.define_singleton_method(:write_state) { |s| received_state = s }

      with_fake_editor_state_service(fake_service) do
        perform :save_state, "state" => { "openTabs" => ["foo.rb"] }
      end

      assert_equal ["foo.rb"], received_state["openTabs"]
    end

    test "save_state does not raise when EditorStateService raises" do
      subscribe
      write_state_called = false
      fake_service = Object.new
      fake_service.define_singleton_method(:write_state) { |_| write_state_called = true; raise "boom" }

      with_fake_editor_state_service(fake_service) do
        assert_nothing_raised { perform :save_state, state: { x: 1 } }
      end

      assert write_state_called, "EditorStateService#write_state should have been called"
    end

    # ── save_branch_state ──────────────────────────────────────────────────────

    test "save_branch_state delegates to EditorStateService#write_branch_state with correct branch and state" do
      subscribe
      received_branch = nil
      received_state  = nil
      fake_service = Object.new
      fake_service.define_singleton_method(:write_branch_state) { |b, s| received_branch = b; received_state = s }

      with_fake_editor_state_service(fake_service) do
        perform :save_branch_state, "branch" => "main", "state" => { "panes" => [] }
      end

      assert_equal "main", received_branch
      assert_equal [], received_state["panes"]
    end

    test "save_branch_state does not raise when EditorStateService raises" do
      subscribe
      write_branch_state_called = false
      fake_service = Object.new
      fake_service.define_singleton_method(:write_branch_state) do |_, _|
        write_branch_state_called = true
        raise "boom"
      end

      with_fake_editor_state_service(fake_service) do
        assert_nothing_raised { perform :save_branch_state, branch: "main", state: {} }
      end

      assert write_branch_state_called, "EditorStateService#write_branch_state should have been called"
    end

    private

    def workspace_root
      Pathname.new(@workspace)
    end

    def with_fake_editor_state_service(fake_service)
      original_new = EditorStateService.method(:new)
      EditorStateService.define_singleton_method(:new) { |*| fake_service }
      yield
    ensure
      EditorStateService.define_singleton_method(:new, original_new)
    end
  end
end
