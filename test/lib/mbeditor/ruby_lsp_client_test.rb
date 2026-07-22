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
                                   position: { line: 0, character: 4 })
    end

    test "handshake completes and a definition request round-trips" do
      result = definition_request

      assert_equal :ready, client.state
      assert_kind_of Array, result
      assert_equal "file://#{@root}/app.rb", result.first["uri"]
      assert_equal 4, result.first.dig("range", "start", "line")
    end

    test "multi-byte UTF-8 responses are framed by byte length" do
      result = client.request_with_document("textDocument/hover", File.join(@root, "app.rb"), "x = 1\n",
                                            position: { line: 0, character: 0 })

      assert_includes result.dig("contents", "value"), "snowman ☃"
    end

    test "documents are opened once and re-sent as full-text changes with version bumps" do
      definition_request(content: "v1\n")
      definition_request(content: "v1\n") # unchanged — no didChange
      definition_request(content: "v2\n") # changed — didChange v2

      log = client.request("fake/syncLog", nil)
      opens   = log.select { |e| e["type"] == "open" }
      changes = log.select { |e| e["type"] == "change" }
      assert_equal 1, opens.length
      assert_equal 1, opens.first["version"]
      assert_equal 1, changes.length
      assert_equal 2, changes.first["version"]
    end

    test "a slow response raises TimeoutError and the process survives for later requests" do
      use_fake_server("FAKE_LSP_DELAY_MS" => "700")
      Mbeditor.configuration.ruby_lsp_timeout = 0.3
      RubyLspClient.reset!

      assert_raises(RubyLspClient::TimeoutError) do
        client.request_with_document("textDocument/definition", File.join(@root, "app.rb"), "x\n",
                                     position: { line: 0, character: 0 })
      end

      result = client.request("textDocument/hover", { textDocument: { uri: "file://#{@root}/app.rb" },
                                                      position: { line: 0, character: 0 } }, timeout: 5)
      assert result, "process should still answer after an earlier timeout"
      assert_equal :ready, client.state
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
                                       position: { line: 0, character: 0 })
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
