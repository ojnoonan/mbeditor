# frozen_string_literal: true

require "digest"

module Mbeditor
  class DocumentChannel < ActionCable::Channel::Base
    # In-memory Y.js state per document (keyed by doc_id).
    # Lost on server restart — acceptable for a dev-time tool.
    @@states = {}
    @@states_mutex = Mutex.new

    def subscribed
      stream_from "mbeditor_doc_#{doc_id}"

      # Send the current accumulated Y.js state to the new subscriber
      # so they can fast-forward to the latest document content.
      @@states_mutex.synchronize do
        transmit({ type: "sync", state: @@states[doc_id] }) if @@states[doc_id]
      end
    end

    def unsubscribed
      # Nothing to clean up — stream persists for other subscribers
    end

    # Client sends a Y.js binary update (base64-encoded) and the new full state.
    def broadcast_update(data)
      @@states_mutex.synchronize do
        @@states[doc_id] = data["state"] if data["state"]
      end

      ActionCable.server.broadcast(
        "mbeditor_doc_#{doc_id}",
        { type: "update", update: data["update"] }
      )
    end

    # Client sends its cursor/selection position for remote-cursor rendering.
    def broadcast_cursor(data)
      ActionCable.server.broadcast(
        "mbeditor_doc_#{doc_id}",
        { type: "cursor", userId: data["userId"], color: data["color"],
          cursor: data["cursor"], selection: data["selection"] }
      )
    end

    private

    def doc_id
      Digest::SHA1.hexdigest(params[:path].to_s)
    end
  end
end
