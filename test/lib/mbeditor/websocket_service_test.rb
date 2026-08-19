# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # This suite skips in minimal compatibility bundles.
end

module Mbeditor
  # The files_changed coalescer turns a burst of per-file broadcasts into one
  # fan-out. Its merge rules carry two invariants that are silent when broken:
  # a path-less broadcast must never be narrowed by paths from the same burst,
  # and `structural` must union across the burst.
  class WebsocketServiceTest < ActiveSupport::TestCase
    def setup
      skip "MiniRacer is not installed in this compatibility bundle" unless defined?(::MiniRacer)

      @context = MiniRacer::Context.new
      # websocket_service.js reaches for window/ActionCable at call time, not at
      # load time, so a bare global object is enough to evaluate it.
      @context.eval("var window = this; window.location = { protocol: 'http:', host: 'x' };")
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/websocket_service.js")))
    end

    # Feeds broadcasts through the merge and returns the payload that would be
    # dispatched to subscribers.
    def coalesce(broadcasts)
      @context.eval(<<~JS)
        (function () {
          var acc = null;
          var input = #{JSON.generate(broadcasts)};
          for (var i = 0; i < input.length; i++) {
            acc = WebSocketService._mergeFilesChanged(acc, input[i]);
          }
          return WebSocketService._coalescedPayload(acc);
        })()
      JS
    end

    test "a burst of single-file saves collapses to one payload naming each file" do
      payload = coalesce([
        { "paths" => ["a.rb"], "structural" => false },
        { "paths" => ["b.rb"], "structural" => false },
        { "paths" => ["c.rb"], "structural" => false }
      ])

      assert_equal %w[a.rb b.rb c.rb], payload["paths"]
      assert_equal false, payload["structural"]
    end

    test "repeated saves of one file are deduplicated" do
      payload = coalesce([
        { "paths" => ["a.rb"], "structural" => false },
        { "paths" => ["a.rb"], "structural" => false }
      ])

      assert_equal ["a.rb"], payload["paths"]
    end

    test "a path-less broadcast in the burst drops paths so the re-check stays total" do
      # The path-less broadcast means "something changed, re-check everything".
      # Emitting only a.rb would silently narrow that to one file.
      payload = coalesce([
        { "paths" => ["a.rb"], "structural" => false },
        { "structural" => true }
      ])

      assert_nil payload["paths"]
      assert_equal true, payload["structural"]
    end

    test "one structural broadcast makes the whole burst structural" do
      # Otherwise the tree walk is skipped and a created or deleted file never
      # appears in the explorer.
      payload = coalesce([
        { "paths" => ["a.rb"], "structural" => false },
        { "paths" => ["new_dir/b.rb"], "structural" => true },
        { "paths" => ["c.rb"], "structural" => false }
      ])

      assert_equal true, payload["structural"]
      assert_equal %w[a.rb new_dir/b.rb c.rb], payload["paths"]
    end

    test "a broadcast with no structural field counts as structural" do
      # An older server omits the field; the conservative read is the safe one.
      payload = coalesce([{ "paths" => ["a.rb"] }])

      assert_equal true, payload["structural"]
    end

    test "a burst of only content saves never asks for a tree walk" do
      payload = coalesce(Array.new(20) { |i| { "paths" => ["f#{i}.rb"], "structural" => false } })

      assert_equal false, payload["structural"]
      assert_equal 20, payload["paths"].length
    end
  end
end
