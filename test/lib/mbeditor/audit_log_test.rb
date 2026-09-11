# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class AuditLogTest < Minitest::Test
    def setup
      Mbeditor.configuration.audit_log = true
      AuditLog.clear!
    end

    def teardown
      AuditLog.clear!
      Mbeditor.configuration.audit_log = true
    end

    def server_events
      AuditLog.payload[:server][:events]
    end

    def client_events
      AuditLog.payload[:client][:events]
    end

    # Drops every trace of the in-memory rings, so the next read has to come
    # off disk — the same state a restarted server process starts in.
    def simulate_restart
      %i[@loaded @entries @client_events @dirty @persisted_at].each do |ivar|
        AuditLog.instance_variable_set(ivar, nil)
      end
    end

    def test_keeps_numeric_boolean_and_symbol_fields
      entry = AuditLog.record(:save, ms: 12, bytes: 3.5, ok: true, cached: false, tier: :rg)

      assert_equal :save, entry[:event]
      assert_equal 12, entry[:ms]
      assert_in_delta 3.5, entry[:bytes]
      assert_equal true, entry[:ok]
      assert_equal false, entry[:cached]
      assert_equal :rg, entry[:tier]
    end

    def test_rejects_string_fields_outright
      entry = AuditLog.record(:save, path: "app/models/user.rb", ms: 3)

      refute entry.key?(:path), "a String can be user data; a Symbol is authored in code"
      assert_equal 3, entry[:ms]
      refute_includes AuditLog.payload.to_s, "user.rb"
    end

    def test_rejects_a_non_symbol_event
      assert_nil AuditLog.record("save", ms: 1)
      assert_empty server_events
    end

    def test_ring_drops_the_oldest
      (AuditLog::MAX_ENTRIES + 3).times { |i| AuditLog.record(:save, ms: i) }

      events = server_events
      assert_equal AuditLog::MAX_ENTRIES, events.length
      assert_equal 3, events.first[:ms], "the first three aged out"
      assert_equal AuditLog::MAX_ENTRIES + 2, events.last[:ms]
    end

    def test_ingest_keeps_only_five_number_arrays
      kept = AuditLog.ingest([[1, 2, 3, 4, 5], [1, 2, 3], "nope", [1, 2, 3, 4, "x"],
                              { "a" => 1 }, [1, 2, 3, 4, 5, 6], [1, 2, Float::INFINITY, 4, 5]])

      assert_equal 1, kept
      assert_equal [[1, 2, 3, 4, 5]], client_events
    end

    def test_ingest_rejects_a_malformed_batch
      assert_nil AuditLog.ingest("events")
      assert_nil AuditLog.ingest(nil)
      assert_empty client_events
    end

    def test_ingest_caps_the_batch
      batch = Array.new(AuditLog::MAX_INGEST + 50) { [1, 2, 3, 4, 5] }

      assert_equal AuditLog::MAX_INGEST, AuditLog.ingest(batch)
    end

    # The whole point of the module. If a String can reach the payload through
    # any argument position, in memory or on disk, the guarantee is a comment
    # rather than a property.
    SECRETS = [
      "/Users/someone/checkout/app/models/user.rb",
      "app/models/user.rb",
      "https://internal.example.com/api?token=abc123",
      "class User < ApplicationRecord; end"
    ].freeze

    def test_no_secret_reaches_the_payload_through_record
      SECRETS.each_with_index do |secret, i|
        AuditLog.record(:probe, path: secret, ms: i, nested: { p: secret }, arr: [secret])
      end
      AuditLog.record(SECRETS.first, ms: 1)

      dump = JSON.generate(AuditLog.payload)
      SECRETS.each { |secret| refute_includes dump, secret }
    end

    def test_no_secret_reaches_the_payload_through_ingest
      AuditLog.ingest([[1, 2, 3, 4, 5], [1, 2, 3, 4, SECRETS.first], [1, 2, SECRETS.first],
                       SECRETS.first, { path: SECRETS.first }, [1, 2, 3, 4, 5, SECRETS.first]])

      dump = JSON.generate(AuditLog.payload)
      SECRETS.each { |secret| refute_includes dump, secret }
    end

    # Regression guard: the legend used to travel in the POST body and was
    # stored verbatim, which was a string-shaped hole straight through the
    # guarantee. It is a constant of the browser bundle and is merged in at
    # download time, so ingest must never grow a second argument again.
    def test_ingest_accepts_no_legend
      assert_equal 1, AuditLog.method(:ingest).arity
    end

    def test_no_secret_reaches_the_persisted_file
      SECRETS.each { |secret| AuditLog.record(:probe, path: secret) }
      AuditLog.payload

      disk = File.read(Rails.root.join("tmp", "mbeditor_audit.json"))
      SECRETS.each { |secret| refute_includes disk, secret }
    end

    def test_survives_a_restart
      AuditLog.record(:boot, ms: 42)
      AuditLog.ingest([[7, 1, 99, 0, 0]])
      AuditLog.payload

      simulate_restart

      assert_equal 42, server_events.first[:ms]
      assert_equal "boot", server_events.first[:event].to_s
      assert_equal [[7, 1, 99, 0, 0]], client_events
    end

    # ProcessRunner is the choke point every subprocess goes through, and
    # AvailabilityProbe runs its probes concurrently and deliberately outside
    # that service's own mutex. record must not put that serialisation back.
    def test_record_never_blocks_on_a_held_lock
      mutex = AuditLog.const_get(:MUTEX)
      mutex.lock
      begin
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        200.times { AuditLog.record(:probe, ms: 1) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 0.5, "record blocked while another thread held the lock"
      ensure
        mutex.unlock
      end
    end

    def test_record_does_no_file_io
      path = Rails.root.join("tmp", "mbeditor_audit.json")
      File.delete(path) if File.exist?(path)

      AuditLog.record(:probe, ms: 1)

      refute File.exist?(path), "record wrote the log file inline; persistence rides on ingest and payload"
      AuditLog.payload
      assert File.exist?(path), "payload still persists"
    end

    def test_disabled_records_nothing
      Mbeditor.configuration.audit_log = false

      assert_nil AuditLog.record(:save, ms: 1)
      assert_nil AuditLog.ingest([[1, 2, 3, 4, 5]])
      assert_empty server_events
      assert_empty client_events
    end
  end
end
