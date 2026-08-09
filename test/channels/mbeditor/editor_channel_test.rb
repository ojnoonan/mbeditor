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
      # Process-wide registry: without this, one test's participants leak into the
      # next test's roster assertions.
      PresenceRegistry.reset!
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

    test "subscription is rejected when authenticate_with halts" do
      previous = Mbeditor.configuration.authenticate_with
      Mbeditor.configuration.authenticate_with = proc { head :forbidden }

      subscribe

      assert subscription.rejected?
      assert_no_streams
    ensure
      Mbeditor.configuration.authenticate_with = previous
    end

    # ── cable authentication ──────────────────────────────────────────────────

    # The failure that made pairing silently impossible: a hook reading state a
    # controller before_action populates sees nothing here, denies, and says
    # nothing about it.
    test "a hook denying on the cable is logged with a diagnosable reason" do
      previous = Mbeditor.configuration.authenticate_with
      Mbeditor.configuration.authenticate_with = proc { head :forbidden }
      Mbeditor::ChannelAuthentication.last_logged.clear
      captured = StringIO.new
      prev_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(captured)

      subscribe

      assert subscription.rejected?
      assert_includes captured.string, "WebSocket subscription rejected"
      assert_includes captured.string, "cable_authenticate_with"
    ensure
      Rails.logger = prev_logger if prev_logger
      Mbeditor.configuration.authenticate_with = previous
    end

    test "a hook raising on the cable is logged with the exception" do
      previous = Mbeditor.configuration.authenticate_with
      Mbeditor.configuration.authenticate_with = proc { Current.user.super_admin_access? }
      Mbeditor::ChannelAuthentication.last_logged.clear
      captured = StringIO.new
      prev_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(captured)

      subscribe

      assert subscription.rejected?
      assert_includes captured.string, "raised"
      assert_includes captured.string, "NameError"
    ensure
      Rails.logger = prev_logger if prev_logger
      Mbeditor.configuration.authenticate_with = previous
    end

    # The first version of this logging flooded the console: the client retries
    # every 30s, every tab retries independently, and both channels authenticate.
    test "repeated identical rejections are logged once, not once per retry" do
      Mbeditor.configuration.cable_authenticate_with = proc { head :forbidden }
      Mbeditor::ChannelAuthentication.last_logged.clear
      Mbeditor::ChannelAuthentication.last_logged.clear
      captured = StringIO.new
      prev_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(captured)

      5.times { subscribe }

      occurrences = captured.string.scan("WebSocket subscription rejected").length
      assert_equal 1, occurrences,
                   "expected one message for five identical rejections, got #{occurrences}"
    ensure
      Rails.logger = prev_logger if prev_logger
      Mbeditor.configuration.cable_authenticate_with = nil
      Mbeditor::ChannelAuthentication.last_logged.clear
    end

    test "a different rejection reason is still reported" do
      Mbeditor::ChannelAuthentication.last_logged.clear
      Mbeditor::ChannelAuthentication.last_logged.clear
      captured = StringIO.new
      prev_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(captured)

      Mbeditor.configuration.cable_authenticate_with = proc { head :forbidden }
      subscribe
      Mbeditor.configuration.cable_authenticate_with = proc { Current.user.super_admin_access? }
      subscribe

      assert_equal 2, captured.string.scan("WebSocket subscription rejected").length
    ensure
      Rails.logger = prev_logger if prev_logger
      Mbeditor.configuration.cable_authenticate_with = nil
      Mbeditor::ChannelAuthentication.last_logged.clear
    end

    test "cable_authenticate_with takes precedence over the HTTP hook" do
      previous = Mbeditor.configuration.authenticate_with
      # The HTTP hook cannot work here — exactly the real-world case.
      Mbeditor.configuration.authenticate_with = proc { Current.user.super_admin_access? }
      Mbeditor.configuration.cable_authenticate_with = proc { true }

      subscribe

      refute subscription.rejected?
      assert_has_stream "mbeditor_editor"
    ensure
      Mbeditor.configuration.authenticate_with = previous
      Mbeditor.configuration.cable_authenticate_with = nil
    end

    test "cable_authenticate_with can still deny" do
      Mbeditor.configuration.cable_authenticate_with = proc { head :forbidden }

      subscribe

      assert subscription.rejected?
      assert_no_streams
    ensure
      Mbeditor.configuration.cable_authenticate_with = nil
    end

    test "session is reachable from a cable hook, so a session-based check works" do
      Mbeditor.configuration.cable_authenticate_with = proc { head :forbidden if session.nil? }

      subscribe

      refute subscription.rejected?
    ensure
      Mbeditor.configuration.cable_authenticate_with = nil
    end

    # ── presence ─────────────────────────────────────────────────────────────

    test "presence broadcasts the whole roster, not just the sender" do
      PresenceRegistry.record("peer-9", {"name" => "Keen Hacker", "colour" => "#98c379",
                                        "current_file" => "app/models/order.rb"})
      subscribe

      perform :presence,
              "client_id"    => "abc123",
              "name"         => "Swift Otter",
              "colour"       => "#61afef",
              "current_file" => "app/models/user.rb"

      payload = broadcasts("mbeditor_editor").map { |m| ActiveSupport::JSON.decode(m) }.last
      assert_equal "presence", payload["type"]
      assert_equal %w[abc123 peer-9].sort, payload["roster"].keys.sort
      assert_equal "Swift Otter", payload["roster"]["abc123"]["name"]
      assert_equal "app/models/order.rb", payload["roster"]["peer-9"]["current_file"]
    end

    test "presence carries the sender's own measured rtt to peers" do
      subscribe

      perform :presence,
              "client_id"    => "abc123",
              "name"         => "Swift Otter",
              "colour"       => "#61afef",
              "current_file" => "app/models/user.rb",
              "rtt"          => 42

      payload = broadcasts("mbeditor_editor").map { |m| ActiveSupport::JSON.decode(m) }.last
      assert_equal 42, payload["roster"]["abc123"]["rtt"]
    end

    test "unsubscribing drops the participant from the broadcast roster" do
      subscribe
      perform :presence, "client_id" => "abc123", "name" => "Swift Otter", "current_file" => "a.rb"

      unsubscribe

      payload = broadcasts("mbeditor_editor").map { |m| ActiveSupport::JSON.decode(m) }.last
      assert_equal({}, payload["roster"])
    end

    # The whole point of a server-authoritative roster: a client that missed the
    # departure still gets a roster without the departed peer on the next change,
    # so a dropped message cannot leave a permanent phantom.
    test "a roster broadcast after a departure omits the departed peer" do
      PresenceRegistry.record("gone", {"name" => "Ghost", "current_file" => "a.rb"})
      PresenceRegistry.remove("gone")
      subscribe

      perform :presence, "client_id" => "abc123", "name" => "Swift Otter", "current_file" => "a.rb"

      payload = broadcasts("mbeditor_editor").map { |m| ActiveSupport::JSON.decode(m) }.last
      assert_equal %w[abc123], payload["roster"].keys
    end

    test "unsubscribing without a presence heartbeat broadcasts nothing" do
      subscribe

      assert_no_broadcasts("mbeditor_editor") do
        unsubscribe
      end
    end

    test "subscribing transmits the current roster to the joiner" do
      PresenceRegistry.record("peer-9", {"name" => "Keen Hacker", "current_file" => "app/models/order.rb"})

      subscribe

      payload = transmissions.last
      assert_equal "presence", payload["type"]
      assert_equal %w[peer-9], payload["roster"].keys
    end

    test "a presence relay failure does not crash the socket" do
      subscribe

      with_broadcasting_unavailable do
        assert_nothing_raised do
          perform :presence, "client_id" => "abc123", "name" => "Swift Otter", "current_file" => "a.rb"
        end
      end
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

    # ── log tail ───────────────────────────────────────────────────────────────

    test "push_log_lines transmits new lines only while watching" do
      subscribe
      fake = Object.new
      def fake.read_since(_offset)
        { lines: ["GET /things 200 OK"], offset: 42, reset: false }
      end

      with_fake_log_tail_service(fake) do
        # Not watching yet -> no log transmitted. Subscribing itself transmits the
        # presence roster, so assert on log messages rather than on there being no
        # transmissions at all.
        subscription.send(:push_log_lines)
        assert_empty transmissions.select { |m| m["type"] == "log" }

        subscription.start_log_tail("offset" => 0)
        subscription.send(:push_log_lines)
      end

      msg = transmissions.last
      assert_equal "log", msg["type"]
      assert_equal ["GET /things 200 OK"], msg["lines"]
      assert_equal 42, msg["offset"]

      subscription.stop_log_tail
      assert_equal false, subscription.instance_variable_get(:@log_watching)
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
      clear_workspace_root_cache!

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
      clear_workspace_root_cache!

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
      clear_workspace_root_cache!
      # Likewise the presence roster — a participant recorded here would otherwise
      # show up in another test's roster assertions.
      PresenceRegistry.reset!
    end

    # Clears the process-wide @workspace_root_cache on the *exact* channel class
    # the test harness instantiates. After a Rails code reload (which other test
    # files can trigger), the Mbeditor::EditorChannel constant points at a fresh
    # class object while the running subscription is still an instance of the
    # class captured by `tests Mbeditor::EditorChannel` at load time — so clearing
    # the constant alone leaves the instance's cache warm. Use subscription.class
    # when a subscription exists; fall back to the constant otherwise.
    def clear_workspace_root_cache!
      # The channel delegates to the shared WorkspaceRootResolver, so that is
      # where the memo lives now.
      Mbeditor::WorkspaceRootResolver.reset!
      channel_class = defined?(subscription) && subscription ? subscription.class : Mbeditor::EditorChannel
      channel_class.instance_variable_set(:@workspace_root_cache, nil)
    end

    def workspace_root
      Pathname.new(@workspace)
    end

    # Simulates ActionCable being unable to relay (server down / cable not mounted):
    # broadcasting raises, and the channel action must swallow it.
    def with_broadcasting_unavailable
      server = ActionCable.server
      original = server.method(:broadcast)
      server.define_singleton_method(:broadcast) { |*| raise "no cable" }
      yield
    ensure
      server.define_singleton_method(:broadcast, original)
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

    def with_fake_log_tail_service(fake_service)
      original_new = LogTailService.method(:new)
      LogTailService.define_singleton_method(:new) { |*| fake_service }
      yield
    ensure
      LogTailService.define_singleton_method(:new, original_new)
    end
  end
end
