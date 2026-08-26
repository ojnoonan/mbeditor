# frozen_string_literal: true

module Mbeditor
  # Thread-safe, in-memory cache of opaque Yjs bytes per active file. It never
  # interprets the bytes (no Ruby CRDT): it only buffers the latest snapshot plus
  # recent deltas so a late-joiner can sync instantly. Modeled on the existing
  # TTL caches (GitInfoService, AvailabilityProbe): Mutex + monotonic clock.
  module CollaborationDocStore
    module_function

    MUTEX = Mutex.new
    private_constant :MUTEX

    # Grace window (seconds): a room with no activity for longer than this is
    # evicted by sweep!. Because every op refreshes last_activity, a room that
    # just went empty survives this long, so a quick reopen recovers its buffer.
    GRACE_TTL = 300

    # Hard cap on cached rooms. Exceeding it evicts the least-recently-active
    # room, so process memory stays bounded even if rooms are never swept.
    ROOM_CAP = 200

    # Idle GC rides on traffic: every write/read attempts a sweep, but the scan
    # runs at most once per this interval so a busy room doesn't pay for it on
    # every op. With no explicit scheduler, memory stays bounded over a long
    # session as long as some activity continues. Kept well under GRACE_TTL so an
    # idle room is reclaimed soon after its grace window elapses.
    SWEEP_INTERVAL = 60

    # Hard cap on buffered deltas per room; a long editing session on one file
    # would otherwise grow it without limit. Over the cap the oldest go, which
    # costs a late joiner an incomplete replay — it then waits for the next
    # snapshot instead of syncing from the buffer.
    MAX_DELTAS = 500

    # Grant the right to seed a room's shared document from disk, to exactly one
    # client. Without this every client that finds the room empty inserts the whole
    # file at offset 0, and Yjs merges those inserts into two concatenated copies —
    # the file appended to itself. That happens whenever two editor tabs attach to
    # a room the server has no state for: a fresh room, or one that was evicted
    # while both were idle. The claim is per room, so the loser waits for the
    # winner's content instead of inventing its own.
    def claim_seed(path, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        next false if room[:seed_claimed] || room[:snapshot] || !room[:deltas].empty?

        room[:seed_claimed] = true
      end
    end

    # Subscriber accounting. A room with a live subscriber must never be evicted:
    # eviction empties the server's copy while clients still hold content, and the
    # next client to attach would be granted a seed it must not perform.
    def join(path, now: monotonic)
      MUTEX.synchronize { touch(path, now)[:subscribers] += 1 }
      nil
    end

    def leave(path, now: monotonic)
      MUTEX.synchronize do
        room = rooms[path]
        next unless room

        room[:subscribers] -= 1 if room[:subscribers] > 0
        # The claimer can leave before it ever seeds (a tab closed during the
        # handshake). Releasing the claim on an empty, empty-handed room keeps the
        # next opener from deferring to content that will never arrive.
        room[:seed_claimed] = false if room[:subscribers].zero? && room[:snapshot].nil? && room[:deltas].empty?
      end
      nil
    end

    def record_update(path, bytes, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        room[:deltas] << bytes
        room[:deltas].shift while room[:deltas].size > MAX_DELTAS
      end
      nil
    end

    def replace_snapshot(path, bytes, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        room[:snapshot] = bytes
        room[:deltas] = []
      end
      nil
    end

    def state_for(path, now: monotonic)
      MUTEX.synchronize do
        room = rooms[path]
        if room
          room[:last_activity] = now
          result = { snapshot: room[:snapshot], deltas: room[:deltas].dup }
        else
          result = { snapshot: nil, deltas: [] }
        end
        maybe_sweep(now)
        result
      end
    end

    def sweep!(now: monotonic, grace: GRACE_TTL)
      MUTEX.synchronize { evict_idle(now, grace) }
      nil
    end

    def reset!
      MUTEX.synchronize do
        @rooms = {}
        @last_sweep = nil
      end
      nil
    end

    def rooms
      @rooms ||= {}
    end
    private_class_method :rooms

    def touch(path, now)
      new_room = !rooms.key?(path)
      room = (rooms[path] ||= { snapshot: nil, deltas: [], subscribers: 0, seed_claimed: false })
      room[:last_activity] = now
      maybe_sweep(now)
      evict_lru if new_room && rooms.size > ROOM_CAP
      room
    end
    private_class_method :touch

    # Opportunistic idle GC, throttled to one scan per SWEEP_INTERVAL. Callers hold
    # MUTEX. The room that just touched its own last_activity has age 0, so a sweep
    # never reclaims the room driving it.
    def maybe_sweep(now)
      return if @last_sweep && (now - @last_sweep) < SWEEP_INTERVAL

      @last_sweep = now
      evict_idle(now, GRACE_TTL)
    end
    private_class_method :maybe_sweep

    def evict_idle(now, grace)
      rooms.delete_if { |_path, room| room[:subscribers].zero? && (now - room[:last_activity]) > grace }
    end
    private_class_method :evict_idle

    def evict_lru
      idle = rooms.reject { |_path, room| room[:subscribers].positive? }
      oldest = (idle.empty? ? rooms : idle).min_by { |_path, room| room[:last_activity] }
      rooms.delete(oldest.first) if oldest
    end
    private_class_method :evict_lru

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic
  end
end
