# frozen_string_literal: true

require "json"
require "time"

module Mbeditor
  # A bounded, in-memory audit/telemetry log the developer can download and
  # hand to an AI to analyse, plus the batches the browser ring pushes up.
  #
  # Lives in lib/ (required from lib/mbeditor.rb, NOT autoloaded) for the same
  # reason as ExceptionLog: a Zeitwerk reload must not wipe the buffer you are
  # about to download.
  #
  # The privacy guarantee is structural, not a scrubber. A field value is kept
  # only when it is Numeric, true, false or a Symbol. A Symbol is authored in
  # code and can never be user data; a String can, so Strings are rejected
  # outright. The client mirrors this rule by dropping any argument to rec()
  # whose typeof is not 'number'. Neither channel can carry a path, a file
  # name, a URL or a line of source.
  module AuditLog
    MAX_ENTRIES = 5000

    # One client batch. The browser ring holds 512, so this only bounds a
    # forged or replayed POST.
    MAX_INGEST = 2048

    # Largest body the ingest endpoint will parse. 512 five-number entries plus
    # the legend is well under this.
    MAX_POST_BYTES = 1024 * 1024

    ENTRY_LENGTH = 5

    # Refuse to read back a file larger than the two rings could ever produce.
    MAX_FILE_BYTES = 8 * 1024 * 1024

    # Write-behind: at most one file write every PERSIST_INTERVAL seconds.
    PERSIST_INTERVAL = 5

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def enabled?
        Mbeditor.configuration.audit_log != false
      end

      # Returns the recorded entry, or nil when nothing was recorded.
      def record(event, **fields)
        return nil unless enabled?
        return nil unless event.is_a?(Symbol)

        entry = { at: Time.now.utc.iso8601, event: event }
        fields.each { |key, value| entry[key] = value if safe?(value) }

        MUTEX.synchronize do
          load_unlocked
          bound(@entries << entry)
          @dirty = true
        end
        persist!
        entry
      # Every caller is an `ensure` block wrapping real work. A raise here would
      # replace the exception that block is unwinding, so a telemetry failure
      # would masquerade as the bug it was recording.
      rescue StandardError => e
        Rails.logger.debug("[mbeditor] audit record failed: #{e.class}: #{e.message}")
        nil
      end

      # A batch from the browser ring. Returns the number of entries kept.
      #
      # Deliberately takes no legend. The legend is a constant of the browser
      # bundle, so shipping it up here would be the one channel in this module
      # that accepts an arbitrary String, and the guarantee above would be a
      # claim rather than a property. The download handler merges it in client
      # side instead, where it never crosses the wire at all.
      def ingest(events)
        return nil unless enabled?
        return nil unless events.is_a?(Array)

        kept = events.first(MAX_INGEST).select { |entry| client_entry?(entry) }

        MUTEX.synchronize do
          load_unlocked
          bound(@client_events.concat(kept))
          @dirty = true
        end
        persist!
        kept.length
      rescue StandardError => e
        Rails.logger.debug("[mbeditor] audit ingest failed: #{e.class}: #{e.message}")
        nil
      end

      # The download payload. Persists unconditionally first, so the file on
      # disk always matches what the developer just downloaded.
      def payload
        persist!(force: true)
        MUTEX.synchronize do
          load_unlocked
          {
            schema: 1,
            generatedAt: Time.now.utc.iso8601,
            client: { events: @client_events.dup },
            server: { events: @entries.dup }
          }
        end
      end

      def clear!
        MUTEX.synchronize do
          @loaded = true
          @entries = []
          @client_events = []
          @dirty = false
          @persisted_at = nil
        end
        path = file_path
        File.delete(path) if path && File.exist?(path)
        nil
      rescue SystemCallError, IOError
        nil
      end

      private

      def safe?(value)
        value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
      end

      # Numbers only, fixed width. A string, a nested object or a short array
      # is dropped rather than repaired.
      def client_entry?(entry)
        entry.is_a?(Array) && entry.length == ENTRY_LENGTH &&
          entry.all? { |value| value.is_a?(Numeric) && value.finite? }
      end

      def bound(ring)
        ring.shift while ring.length > MAX_ENTRIES
        ring
      end

      # Serialises under the lock and writes outside it: the file runs to a
      # megabyte and a request should never wait on that IO.
      def persist!(force: false)
        json = MUTEX.synchronize do
          load_unlocked
          next nil unless force || (@dirty && Time.now.to_f - (@persisted_at || 0) >= PERSIST_INTERVAL)

          @dirty = false
          @persisted_at = Time.now.to_f
          JSON.generate("schema" => 1, "client" => @client_events, "server" => @entries)
        end
        return if json.nil?

        path = file_path
        File.write(path, json) if path
        nil
      rescue SystemCallError, IOError => e
        Rails.logger.debug("[mbeditor] audit log persist failed: #{e.class}: #{e.message}")
      end

      # Loaded once, lazily. Surviving a page reload is the point of persisting,
      # and the server process may have restarted in between.
      def load_unlocked
        return if @loaded

        @loaded = true
        @entries = []
        @client_events = []

        path = file_path
        return unless path && File.exist?(path) && File.size(path) <= MAX_FILE_BYTES

        data = JSON.parse(File.read(path))
        return unless data.is_a?(Hash)

        @entries = bound(Array(data["server"]).grep(Hash).map { |raw| raw.transform_keys(&:to_sym) })
        @client_events = bound(Array(data["client"]).select { |raw| client_entry?(raw) })
      rescue JSON::ParserError, SystemCallError, IOError => e
        Rails.logger.debug("[mbeditor] audit log load failed: #{e.class}: #{e.message}")
      end

      def file_path
        Rails.root && Rails.root.join("tmp", "mbeditor_audit.json").to_s
      end
    end
  end
end
