# frozen_string_literal: true

require "test_helper"
require "digest"

module Mbeditor
  class CollaborationChannelTest < ActionCable::Channel::TestCase
    tests Mbeditor::CollaborationChannel

    def setup
      CollaborationDocStore.reset!
    end

    def teardown
      CollaborationDocStore.reset!
    end

    test "subscribing with a path streams the digest-keyed per-file stream" do
      subscribe path: "app/models/user.rb"

      assert subscription.confirmed?
      assert_has_stream stream_name_for("app/models/user.rb")
    end

    test "a fresh subscribe transmits the cached snapshot and buffered deltas" do
      path = "app/models/user.rb"
      CollaborationDocStore.replace_snapshot(room_key_for(path), "SNAP")
      CollaborationDocStore.record_update(room_key_for(path), "D1")
      CollaborationDocStore.record_update(room_key_for(path), "D2")

      subscribe path: path

      sync = transmissions.last
      assert_equal "sync", sync["type"]
      assert_equal "SNAP", sync["snapshot"]
      assert_equal %w[D1 D2], sync["deltas"]
    end

    test "doc_update persists the bytes to the store and relays them on the stream" do
      path = "lib/foo.rb"
      subscribe path: path

      assert_broadcast_on(stream_name_for(path), "type" => "doc_update", "update" => "DELTA") do
        perform :doc_update, "update" => "DELTA"
      end

      state = CollaborationDocStore.state_for(room_key_for(path))
      assert_equal ["DELTA"], state[:deltas]
    end

    test "awareness relays on the stream but is not persisted to the store" do
      path = "lib/foo.rb"
      subscribe path: path

      assert_broadcast_on(stream_name_for(path), "type" => "awareness", "awareness" => "CURSOR") do
        perform :awareness, "awareness" => "CURSOR"
      end

      state = CollaborationDocStore.state_for(room_key_for(path))
      assert_nil state[:snapshot]
      assert_empty state[:deltas]
    end

    test "snapshot replaces the cached snapshot, clears deltas, and relays" do
      path = "lib/foo.rb"
      CollaborationDocStore.record_update(room_key_for(path), "OLD_DELTA")
      subscribe path: path

      assert_broadcast_on(stream_name_for(path), "type" => "snapshot", "snapshot" => "NEWSNAP") do
        perform :snapshot, "snapshot" => "NEWSNAP"
      end

      state = CollaborationDocStore.state_for(room_key_for(path))
      assert_equal "NEWSNAP", state[:snapshot]
      assert_empty state[:deltas]
    end

    test "live channel traffic opportunistically reclaims a room idle past the grace window" do
      # An idle room, aged relative to the *current* monotonic reading rather than
      # parked at 0.0. The channel traffic below reads the real clock, and on Linux
      # CLOCK_MONOTONIC counts from boot — so on a freshly started CI runner "now"
      # can be smaller than SWEEP_INTERVAL, making 0.0 not a past time at all and
      # the sweep never fire. Anchoring to the real clock makes the age exact
      # regardless of host uptime.
      ancient = Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                (CollaborationDocStore::GRACE_TTL + CollaborationDocStore::SWEEP_INTERVAL + 1)
      CollaborationDocStore.record_update(room_key_for("abandoned/old.rb"), "OLD", now: ancient)

      subscribe path: "live/new.rb"
      perform :doc_update, "update" => "NEW"

      # The idle room was swept end-to-end, without any explicit sweep! call.
      assert_empty CollaborationDocStore.state_for(room_key_for("abandoned/old.rb"))[:deltas]
      assert_equal ["NEW"], CollaborationDocStore.state_for(room_key_for("live/new.rb"))[:deltas]
    end

    test "subscribing without a path is rejected and opens no stream" do
      subscribe

      assert subscription.rejected?
      assert_no_streams
    end

    test "subscription is rejected when authenticate_with halts" do
      with_auth(proc { head :forbidden }) do
        subscribe path: "lib/foo.rb"

        assert subscription.rejected?
        assert_no_streams
      end
    end

    test "subscription is confirmed when authenticate_with does not halt" do
      with_auth(proc { "authenticated" }) do
        subscribe path: "lib/foo.rb"

        assert subscription.confirmed?
        assert_has_stream stream_name_for("lib/foo.rb")
      end
    end

    test "subscription is rejected when authenticate_with halts via render with keyword args" do
      with_auth(proc { render(plain: "Forbidden", status: :forbidden) }) do
        subscribe path: "lib/foo.rb"

        assert subscription.rejected?
      end
    end

    test "subscription is rejected when authenticate_with raises (fail closed)" do
      with_auth(proc { raise "auth backend down" }) do
        subscribe path: "lib/foo.rb"

        assert subscription.rejected?
      end
    end

    test "a relay/broadcast failure does not raise and persistence still succeeds" do
      path = "lib/foo.rb"
      subscribe path: path

      with_broadcasting_unavailable do
        assert_nothing_raised do
          perform :doc_update, "update" => "DELTA"
        end
      end

      assert_equal ["DELTA"], CollaborationDocStore.state_for(room_key_for(path))[:deltas]
    end

    private

    def with_auth(hook)
      previous = Mbeditor.configuration.authenticate_with
      Mbeditor.configuration.authenticate_with = hook
      yield
    ensure
      Mbeditor.configuration.authenticate_with = previous
    end

    # Simulates ActionCable being unable to relay (e.g. server not running /
    # cable not mounted): broadcasting raises, persistence must still happen.
    def with_broadcasting_unavailable
      server = ActionCable.server
      original = server.method(:broadcast)
      server.define_singleton_method(:broadcast) { |*| raise "no cable" }
      yield
    ensure
      server.define_singleton_method(:broadcast, original)
    end

    # Mirrors CollaborationChannel#room_key: rooms are scoped by workspace so two
    # workspaces holding the same relative path never share a buffer.
    def room_key_for(path)
      "#{Mbeditor::WorkspaceRootResolver.call}\0#{path}"
    end

    def stream_name_for(path)
      "mbeditor_collab:#{Digest::SHA256.hexdigest(room_key_for(path))}"
    end
  end
end
