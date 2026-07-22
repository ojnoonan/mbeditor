#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal stdio LSP server used by RubyLspClient tests — speaks Content-Length
# JSON-RPC with canned responses, no ruby-lsp dependency.
#
# Env knobs:
#   FAKE_LSP_DELAY_MS            sleep before answering non-initialize requests
#   FAKE_LSP_CRASH_AFTER         exit!(1) when more than N id'd requests handled
#   FAKE_LSP_SEND_SERVER_REQUEST send a workspace/configuration server request
#                                during initialize (client must answer it)
#
# Test hook: the custom request "fake/syncLog" returns the didOpen/didChange
# notifications received so far, so tests can assert document-sync behavior.

require "json"

STDOUT.binmode
STDIN.binmode
STDOUT.sync = true

DELAY_MS    = ENV["FAKE_LSP_DELAY_MS"].to_i
CRASH_AFTER = ENV["FAKE_LSP_CRASH_AFTER"].to_i

def write_msg(payload)
  json = JSON.generate(payload)
  STDOUT.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
end

def read_msg
  content_length = nil
  loop do
    line = STDIN.gets("\r\n")
    return nil if line.nil?

    line = line.chomp("\r\n")
    break if line.empty?

    content_length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)\z/i
  end
  return nil if content_length.nil?

  body = STDIN.read(content_length)
  return nil if body.nil?

  JSON.parse(body)
end

sync_log = []
handled = 0

loop do
  msg = read_msg
  break if msg.nil?

  method = msg["method"]
  id     = msg["id"]

  case method
  when "textDocument/didOpen"
    sync_log << { "type" => "open",
                  "uri" => msg.dig("params", "textDocument", "uri"),
                  "version" => msg.dig("params", "textDocument", "version") }
    next
  when "textDocument/didChange"
    sync_log << { "type" => "change",
                  "uri" => msg.dig("params", "textDocument", "uri"),
                  "version" => msg.dig("params", "textDocument", "version") }
    next
  when "initialized"
    next
  when "exit"
    exit 0
  end

  next unless id # other notifications: ignore

  sleep(DELAY_MS / 1000.0) if DELAY_MS.positive? && method != "initialize"

  handled += 1
  exit!(1) if CRASH_AFTER.positive? && handled > CRASH_AFTER

  result =
    case method
    when "initialize"
      if ENV["FAKE_LSP_SEND_SERVER_REQUEST"] == "1"
        write_msg({ "jsonrpc" => "2.0", "id" => 9999,
                    "method" => "workspace/configuration",
                    "params" => { "items" => [{}] } })
      end
      { "capabilities" => {} }
    when "shutdown"
      nil
    when "textDocument/definition"
      uri = msg.dig("params", "textDocument", "uri")
      [{ "uri" => uri,
         "range" => { "start" => { "line" => 4, "character" => 2 },
                      "end" => { "line" => 4, "character" => 10 } } }]
    when "textDocument/hover"
      # Non-ASCII on purpose: exercises byte-length Content-Length framing.
      { "contents" => { "kind" => "markdown", "value" => "**fake hover** — snowman ☃" } }
    when "textDocument/completion"
      { "items" => [{ "label" => "fake_method", "kind" => 2,
                      "insertText" => "fake_method", "detail" => "FakeClass#fake_method" }] }
    when "fake/syncLog"
      sync_log
    end

  write_msg({ "jsonrpc" => "2.0", "id" => id, "result" => result })
end
