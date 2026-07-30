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
  when "textDocument/didClose"
    sync_log << { "type" => "close", "uri" => msg.dig("params", "textDocument", "uri") }
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
      # Shaped like ruby-lsp's real hover: a title, a "Definitions" line of
      # file:// links (one in-workspace, one from a gem), then the docs.
      # Non-ASCII on purpose: exercises byte-length Content-Length framing.
      uri = msg.dig("params", "textDocument", "uri")
      { "contents" => { "kind" => "markdown", "value" => <<~MD } }
        ```ruby
        User
        ```

        **Definitions**: [user.rb](#{uri}#L3,1-9,4) | [set.rb](file:///gems/set/lib/set.rb#L2,1-2,3)

        **fake hover** — snowman ☃

        # Doc comment opened with ## in the source
        Body of the comment.
      MD
    when "textDocument/references"
      # One in-workspace hit and one in a gem: the gem location must be dropped
      # by the controller's URI sanitizer before it reaches the browser.
      uri = msg.dig("params", "textDocument", "uri")
      [{ "uri" => uri,
         "range" => { "start" => { "line" => 6, "character" => 4 },
                      "end" => { "line" => 6, "character" => 8 } } },
       { "uri" => "file:///gems/activesupport/lib/thing.rb",
         "range" => { "start" => { "line" => 1, "character" => 0 },
                      "end" => { "line" => 1, "character" => 4 } } }]
    when "textDocument/documentHighlight"
      [{ "range" => { "start" => { "line" => 2, "character" => 4 },
                      "end" => { "line" => 2, "character" => 8 } }, "kind" => 1 },
       { "range" => { "start" => { "line" => 5, "character" => 2 },
                      "end" => { "line" => 5, "character" => 6 } }, "kind" => 2 }]
    when "textDocument/documentSymbol"
      [{ "name" => "User", "kind" => 5,
         "range" => { "start" => { "line" => 0, "character" => 0 },
                      "end" => { "line" => 8, "character" => 3 } },
         "selectionRange" => { "start" => { "line" => 0, "character" => 6 },
                               "end" => { "line" => 0, "character" => 10 } },
         "children" => [
           { "name" => "full_name", "kind" => 6,
             "range" => { "start" => { "line" => 2, "character" => 2 },
                          "end" => { "line" => 4, "character" => 5 } },
             "selectionRange" => { "start" => { "line" => 2, "character" => 6 },
                                   "end" => { "line" => 2, "character" => 15 } },
             "children" => [] }
         ] }]
    when "textDocument/foldingRange"
      [{ "startLine" => 0, "endLine" => 8 },
       { "startLine" => 2, "endLine" => 4, "kind" => "comment" }]
    when "textDocument/formatting"
      # Echo the options back in the replacement so tests can assert they were
      # forwarded, alongside a normal whole-document edit.
      opts = msg.dig("params", "options") || {}
      [{ "range" => { "start" => { "line" => 0, "character" => 0 },
                      "end" => { "line" => 1, "character" => 0 } },
         "newText" => "# formatted tabSize=#{opts['tabSize']} insertSpaces=#{opts['insertSpaces']}\n" }]
    when "textDocument/signatureHelp"
      # Documentation embeds a file:// "Definitions" line, exactly as ruby-lsp's
      # does — the controller must not let that absolute path reach the browser.
      uri = msg.dig("params", "textDocument", "uri")
      { "signatures" => [
          { "label" => "full_name(first, last)",
            "documentation" => { "kind" => "markdown",
                                 "value" => "Joins the two names.\n\n**Definitions**: " \
                                            "[user.rb](#{uri}#L2,3-4,6) | " \
                                            "[set.rb](file:///gems/set/lib/set.rb#L2,1-2,3)" },
            "parameters" => [{ "label" => "first" }, { "label" => "last" }] }
        ],
        "activeSignature" => 0, "activeParameter" => 1 }
    when "textDocument/selectionRange"
      # A linked list: innermost range first, widening through `parent`.
      [{ "range" => { "start" => { "line" => 2, "character" => 4 },
                      "end" => { "line" => 2, "character" => 8 } },
         "parent" => {
           "range" => { "start" => { "line" => 2, "character" => 0 },
                        "end" => { "line" => 2, "character" => 20 } },
           "parent" => {
             "range" => { "start" => { "line" => 0, "character" => 0 },
                          "end" => { "line" => 5, "character" => 3 } }
           }
         } }]
    when "textDocument/completion"
      { "items" => [{ "label" => "fake_method", "kind" => 2,
                      "insertText" => "fake_method", "detail" => "FakeClass#fake_method" }] }
    when "textDocument/diagnostic"
      # One RuboCop-shaped (correctable, carries a cop name) and one
      # Prism-shaped (syntax error, no cop name) diagnostic.
      uri = msg.dig("params", "textDocument", "uri")
      { "kind" => "full", "items" => [
        { "source" => "RuboCop",
          "code" => "Layout/SpaceAroundOperators",
          # camelCase: this is the LSP wire key, not the Ruby keyword argument.
          "codeDescription" => {
            "href" => "https://docs.rubocop.org/rubocop/cops_layout.html#layoutspacearoundoperators"
          },
          "severity" => 3,
          "message" => "Surrounding space missing for operator `=`.",
          "range" => { "start" => { "line" => 2, "character" => 4 },
                       "end" => { "line" => 2, "character" => 5 } },
          # ruby-lsp embeds the complete fix edits here; its codeAction handler
          # only echoes them back, so the editor applies them with no request.
          "data" => {
            "correctable" => true,
            "code_actions" => [
              { "title" => "Autocorrect Layout/SpaceAroundOperators",
                "kind" => "quickfix",
                "isPreferred" => true,
                "edit" => { "documentChanges" => [
                  { "textDocument" => { "version" => nil, "uri" => uri },
                    "edits" => [
                      { "range" => { "start" => { "line" => 2, "character" => 4 },
                                     "end" => { "line" => 2, "character" => 5 } },
                        "newText" => " = " }
                    ] }
                ] } },
              { "title" => "Disable Layout/SpaceAroundOperators for this line",
                "kind" => "quickfix",
                "edit" => { "documentChanges" => [
                  { "textDocument" => { "version" => nil, "uri" => uri },
                    "edits" => [
                      { "range" => { "start" => { "line" => 2, "character" => 8 },
                                     "end" => { "line" => 2, "character" => 8 } },
                        "newText" => " # rubocop:disable Layout/SpaceAroundOperators" }
                    ] }
                ] } }
            ]
          } },
        { "source" => "Prism",
          "severity" => 1,
          "message" => "unexpected end-of-input",
          "range" => { "start" => { "line" => 9, "character" => 0 },
                       "end" => { "line" => 9, "character" => 3 } } }
      ] }
    when "fake/syncLog"
      sync_log
    end

  write_msg({ "jsonrpc" => "2.0", "id" => id, "result" => result })
end
