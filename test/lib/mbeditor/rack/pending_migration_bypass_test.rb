# frozen_string_literal: true

require "test_helper"

module Mbeditor
  module Rack
    # A pending migration used to lock the developer out of the editor that
    # exists to let them fix it: every request raised, so the tree, opening a
    # file, saving one, and the page's own assets all failed. These pin the two
    # halves of the contract — editor traffic must get through, host traffic
    # must still be stopped exactly as Rails intends.
    class PendingMigrationBypassTest < ActiveSupport::TestCase
      # Stands in for ActiveRecord::Migration::CheckPending: raises until told
      # otherwise, and records whether the downstream app was reached.
      class FakeCheck
        attr_reader :calls

        def initialize(app, raising:)
          @app = app
          @raising = raising
          @calls = 0
        end

        def call(env)
          @calls += 1
          raise ActiveRecord::PendingMigrationError if @raising

          @app.call(env)
        end
      end

      def build(raising:, downstream: nil)
        reached = []
        app = downstream || lambda do |env|
          reached << "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
          [200, { "Content-Type" => "text/plain" }, ["ok"]]
        end
        middleware = Mbeditor::Rack::PendingMigrationBypass.allocate
        middleware.instance_variable_set(:@app, app)
        middleware.instance_variable_set(:@checked, FakeCheck.new(app, raising: raising))
        [middleware, reached]
      end

      def env_for(path)
        { "SCRIPT_NAME" => "", "PATH_INFO" => path, "REQUEST_METHOD" => "GET" }
      end

      setup { Mbeditor::PendingMigrations.clear }
      teardown { Mbeditor::PendingMigrations.clear }

      test "an editor API request still reaches the app while migrations are pending" do
        middleware, reached = build(raising: true)

        status, headers, body = middleware.call(env_for("/mbeditor/files"))

        assert_equal 200, status
        assert_equal ["ok"], body
        assert_equal ["/mbeditor/files"], reached
        assert headers[Mbeditor::Rack::PendingMigrationBypass::PENDING_HEADER],
               "the response should still announce the pending migration"
      end

      test "the assets the editor page loads are not blocked either" do
        # The shell is inert without these, and they live outside the mount, so
        # an mbeditor-path-only guard left the editor unable to boot.
        middleware, reached = build(raising: true)

        status, = middleware.call(env_for("/assets/mbeditor/application.js"))

        assert_equal 200, status
        assert_equal ["/assets/mbeditor/application.js"], reached
      end

      test "host application traffic is still blocked exactly as Rails intends" do
        middleware, reached = build(raising: true)

        assert_raises(ActiveRecord::PendingMigrationError) do
          middleware.call(env_for("/orders"))
        end
        assert_empty reached, "the host request must not reach the app"
      end

      test "the pending message is recorded so the editor can warn about it" do
        middleware, = build(raising: true)

        middleware.call(env_for("/mbeditor/files"))

        assert Mbeditor::PendingMigrations.pending?
        assert_match(/migration/i, Mbeditor::PendingMigrations.message)
      end

      test "a passing check clears a previously recorded message" do
        # Otherwise the banner would outlive the migration that caused it.
        Mbeditor::PendingMigrations.note("Migrations are pending")
        middleware, = build(raising: false)

        _status, headers, = middleware.call(env_for("/mbeditor/files"))

        refute Mbeditor::PendingMigrations.pending?
        assert_nil headers[Mbeditor::Rack::PendingMigrationBypass::PENDING_HEADER]
      end

      test "the request is dispatched once, not twice" do
        # CheckPending raises before touching the app, so the bypass dispatches
        # afterwards. If it ever raised *after*, a save would be applied twice.
        middleware, reached = build(raising: true)

        middleware.call(env_for("/mbeditor/file"))

        assert_equal 1, reached.length
      end

      test "a non-migration error is never swallowed" do
        boom = lambda { |_env| raise ArgumentError, "unrelated" }
        middleware = Mbeditor::Rack::PendingMigrationBypass.allocate
        middleware.instance_variable_set(:@app, boom)
        middleware.instance_variable_set(:@checked, boom)

        assert_raises(ArgumentError) { middleware.call(env_for("/mbeditor/files")) }
      end

      test "the header carries no newlines" do
        # PendingMigrationError's message is multi-line; a raw header value
        # would be an invalid response.
        middleware, = build(raising: true)

        _status, headers, = middleware.call(env_for("/mbeditor/files"))

        refute_includes headers[Mbeditor::Rack::PendingMigrationBypass::PENDING_HEADER], "\n"
      end
    end
  end
end
