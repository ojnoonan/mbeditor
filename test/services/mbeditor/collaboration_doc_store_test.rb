# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class CollaborationDocStoreTest < Minitest::Test
    def teardown
      CollaborationDocStore.reset!
    end

    # tracer: a recorded update is buffered as a delta for a late-joiner

    def test_record_update_then_state_for_returns_buffered_delta
      CollaborationDocStore.record_update("file.rb", "delta-1")

      state = CollaborationDocStore.state_for("file.rb")

      assert_nil state[:snapshot]
      assert_equal ["delta-1"], state[:deltas]
    end

    # record_update buffers deltas in arrival order

    def test_record_update_appends_deltas_in_order
      CollaborationDocStore.record_update("file.rb", "d1")
      CollaborationDocStore.record_update("file.rb", "d2")
      CollaborationDocStore.record_update("file.rb", "d3")

      assert_equal %w[d1 d2 d3], CollaborationDocStore.state_for("file.rb")[:deltas]
    end

    # replace_snapshot compacts: it swaps the snapshot and clears buffered deltas

    def test_replace_snapshot_swaps_snapshot_and_clears_deltas
      CollaborationDocStore.record_update("file.rb", "d1")
      CollaborationDocStore.record_update("file.rb", "d2")

      CollaborationDocStore.replace_snapshot("file.rb", "snap")

      state = CollaborationDocStore.state_for("file.rb")
      assert_equal "snap", state[:snapshot]
      assert_equal [], state[:deltas]
    end

    def test_record_update_after_snapshot_appends_on_top_of_snapshot
      CollaborationDocStore.replace_snapshot("file.rb", "snap")
      CollaborationDocStore.record_update("file.rb", "d1")

      state = CollaborationDocStore.state_for("file.rb")
      assert_equal "snap", state[:snapshot]
      assert_equal ["d1"], state[:deltas]
    end

    # a never-seen path has no buffered state

    def test_state_for_unknown_path_returns_empty_state
      state = CollaborationDocStore.state_for("never-opened.rb")

      assert_nil state[:snapshot]
      assert_equal [], state[:deltas]
    end

    # sweep! evicts a room whose last activity is older than the grace window

    def test_sweep_evicts_room_idle_past_grace_window
      CollaborationDocStore.record_update("stale.rb", "d1", now: 1000.0)

      CollaborationDocStore.sweep!(now: 1000.0 + CollaborationDocStore::GRACE_TTL + 1)

      state = CollaborationDocStore.state_for("stale.rb")
      assert_nil state[:snapshot]
      assert_equal [], state[:deltas]
    end

    # a briefly-empty room within the grace window survives sweep!

    def test_sweep_keeps_room_within_grace_window
      CollaborationDocStore.record_update("live.rb", "d1", now: 1000.0)

      CollaborationDocStore.sweep!(now: 1000.0 + CollaborationDocStore::GRACE_TTL - 1)

      assert_equal ["d1"], CollaborationDocStore.state_for("live.rb")[:deltas]
    end

    # reading state refreshes activity, so a quick reopen survives a later sweep

    def test_state_for_refreshes_activity_so_reopen_survives_sweep
      CollaborationDocStore.record_update("reopened.rb", "d1", now: 1000.0)

      # quick reopen just before the grace window elapses
      CollaborationDocStore.state_for("reopened.rb", now: 1000.0 + CollaborationDocStore::GRACE_TTL - 1)
      # a sweep that would have evicted the original activity timestamp
      CollaborationDocStore.sweep!(now: 1000.0 + CollaborationDocStore::GRACE_TTL + 1)

      assert_equal ["d1"], CollaborationDocStore.state_for("reopened.rb")[:deltas]
    end

    # activity opportunistically sweeps: a write evicts another room idle past the
    # grace window without anyone calling sweep! — idle GC rides on traffic.

    def test_write_opportunistically_evicts_room_idle_past_grace_window
      CollaborationDocStore.record_update("stale.rb", "d1", now: 1000.0)

      # A write to a different room, long after stale.rb went idle, triggers GC.
      past_grace = 1000.0 + CollaborationDocStore::GRACE_TTL + 1
      CollaborationDocStore.record_update("active.rb", "d2", now: past_grace)

      assert_equal [], CollaborationDocStore.state_for("stale.rb", now: past_grace)[:deltas]
      assert_equal ["d2"], CollaborationDocStore.state_for("active.rb", now: past_grace)[:deltas]
    end

    # the opportunistic sweep is throttled: a write within SWEEP_INTERVAL of the
    # last sweep does not rescan, so a just-expired idle room briefly survives
    # (the GC scan doesn't run on every op).

    def test_opportunistic_sweep_is_throttled_within_interval
      grace = CollaborationDocStore::GRACE_TTL
      CollaborationDocStore.record_update("stale.rb", "d1", now: 0.0)
      # A write at +(grace - 20) sweeps (interval elapsed) but stale isn't expired yet.
      CollaborationDocStore.record_update("keep.rb", "k", now: grace - 20.0)
      # Another write only 40s later (< SWEEP_INTERVAL=60): throttled, no rescan,
      # even though stale is now past its grace window.
      CollaborationDocStore.record_update("keep.rb", "k2", now: grace + 20.0)

      assert_equal ["d1"], CollaborationDocStore.state_for("stale.rb", now: grace + 20.0)[:deltas]
    end

    # eviction resumes on the next write once SWEEP_INTERVAL has elapsed again.

    def test_opportunistic_sweep_resumes_after_interval
      grace = CollaborationDocStore::GRACE_TTL
      CollaborationDocStore.record_update("stale.rb", "d1", now: 0.0)
      CollaborationDocStore.record_update("keep.rb", "k", now: grace - 20.0)   # sweep, stale survives
      CollaborationDocStore.record_update("keep.rb", "k2", now: grace + 20.0)  # throttled
      CollaborationDocStore.record_update("keep.rb", "k3", now: grace + 50.0)  # interval elapsed -> sweep

      assert_equal [], CollaborationDocStore.state_for("stale.rb", now: grace + 50.0)[:deltas]
    end

    # a read also drives the opportunistic sweep, evicting a different idle room.

    def test_read_drives_opportunistic_sweep
      CollaborationDocStore.record_update("stale.rb", "d1", now: 0.0)
      past_grace = CollaborationDocStore::GRACE_TTL + 1

      CollaborationDocStore.state_for("other.rb", now: past_grace) # read triggers GC

      assert_equal [], CollaborationDocStore.state_for("stale.rb", now: past_grace)[:deltas]
    end

    # the room cap bounds cached rooms by evicting the least-recently-active one

    def test_room_cap_evicts_least_recently_active_room
      cap = CollaborationDocStore::ROOM_CAP
      (0...cap).each { |i| CollaborationDocStore.record_update("r#{i}", "d", now: 100.0 + i) }

      # one more room exceeds the cap -> evicts r0 (oldest last_activity)
      now = 100.0 + cap
      CollaborationDocStore.record_update("overflow", "d", now: now)

      assert_equal [], CollaborationDocStore.state_for("r0", now: now)[:deltas]
      assert_equal ["d"], CollaborationDocStore.state_for("overflow", now: now)[:deltas]
    end

    # concurrent writers to one room record every delta without loss or crash

    def test_concurrent_record_update_records_all_deltas
      threads = 20
      per_thread = 100

      workers = Array.new(threads) do |t|
        Thread.new do
          per_thread.times { |i| CollaborationDocStore.record_update("hot.rb", "t#{t}-#{i}") }
        end
      end
      workers.each(&:join)

      assert_equal threads * per_thread, CollaborationDocStore.state_for("hot.rb")[:deltas].size
    end

    # reset! drops all cached rooms (test hook)

    def test_reset_clears_all_rooms
      CollaborationDocStore.record_update("a.rb", "d1")
      CollaborationDocStore.replace_snapshot("b.rb", "snap")

      CollaborationDocStore.reset!

      assert_equal [], CollaborationDocStore.state_for("a.rb")[:deltas]
      assert_nil CollaborationDocStore.state_for("b.rb")[:snapshot]
    end
  end
end
