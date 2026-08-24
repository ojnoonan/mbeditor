# frozen_string_literal: true

require "test_helper"
require "rbconfig"

module Mbeditor
  class RubyLspClientTest < ActiveSupport::TestCase
    FAKE_SERVER = File.expand_path("../../fixtures/fake_lsp_server.rb", __dir__)

    def setup
      @root = Dir.mktmpdir("mbeditor_lsp_client_")
      @original_command = Mbeditor.configuration.ruby_lsp_command
      @original_timeout = Mbeditor.configuration.ruby_lsp_timeout
      use_fake_server
      RubyLspClient.reset!
    end

    def teardown
      RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = @original_command
      Mbeditor.configuration.ruby_lsp_timeout = @original_timeout
      FileUtils.rm_rf(@root)
    end

    def use_fake_server(env = {})
      cmd = [RbConfig.ruby, FAKE_SERVER]
      cmd = ["env"] + env.map { |k, v| "#{k}=#{v}" } + cmd unless env.empty?
      Mbeditor.configuration.ruby_lsp_command = cmd
    end

    def client
      RubyLspClient.for(@root)
    end

    def definition_request(content: "def x\nend\n", path: "app.rb")
      client.request_with_document("textDocument/definition", File.join(@root, path), content,
                                   { position: { line: 0, character: 4 } })
    end

    test "handshake completes and a definition request round-trips" do
      result = definition_request

      assert_equal :ready, client.state
      assert_kind_of Array, result
      assert_equal "file://#{@root}/app.rb", result.first["uri"]
      assert_equal 4, result.first.dig("range", "start", "line")
    end

    # A raw path is not a URI: a space raises URI::InvalidURIError inside
    # ruby-lsp and a `#` truncates the path at the fragment, so every request
    # against such a file failed.
    test "a path with characters that are illegal in a URI is percent-escaped" do
      result = definition_request(path: "has space#hash.rb")

      assert_equal "file://#{@root}/has%20space%23hash.rb", result.first["uri"]
    end

    test "a positionless diagnostics request round-trips a full document report" do
      result = client.request_with_document("textDocument/diagnostic", File.join(@root, "app.rb"), "x=1\n", {})

      assert_equal "full", result["kind"]
      assert_equal 2, result["items"].length
      assert_equal "RuboCop", result["items"].first["source"]
      assert_equal true, result["items"].first.dig("data", "correctable")
    end

    test "multi-byte UTF-8 responses are framed by byte length" do
      result = client.request_with_document("textDocument/hover", File.join(@root, "app.rb"), "x = 1\n",
                                            { position: { line: 0, character: 0 } })

      assert_includes result.dig("contents", "value"), "snowman ☃"
    end

    # ruby-lsp only supports INCREMENTAL sync — a rangeless full-text
    # didChange raises inside its Document#push_edits and leaves the server
    # holding stale content. Changed buffers must therefore be re-opened.
    test "an unchanged buffer is not re-synced and a changed one is re-opened" do
      definition_request(content: "v1\n")
      definition_request(content: "v1\n") # unchanged — no traffic
      definition_request(content: "v2\n") # changed — close + re-open at v2

      log = client.request("fake/syncLog", nil)
      opens   = log.select { |e| e["type"] == "open" }
      closes  = log.select { |e| e["type"] == "close" }
      changes = log.select { |e| e["type"] == "change" }

      assert_equal 2, opens.length, "one initial open plus one re-open after the edit"
      assert_equal [1, 2], opens.map { |o| o["version"] }
      assert_equal 1, closes.length, "the stale copy is closed before re-opening"
      assert_equal [], changes, "didChange is never used — ruby-lsp rejects rangeless edits"
    end

    test "a slow response raises TimeoutError and the process survives for later requests" do
      use_fake_server("FAKE_LSP_DELAY_MS" => "700")
      Mbeditor.configuration.ruby_lsp_timeout = 0.3
      RubyLspClient.reset!

      assert_raises(RubyLspClient::TimeoutError) do
        client.request_with_document("textDocument/definition", File.join(@root, "app.rb"), "x\n",
                                     { position: { line: 0, character: 0 } })
      end

      result = client.request("textDocument/hover", { textDocument: { uri: "file://#{@root}/app.rb" },
                                                      position: { line: 0, character: 0 } }, timeout: 5)
      assert result, "process should still answer after an earlier timeout"
      assert_equal :ready, client.state
    end

    # Queue#pop only takes a timeout: keyword on Ruby >= 3.2, but the gem
    # supports 3.0. Force the fallback branch so both paths are covered
    # whichever Ruby runs the suite — without this, a 3.2-only API silently
    # breaks every ruby-lsp feature on older rubies.
    def with_legacy_queue_pop
      original = RubyLspClient::QUEUE_POP_SUPPORTS_TIMEOUT
      $VERBOSE = nil
      RubyLspClient.send(:remove_const, :QUEUE_POP_SUPPORTS_TIMEOUT)
      RubyLspClient.const_set(:QUEUE_POP_SUPPORTS_TIMEOUT, false)
      $VERBOSE = true
      yield
    ensure
      $VERBOSE = nil
      RubyLspClient.send(:remove_const, :QUEUE_POP_SUPPORTS_TIMEOUT)
      RubyLspClient.const_set(:QUEUE_POP_SUPPORTS_TIMEOUT, original)
      $VERBOSE = true
    end

    test "requests round-trip on the pre-3.2 queue-pop path" do
      with_legacy_queue_pop do
        RubyLspClient.reset!
        result = definition_request
        assert_kind_of Array, result
        assert_equal :ready, client.state
      end
    end

    test "the pre-3.2 queue-pop path still times out" do
      use_fake_server("FAKE_LSP_DELAY_MS" => "700")
      Mbeditor.configuration.ruby_lsp_timeout = 0.3

      with_legacy_queue_pop do
        RubyLspClient.reset!
        assert_raises(RubyLspClient::TimeoutError) do
          client.request_with_document("textDocument/definition", File.join(@root, "app.rb"), "x\n",
                                       { position: { line: 0, character: 0 } })
        end
      end
    end

    test "a crashed server is detected and restarts after backoff" do
      # initialize counts as request 1; the first definition (2) exceeds the cap.
      use_fake_server("FAKE_LSP_CRASH_AFTER" => "1")
      RubyLspClient.reset!

      assert_raises(RubyLspClient::Error) { definition_request }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.05 until client.state == :crashed || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_equal :crashed, client.state

      # Point at a healthy server; after the 1s backoff the client restarts lazily.
      use_fake_server
      sleep 1.1
      result = definition_request
      assert_kind_of Array, result
      assert_equal :ready, client.state
    end

    test "start failure with a nonexistent command degrades to NotReadyError" do
      Mbeditor.configuration.ruby_lsp_command = ["/nonexistent/ruby-lsp-binary"]
      RubyLspClient.reset!

      assert_raises(RubyLspClient::NotReadyError) { definition_request }
    end

    test "health reports the state without booting the server" do
      assert_equal :stopped, client.health[:state], "asking how you are must not start you"
      assert_equal 0, client.health[:restarts]
      assert_nil client.health[:error]

      definition_request
      assert_equal :ready, client.health[:state]
    end

    test "health surfaces the reason a start failed" do
      Mbeditor.configuration.ruby_lsp_command = ["/nonexistent/ruby-lsp-binary"]
      RubyLspClient.reset!

      assert_raises(RubyLspClient::NotReadyError) { definition_request }

      health = client.health
      assert_equal 1, health[:restarts]
      assert_match(/nonexistent/, health[:error].to_s, "the chip needs something to show the user")
    end

    test "reset! revives a client latched at :failed" do
      Mbeditor.configuration.ruby_lsp_command = ["/nonexistent/ruby-lsp-binary"]
      RubyLspClient.reset!

      # Exhaust the crash budget: RESTART_BACKOFFS gates retries by elapsed
      # time, so drive the counter directly rather than sleeping 31 seconds.
      RubyLspClient::MAX_RESTARTS.times { client.send(:ensure_started) }
      client.instance_variable_set(:@crash_times, Array.new(RubyLspClient::MAX_RESTARTS) do
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end)
      client.send(:ensure_started)

      assert_equal :failed, client.state, "budget exhausted should latch"
      assert_raises(RubyLspClient::NotReadyError) { definition_request }

      use_fake_server
      assert client.reset!, "reset! should clear the latch and come back ready"
      assert_equal :ready, client.state
      assert_equal 0, client.health[:restarts]
      assert_nil client.health[:error]
      assert_kind_of Array, definition_request
    end

    test "server-initiated requests during initialize are answered and don't wedge the handshake" do
      use_fake_server("FAKE_LSP_SEND_SERVER_REQUEST" => "1")
      RubyLspClient.reset!

      result = definition_request
      assert_kind_of Array, result
    end

    test "concurrent threaded requests each get their own response" do
      results = 4.times.map do |i|
        Thread.new do
          client.request_with_document("textDocument/definition", File.join(@root, "file#{i}.rb"), "x#{i}\n",
                                       { position: { line: 0, character: 0 } })
        end
      end.map(&:value)

      results.each_with_index do |r, i|
        assert_equal "file://#{@root}/file#{i}.rb", r.first["uri"]
      end
    end

    test "stop shuts the child down" do
      definition_request
      assert_equal :ready, client.state

      client.stop
      assert_equal :stopped, client.state

      out = `pgrep -f fake_lsp_server.rb`
      assert_equal "", out.strip, "no fake server process should remain after stop"
    end
  end
end
