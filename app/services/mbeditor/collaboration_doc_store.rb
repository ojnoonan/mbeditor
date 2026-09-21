# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

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
    # costs a late joiner an incomplete replay — the client detects the missing
    # dependencies and asks a peer for a full snapshot instead of attaching to
    # the partial replay (see CollaborationService#_maybeAttach).
    MAX_DELTAS = 500

    # A seed claim left behind by a crashed process would wedge the room forever
    # (every later opener defers to content that never comes). Claims older than
    # this are treated as abandoned and may be taken over. It matches GRACE_TTL
    # because a room that has been idle that long is itself evictable, so the
    # claim and the room it guards expire together.
    CLAIM_TTL = GRACE_TTL

    # Grant the right to seed a room's shared document from disk, to exactly one
    # client. Without this every client that finds the room empty inserts the whole
    # file at offset 0, and Yjs merges those inserts into two concatenated copies —
    # the file appended to itself. That happens whenever two editor tabs attach to
    # a room the server has no state for: a fresh room, or one that was evicted
    # while both were idle. The claim is per room, so the loser waits for the
    # winner's content instead of inventing its own.
    #
    # The in-memory flag only covers one process. With a cross-process cable
    # adapter (redis/postgres/solid_cable) and more than one Puma worker, two
    # clients can reach two different processes whose stores are both empty, so
    # the claim is also serialized through a lock file under tmp/ (shared by
    # every process of the app). `File::CREAT | File::EXCL` is the atomic test,
    # so exactly one process wins even in the race.
    def claim_seed(path, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        next false if room[:seed_claimed] || room[:snapshot] || !room[:deltas].empty?

        next false unless acquire_claim(path, now)

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
        if room[:subscribers].zero? && room[:snapshot].nil? && room[:deltas].empty?
          room[:seed_claimed] = false
          release_claim(path)
        end
      end
      nil
    end

    # Record a delta and return the room-local sequence number assigned to it.
    # The sequence lets a client tell the server how far its full-state snapshot
    # reaches, so replace_snapshot can keep exactly the deltas the snapshot does
    # not already contain (see #97).
    def record_update(path, bytes, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        room[:seq] += 1
        room[:deltas] << { seq: room[:seq], bytes: bytes }
        room[:deltas].shift while room[:deltas].size > MAX_DELTAS
        room[:seq]
      end
    end

    # Swap the cached snapshot. Deltas up to +applied_seq+ are already folded into
    # the snapshot and are dropped; anything recorded after that point stays, so a
    # delta that crossed the snapshot in flight is not lost from the buffer.
    # +applied_seq+ nil (legacy/unknown) clears the buffer as before.
    def replace_snapshot(path, bytes, applied_seq: nil, now: monotonic)
      MUTEX.synchronize do
        room = touch(path, now)
        room[:snapshot] = bytes
        if applied_seq
          room[:deltas] = room[:deltas].select { |d| d[:seq] > applied_seq }
          room[:snapshot_seq] = applied_seq
        else
          room[:deltas] = []
          room[:snapshot_seq] = room[:seq]
        end
      end
      nil
    end

    def state_for(path, now: monotonic)
      MUTEX.synchronize do
        room = rooms[path]
        if room
          room[:last_activity] = now
          result = {
            snapshot: room[:snapshot],
            deltas: room[:deltas].map { |d| d[:bytes] },
            delta_seqs: room[:deltas].map { |d| d[:seq] },
            snapshot_seq: room[:snapshot_seq],
            seq: room[:seq]
          }
        else
          result = { snapshot: nil, deltas: [], delta_seqs: [], snapshot_seq: 0, seq: 0 }
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
        clear_claims
      end
      nil
    end

    def rooms
      @rooms ||= {}
    end
    private_class_method :rooms

    def touch(path, now)
      new_room = !rooms.key?(path)
      room = (rooms[path] ||= { snapshot: nil, deltas: [], subscribers: 0, seed_claimed: false,
                                seq: 0, snapshot_seq: 0 })
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
      rooms.delete_if do |path, room|
        evict = room[:subscribers].zero? && (now - room[:last_activity]) > grace
        release_claim(path) if evict
        evict
      end
    end
    private_class_method :evict_idle

    # Only idle rooms are evictable, per the invariant on join: emptying a room
    # clients still hold content for gets the next opener granted a seed it must
    # not perform. With every room subscribed the cap is simply exceeded.
    def evict_lru
      oldest = rooms.reject { |_path, room| room[:subscribers].positive? }
                    .min_by { |_path, room| room[:last_activity] }
      return unless oldest

      release_claim(oldest.first)
      rooms.delete(oldest.first)
    end
    private_class_method :evict_lru

    # ── cross-process seed claim ────────────────────────────────────────────
    #
    # The workspace tmp/ directory is shared by every process of the app (the
    # same tree WorkspaceRootResolver points at), so a claim file there is
    # visible to all of them without new infrastructure.

    def claim_dir
      root = begin
        WorkspaceRootResolver.call.to_s
      rescue StandardError
        nil
      end
      root = Rails.root.to_s if (root.nil? || root.empty?) && defined?(Rails) && Rails.respond_to?(:root)
      root = Dir.tmpdir if root.nil? || root.empty?
      File.join(root, "tmp", "mbeditor_collab_claims")
    end
    private_class_method :claim_dir

    def claim_path(path)
      File.join(claim_dir, Digest::SHA256.hexdigest(path.to_s))
    end
    private_class_method :claim_path

    # Atomically take the claim, or refuse when another process holds a live one.
    # Returns true only when this call created the file.
    def acquire_claim(path, now)
      file = claim_path(path)
      if File.exist?(file)
        return false if (Time.now - File.mtime(file)) <= CLAIM_TTL

        # Abandoned by a crashed/evicted process; reclaim it.
        begin
          File.delete(file)
        rescue Errno::ENOENT
          nil
        end
      end

      FileUtils.mkdir_p(claim_dir)
      begin
        File.open(file, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(now.to_s) }
        true
      rescue Errno::EEXIST
        false
      end
    rescue SystemCallError, IOError
      # No writable tmp/ (e.g. a read-only checkout). Fall back to the in-memory
      # claim rather than crashing the channel; cross-process serialization is
      # lost, but the alternative is no collaboration at all.
      true
    end
    private_class_method :acquire_claim

    def release_claim(path)
      File.delete(claim_path(path))
    rescue SystemCallError
      nil
    end
    private_class_method :release_claim

    def clear_claims
      Dir.glob(File.join(claim_dir, "*")).each do |file|
        File.delete(file)
      rescue SystemCallError
        nil
      end
    rescue StandardError
      nil
    end
    private_class_method :clear_claims

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic
  end
end

