# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ExceptionLogTest < Minitest::Test
    ROOT = "/workspace/app"

    def setup
      ExceptionLog.clear!
    end

    def teardown
      ExceptionLog.clear!
    end

    # Builds a real exception with a synthetic backtrace: the frames are the
    # thing under test and a natural raise wouldn't produce interesting ones.
    def boom(backtrace, message: "kaboom", klass: RuntimeError)
      error = klass.new(message)
      error.set_backtrace(backtrace)
      error
    end

    def record(error, payload = {})
      ExceptionLog.record(error, payload, workspace_root: ROOT)
    end

    def test_records_class_message_and_request_context
      entry = record(boom([]), { controller: "ArticlesController", action: "show", path: "/articles/1" })

      assert_equal "exception", entry[:type]
      assert_equal "RuntimeError", entry[:klass]
      assert_equal "kaboom", entry[:message]
      assert_equal "ArticlesController", entry[:controller]
      assert_equal "show", entry[:action]
      assert_equal "/articles/1", entry[:path]
    end

    def test_keeps_only_workspace_frames_and_strips_the_root
      entry = record(boom([
        "/usr/lib/ruby/gems/actionpack-8.0/lib/action_controller/metal.rb:12:in 'dispatch'",
        "#{ROOT}/models/article.rb:42:in 'publish'",
        "/some/other/checkout/app.rb:9:in 'run'",
        "#{ROOT}/controllers/articles_controller.rb:7:in 'show'"
      ]))

      assert_equal([{ file: "models/article.rb", line: 42 },
                    { file: "controllers/articles_controller.rb", line: 7 }],
                   entry[:frames],
                   "gem and out-of-workspace frames are neither openable nor ours to expose")
    end

    def test_never_emits_an_absolute_path
      entry = record(boom(["#{ROOT}/models/article.rb:42:in 'publish'"]))

      refute_includes entry.to_s, ROOT, "an absolute host path is a leak and useless to the editor"
    end

    def test_caps_the_frame_count
      frames = Array.new(40) { |i| "#{ROOT}/models/a#{i}.rb:#{i}:in 'x'" }
      assert_equal ExceptionLog::MAX_FRAMES, record(boom(frames))[:frames].length
    end

    def test_tolerates_a_nil_backtrace_and_an_unset_workspace_root
      assert_equal [], record(boom(nil))[:frames]
      assert_equal [], ExceptionLog.record(boom(["#{ROOT}/a.rb:1:in 'x'"]), {}, workspace_root: nil)[:frames]
    end

    def test_ring_drops_the_oldest_and_reports_newest_first
      (ExceptionLog::MAX_ENTRIES + 5).times { |i| record(boom([], message: "e#{i}")) }

      entries = ExceptionLog.entries
      assert_equal ExceptionLog::MAX_ENTRIES, entries.length
      assert_equal "e#{ExceptionLog::MAX_ENTRIES + 4}", entries.first[:message], "newest first"
      assert_equal "e5", entries.last[:message], "the first five aged out"
    end

    def test_ids_are_unique_so_the_ui_can_key_on_them
      3.times { record(boom([])) }
      ids = ExceptionLog.entries.map { |e| e[:id] }

      assert_equal ids.uniq, ids
    end

    def test_recording_nil_is_a_no_op
      assert_nil ExceptionLog.record(nil, {}, workspace_root: ROOT)
      assert_empty ExceptionLog.entries
    end

    def test_truncates_an_enormous_message
      entry = record(boom([], message: "x" * 5000))

      assert_operator entry[:message].length, :<=, 2000
    end
  end
end
