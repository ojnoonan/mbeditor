# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class PresenceRegistryTest < ActiveSupport::TestCase
    def setup
      PresenceRegistry.reset!
    end

    def teardown
      PresenceRegistry.reset!
    end

    test "records a participant and returns it in the roster" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter", "colour" => "#61afef",
                                     "current_file" => "app/models/user.rb", "rtt" => 12})

      entry = PresenceRegistry.roster["abc"]
      assert_equal "Swift Otter",          entry["name"]
      assert_equal "#61afef",              entry["colour"]
      assert_equal "app/models/user.rb",   entry["current_file"]
      assert_equal 12,                     entry["rtt"]
      assert_equal "abc",                  entry["client_id"]
    end

    test "re-recording the same client updates in place rather than duplicating" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter", "current_file" => "a.rb"})
      PresenceRegistry.record("abc", {"name" => "Swift Otter", "current_file" => "b.rb"})

      assert_equal %w[abc], PresenceRegistry.roster.keys
      assert_equal "b.rb", PresenceRegistry.roster["abc"]["current_file"]
    end

    test "remove drops the participant" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter"})
      PresenceRegistry.remove("abc")

      assert_empty PresenceRegistry.roster
    end

    test "removing an unknown client is a no-op" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter"})

      assert_nothing_raised { PresenceRegistry.remove("never-seen") }
      assert_equal %w[abc], PresenceRegistry.roster.keys
    end

    test "a blank client id is not recorded" do
      PresenceRegistry.record("", {"name" => "Nobody"})
      PresenceRegistry.record(nil, {"name" => "Nobody"})

      assert_empty PresenceRegistry.roster
    end

    # The payload is relayed verbatim to every other participant, so it is a
    # boundary: anything not in RELAYED_FIELDS must not survive the round trip.
    test "unknown fields in the payload are dropped" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter", "evil" => "<script>",
                                     "workspace_root" => "/home/someone/secrets"})

      entry = PresenceRegistry.roster["abc"]
      assert_nil entry["evil"]
      assert_nil entry["workspace_root"]
    end

    test "idle is measured from the last heartbeat on a monotonic clock" do
      PresenceRegistry.record("abc", { "name" => "Swift Otter" }, now: 1000.0)

      assert_equal 0,  PresenceRegistry.roster(now: 1000.0)["abc"]["idle"]
      assert_equal 42, PresenceRegistry.roster(now: 1042.4)["abc"]["idle"]
    end

    test "the roster never leaks the raw last_seen clock reading" do
      PresenceRegistry.record("abc", {"name" => "Swift Otter"})

      assert_nil PresenceRegistry.roster["abc"]["last_seen"]
    end
  end
end
