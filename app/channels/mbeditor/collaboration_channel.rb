# frozen_string_literal: true

require "digest"

module Mbeditor
  # Per-file relay edge for realtime collaborative editing. The channel never
  # interprets the opaque Yjs bytes it carries — it persists them through
  # CollaborationDocStore and relays them to the other subscribers on a stream
  # keyed by a digest of the workspace-relative path. It degrades gracefully
  # when ActionCable is absent, matching the EditorChannel conditional-base
  # pattern.
  class CollaborationChannel < (defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object)
    include ChannelAuthentication

    STREAM_PREFIX = "mbeditor_collab"

    def subscribed
      return unless mbeditor_authenticated?

      @path = params[:path].to_s
      return reject if @path.empty? && respond_to?(:reject, true)

      stream_from stream_name if respond_to?(:stream_from)
      CollaborationDocStore.join(room_key)
      @joined = true
      transmit_initial_state
    end

    def unsubscribed
      CollaborationDocStore.leave(room_key) if @joined
      @joined = false
    end

    def doc_update(data)
      bytes = data["update"]
      return if bytes.nil?

      seq = CollaborationDocStore.record_update(room_key, bytes)
      relay("type" => "doc_update", "update" => bytes, "seq" => seq)
    end

    def snapshot(data)
      bytes = data["snapshot"]
      return if bytes.nil?

      applied_seq = data["applied_seq"]
      CollaborationDocStore.replace_snapshot(room_key, bytes, applied_seq: applied_seq)
      relay("type" => "snapshot", "snapshot" => bytes, "applied_seq" => applied_seq)
    end

    # A client whose delta replay was incomplete (missing dependencies after the
    # buffer overflowed, or a room restarted from scratch) asks the room for a
    # full snapshot. It is relayed to the other subscribers; any bound peer
    # answers with its own state via #snapshot. The requester attaches once that
    # lands (see CollaborationService).
    def request_snapshot(_data = nil)
      relay("type" => "request_snapshot")
    end

    def awareness(data)
      bytes = data["awareness"]
      return if bytes.nil?

      relay("type" => "awareness", "awareness" => bytes)
    end

    private

    def relay(payload)
      return unless defined?(ActionCable) && ActionCable.respond_to?(:server)

      ActionCable.server.broadcast(stream_name, payload)
    rescue StandardError
      # A relay failure (cable down / not mounted) must never crash the socket
      # or undo the persistence that already happened.
    end

    def transmit_initial_state
      return unless respond_to?(:transmit, true)

      state = CollaborationDocStore.state_for(room_key)
      # Exactly one client per empty room is told to seed it from disk; see
      # CollaborationDocStore.claim_seed. Everyone else waits for that content.
      # delta_seqs lets the joiner track how far the replay reaches, so its own
      # later snapshot can tell the server which deltas to keep.
      transmit({ "type" => "sync", "snapshot" => state[:snapshot], "deltas" => state[:deltas],
                 "delta_seqs" => state[:delta_seqs], "snapshot_seq" => state[:snapshot_seq],
                 "seed" => CollaborationDocStore.claim_seed(room_key) })
    end

    # A room is identified by workspace *and* relative path. Keying on the path
    # alone means two workspaces that both contain "README.md" share one buffer,
    # so pointing `workspace_root` at a different project seeds its file with the
    # previous project's content. The NUL separator cannot occur in either part.
    def room_key
      @room_key ||= "#{WorkspaceRootResolver.call}\0#{@path}"
    end

    def stream_name
      "#{STREAM_PREFIX}:#{Digest::SHA256.hexdigest(room_key)}"
    end
  end
end
