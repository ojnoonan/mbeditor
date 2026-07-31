# frozen_string_literal: true

module Mbeditor
  # Who is currently connected for collaborative editing. Thread-safe and
  # in-memory, modelled on CollaborationDocStore (Mutex + monotonic clock).
  #
  # This exists because the clients cannot maintain an accurate roster between
  # themselves. The original protocol relayed one "here"/"leave" event per
  # participant and every client merged those into its own roster, which meant a
  # single dropped or missed message — a peer's browser killed outright, a relay
  # failure, or simply reloading your own page at the moment someone else closed
  # theirs — left a participant in your roster permanently, with no expiry to
  # reclaim it. That is not cosmetic: the roster gates collaboration, so one ghost
  # kept persistent undo disabled and external on-disk changes suppressed for the
  # rest of the session, for a peer who was not there.
  #
  # The server already knows exactly who is subscribed — Action Cable calls
  # `unsubscribed` on a clean close and on its own connection timeout — so it is
  # the only party that can answer this correctly. Every broadcast now carries the
  # complete roster and clients replace theirs wholesale, so a dropped message
  # costs one stale interval rather than a permanent phantom. No TTL sweep: an
  # entry outlives its connection only if the process dies, which takes the
  # registry with it.
  module PresenceRegistry
    module_function

    MUTEX = Mutex.new
    private_constant :MUTEX

    # Fields a participant publishes about itself. Anything else in the payload is
    # dropped — this is relayed to every other client, so the shape is a boundary.
    # `seq` is the sender's own heartbeat counter, echoed back so they can tell
    # which broadcast their message caused — every participant's heartbeat now
    # rebroadcasts everyone, so "my entry came back" alone does not mean "my
    # message round-tripped", and timing against it inflates the measurement.
    # `seed` is a stable number derived from the sender's persisted identity. It
    # exists so a colour clash resolves to the same winner on both sides and stays
    # resolved across a reload; it is deliberately a hash rather than the id itself.
    RELAYED_FIELDS = %w[name colour current_file rtt seq seed].freeze

    def record(client_id, attrs, now: monotonic)
      id = client_id.to_s
      return if id.empty?

      entry = attrs.slice(*RELAYED_FIELDS)
      MUTEX.synchronize do
        participants[id] = entry.merge("client_id" => id, "last_seen" => now)
      end
      nil
    end

    def remove(client_id)
      id = client_id.to_s
      MUTEX.synchronize { participants.delete(id) }
      nil
    end

    # The full roster, with each entry's idle time resolved against a monotonic
    # clock here rather than compared across machines — no clock skew to correct.
    def roster(now: monotonic)
      MUTEX.synchronize do
        participants.transform_values do |entry|
          entry.except("last_seen").merge("idle" => (now - entry["last_seen"]).round)
        end
      end
    end

    def reset!
      MUTEX.synchronize { @participants = {} }
      nil
    end

    def participants
      @participants ||= {}
    end
    private_class_method :participants

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic
  end
end
