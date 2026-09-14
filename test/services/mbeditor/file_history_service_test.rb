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
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "x"]], base: "", base_given: true, version: 2)

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
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "main-a"]], base: "", base_given: true, version: 2)
        service.append("feature", "a.rb", ops: [[1, 1, 1, 1, "feature-a"]], base: "", base_given: true, version: 2)
        service.append("main", "b.rb", ops: [[1, 1, 1, 1, "main-b"]], base: "", base_given: true, version: 2)

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

    # --- format v2 / legacy migration (#93) ---------------------------------

    test "read folds a v1 history's leading load into the base and keeps its edits" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        write_raw_history(root, "main", "a.rb",
          "base" => "",
          "ops"  => [[1, 1, 1, 1, "file\n"], [1, 1, 1, 5, "edit"]],
          "t"    => Time.now.utc.iso8601)

        result = service.read("main", "a.rb")
        assert_equal "file\n", result["base"]
        assert_equal [[1, 1, 1, 5, "edit"]], result["ops"]
      end
    end

    test "read drops later whole-file loads from a multi-open v1 history" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        write_raw_history(root, "main", "a.rb",
          "base" => "",
          "ops"  => [
            [1, 1, 1, 1, "one\n"],      # session 1: load
            [1, 1, 1, 5, "edit1"],      # session 1: edit
            [1, 1, 1, 1, "one\nedit1"], # session 2: load (reproduces session 1's result)
            [1, 6, 1, 6, "edit2"]       # session 2: edit
          ],
          "t"    => Time.now.utc.iso8601)

        result = service.read("main", "a.rb")
        assert_equal "one\n", result["base"]
        assert_equal [[1, 1, 1, 5, "edit1"], [1, 6, 1, 6, "edit2"]], result["ops"],
          "each later load must be dropped, not concatenated onto the document"
      end
    end

    test "read rewrites a migrated history with the current format version" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        path = write_raw_history(root, "main", "a.rb",
          "base" => "", "ops" => [[1, 1, 1, 1, "file\n"]], "t" => Time.now.utc.iso8601)

        service.read("main", "a.rb")
        data = JSON.parse(File.read(path))
        assert_equal FileHistoryService::FORMAT_VERSION, data["v"]
        assert_equal "file\n", data["base"]
        assert_equal [], data["ops"]
      end
    end

    test "read leaves a current-format history untouched" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        write_raw_history(root, "main", "a.rb",
          "v" => FileHistoryService::FORMAT_VERSION,
          "base" => "file\n", "ops" => [[1, 1, 1, 1, "x"]], "t" => Time.now.utc.iso8601)

        result = service.read("main", "a.rb")
        assert_equal "file\n", result["base"]
        assert_equal [[1, 1, 1, 1, "x"]], result["ops"]
      end
    end

    test "append folds a legacy load payload into the base and stamps v2" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        service = FileHistoryService.new(root)
        service.append("main", "a.rb",
          ops: [[1, 1, 1, 1, "file\n"], [1, 1, 1, 5, "edit"]], base: "", base_given: true)

        result = service.read("main", "a.rb")
        assert_equal "file\n", result["base"]
        assert_equal [[1, 1, 1, 5, "edit"]], result["ops"]
      end
    end

    test "append does not fold an empty base sent by a current-format client" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir))
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "x"]], base: "", base_given: true, version: 2)

        result = service.read("main", "a.rb")
        assert_equal "", result["base"]
        assert_equal [[1, 1, 1, 1, "x"]], result["ops"]
      end
    end

    test "append compacts when the serialized history exceeds the byte budget" do
      Dir.mktmpdir do |dir|
        service = FileHistoryService.new(Pathname.new(dir), max_bytes: 50)
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "hello world"]], base: "base", base_given: true, version: 2)
        service.append("main", "a.rb", ops: [[1, 1, 1, 1, "again and again"]], base_given: false, version: 2)

        result = service.read("main", "a.rb")
        assert_equal [], result["ops"], "a byte overage must fold the op log into the base"
      end
    end

    private

    # Writes a history file directly in the exact hash FileHistoryService derives
    # from branch+path, bypassing append so tests can seed legacy shapes.
    def write_raw_history(root, branch, rel_path, data)
      hist_dir  = root.join("tmp", "mbeditor_history")
      FileUtils.mkdir_p(hist_dir)
      branch_hash = Digest::SHA256.hexdigest(branch)[0, 16]
      file_hash   = Digest::SHA256.hexdigest(rel_path)[0, 16]
      path = hist_dir.join("#{branch_hash}_#{file_hash}.json")
      File.write(path, JSON.dump(data))
      path
    end
  end
end
