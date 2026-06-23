# frozen_string_literal: true

require "test_helper"
require "open3"

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

    # ── real EditorStateService validation paths (unstubbed) ───────────────────

    test "save_state writes to a real tmp workspace that read_state round-trips" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe
        perform :save_state, "state" => { "openTabs" => ["foo.rb"] }

        persisted = EditorStateService.new(Pathname.new(dir)).read_state
        assert_equal ["foo.rb"], persisted["openTabs"]
      end
    end

    test "save_state rejects an oversized payload without writing over existing state" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        service = EditorStateService.new(Pathname.new(dir))
        service.write_state({ "openTabs" => ["keep.rb"] })

        subscribe
        oversized = { "x" => "y" * (EditorStateService::STATE_MAX_BYTES + 1) }
        assert_nothing_raised { perform :save_state, "state" => oversized }

        assert_equal ["keep.rb"], service.read_state["openTabs"],
          "an oversized payload (real PayloadTooLargeError) must not clobber existing state"
      end
    end

    test "save_branch_state rejects an invalid branch name without writing the branch states file" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe
        assert_nothing_raised do
          perform :save_branch_state, "branch" => "bad name!", "state" => { "x" => 1 }
        end

        branch_file = Pathname.new(dir).join("tmp", "mbeditor_branch_states.json")
        refute File.exist?(branch_file),
          "an invalid branch name (real InvalidBranchError) must not be persisted"
      end
    end

    test "save_branch_state logs a warning when an invalid branch name is rejected" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe

        warnings = capture_logger_warnings do
          perform :save_branch_state, "branch" => "bad name!", "state" => { "x" => 1 }
        end

        assert warnings.any? { |m| m.include?("[mbeditor]") },
          "rejecting an invalid branch name should be observable via a logged warning"
      end
    end

    test "save_branch_state rejection warning names the offending branch" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe

        warnings = capture_logger_warnings do
          perform :save_branch_state, "branch" => "bad name!", "state" => { "x" => 1 }
        end

        assert warnings.any? { |m| m.include?("bad name!") },
          "the warning should name the rejected branch so misconfiguration is diagnosable"
      end
    end

    test "save_branch_state does not log a warning for a valid branch name" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe

        warnings = capture_logger_warnings do
          perform :save_branch_state, "branch" => "feature/ok", "state" => { "x" => 1 }
        end

        assert_empty warnings,
          "a valid branch name must not produce a rejection warning (no false positives)"
      end
    end

    test "save_branch_state writes to a real tmp workspace that read_branch_state round-trips" do
      Dir.mktmpdir do |dir|
        Mbeditor.configure { |c| c.workspace_root = dir }
        subscribe
        perform :save_branch_state, "branch" => "feature/x", "state" => { "panes" => ["a.rb"] }

        persisted = EditorStateService.new(Pathname.new(dir)).read_branch_state("feature/x")
        assert_equal ["a.rb"], persisted["panes"]
      end
    end

    # ── workspace_root caching ─────────────────────────────────────────────────

    test "computes the git toplevel only once across multiple actions when workspace_root is unconfigured" do
      Mbeditor.configure { |c| c.workspace_root = nil }
      subscribe

      fake_service = Object.new
      fake_service.define_singleton_method(:write_state) { |_| }

      git_calls = count_git_rev_parse do
        with_fake_editor_state_service(fake_service) do
          perform :save_state, state: { x: 1 }
          perform :save_state, state: { y: 2 }
        end
      end

      assert_equal 1, git_calls,
        "git rev-parse should run once and then be served from the class-level cache"
    end

    test "reuses the cached git toplevel across different action types" do
      Mbeditor.configure { |c| c.workspace_root = nil }
      subscribe

      fake_service = Object.new
      fake_service.define_singleton_method(:write_state)        { |_| }
      fake_service.define_singleton_method(:write_branch_state) { |_, _| }

      git_calls = count_git_rev_parse do
        with_fake_editor_state_service(fake_service) do
          perform :save_state,        state: { x: 1 }
          perform :save_branch_state, branch: "main", state: { y: 2 }
        end
      end

      assert_equal 1, git_calls,
        "save_branch_state should reuse the toplevel cached by save_state"
    end

    private

    def teardown
      # The cache lives in a class ivar; clear it so it doesn't leak between tests.
      Mbeditor::EditorChannel.instance_variable_set(:@workspace_root_cache, nil)
    end

    def workspace_root
      Pathname.new(@workspace)
    end

    def count_git_rev_parse
      count = 0
      original = Open3.method(:capture3)
      Open3.define_singleton_method(:capture3) do |*args|
        count += 1 if args.include?("rev-parse")
        original.call(*args)
      end
      yield
      count
    ensure
      Open3.define_singleton_method(:capture3, original)
    end

    def capture_logger_warnings
      warnings = []
      capturer = Object.new
      capturer.define_singleton_method(:warn) { |msg = nil, &blk| warnings << (msg || blk&.call).to_s }
      capturer.define_singleton_method(:method_missing) { |*| nil }
      capturer.define_singleton_method(:respond_to_missing?) { |*| true }

      original_logger = Rails.logger
      Rails.logger = capturer
      yield
      warnings
    ensure
      Rails.logger = original_logger
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
