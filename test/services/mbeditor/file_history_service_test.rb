# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # HTTP-level coverage of the branch+path keying, aging, and corrupt-file
  # handling already lives in editors_controller_test.rb's file_history tests.
  # This file covers what those don't reach directly: the locking/atomic-write
  # contract, compaction arithmetic, and the base_given tri-state.
  class FileHistoryServiceTest < ActiveSupport::TestCase
    test "read returns nil when there is no history for the branch+path" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        assert_nil service.read("main", "app/models/user.rb")
      end
    end

    test "append seeds history with base on first write, read returns it back" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "hello"]], base: "class A; end\n", base_given: true)

        result = service.read("main", "a.rb")
        assert_equal "class A; end\n", result["base"]
        assert_equal [[1, 1, 1, 1, "hello"]], result["ops"]
      end
    end

    test "append accepts an explicit empty base as a legitimate first snapshot" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "x"]], base: "", base_given: true)

        assert_equal "", service.read("main", "a.rb")["base"]
      end
    end

    test "append raises BaseRequiredError when base_given is false on the first write" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        assert_raises(FileHistoryService::BaseRequiredError) do
          service.append("main", "a.rb", ops: [[1, 1, 1, 1, "x"]], base_given: false)
        end
      end
    end

    test "append raises BaseTooLargeError when base exceeds BASE_MAX_BYTES" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        oversized = "x" * (FileHistoryService::BASE_MAX_BYTES + 1)
        assert_raises(FileHistoryService::BaseTooLargeError) do
          service.append("main", "a.rb", ops: [], base: oversized, base_given: true)
        end
      end
    end

    test "append does not require base on a subsequent write" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "hello"]], base: "x", base_given: true)
        service.append("main", "a.rb", ops: [[1, 6, 1, 6, " world"]], base_given: false)

        result = service.read("main", "a.rb")
        assert_equal 2, result["ops"].length
        assert_equal [1, 6, 1, 6, " world"], result["ops"].last
      end
    end

    test "append keeps separate history per branch and per path" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "main-a"]], base: "", base_given: true)
        service.append("feature", "a.rb", ops: [[1, 1, 1, 1, "feature-a"]], base: "", base_given: true)
        service.append("main", "b.rb", ops: [[1, 1, 1, 1, "main-b"]], base: "", base_given: true)

        assert_equal [[1, 1, 1, 1, "main-a"]], service.read("main", "a.rb")["ops"]
        assert_equal [[1, 1, 1, 1, "feature-a"]], service.read("feature", "a.rb")["ops"]
        assert_equal [[1, 1, 1, 1, "main-b"]], service.read("main", "b.rb")["ops"]
      end
    end

    test "append compacts the op log into base once it exceeds MAX_OPS, replaying the compacted ops" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        first_ops = Array.new(FileHistoryService::MAX_OPS) { [1, 1, 1, 1, "x"] }
        service.append("main", "a.rb", ops: first_ops, base: "line\n", base_given: true)
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "y"]], base_given: false)

        result = service.read("main", "a.rb")
        assert_equal FileHistoryService::MAX_OPS - FileHistoryService::COMPACT_TARGET + 1, result["ops"].length
        # The compacted-away ops must still be reflected in base: COMPACT_TARGET
        # insertions of "x" at (1,1)-(1,1) each prepend, so base ends up
        # "x"*COMPACT_TARGET followed by the original content.
        assert_equal "x" * FileHistoryService::COMPACT_TARGET + "line\n", result["base"]
      end
    end

    test "read prunes and returns nil when history is older than MAX_AGE_SECONDS" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        service.append("main", "a.rb", ops: [], base: "x", base_given: true)

        hist_dir = root.join("tmp", "mbeditor_history")
        hist_file = Dir.glob(hist_dir.join("*.json")).first
        data = JSON.parse(File.read(hist_file))
        data["t"] = (Time.now.utc - (FileHistoryService::MAX_AGE_SECONDS + 1)).iso8601
        File.write(hist_file, data.to_json)

        assert_nil service.read("main", "a.rb")
        assert_not File.exist?(hist_file)
      end
    end

    test "read deletes and returns nil for a corrupted history file" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        hist_dir = root.join("tmp", "mbeditor_history")
        FileUtils.mkdir_p(hist_dir)
        branch_hash = Digest::SHA256.hexdigest("main")[0, 16]
        file_hash   = Digest::SHA256.hexdigest("a.rb")[0, 16]
        hist_file   = hist_dir.join("#{branch_hash}_#{file_hash}.json")
        File.write(hist_file, "not json {{{")

        assert_nil service.read("main", "a.rb")
        assert_not File.exist?(hist_file)
      end
    end

    test "prune removes history files for branches no longer active" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        service.append("main", "a.rb", ops: [], base: "x", base_given: true)
        service.append("ghost-branch", "a.rb", ops: [], base: "x", base_given: true)

        service.prune(active_branches: ["main"])

        assert service.read("main", "a.rb")
        assert_nil service.read("ghost-branch", "a.rb")
      end
    end

    test "prune is a no-op when the history directory does not exist" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        assert_nil service.prune(active_branches: ["main"])
      end
    end

    test "append fails fast with LockTimeoutError instead of blocking on a held lock" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root, lock_timeout: 0.2)
        branch_hash = Digest::SHA256.hexdigest("main")[0, 16]
        file_hash   = Digest::SHA256.hexdigest("a.rb")[0, 16]
        hist_path = root.join("tmp", "mbeditor_history", "#{branch_hash}_#{file_hash}.json")
        FileUtils.mkdir_p(hist_path.dirname)
        holder = File.open("#{hist_path}.lock", File::RDWR | File::CREAT)
        holder.flock(File::LOCK_EX)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(FileHistoryService::LockTimeoutError) do
          service.append("main", "a.rb", ops: [], base: "x", base_given: true)
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 2.0, "a save must not hang indefinitely behind a stuck lock holder"
      ensure
        holder&.flock(File::LOCK_UN)
        holder&.close
      end
    end
  end
end
