# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class LockedJsonFileTest < ActiveSupport::TestCase
    test "read returns empty hash when the file does not exist" do
      Dir.mktmpdir do |dir|
        file = LockedJsonFile.new(File.join(dir, "missing.json"), lock_timeout: 1.0)
        assert_equal({}, file.read)
      end
    end

    test "write / read round-trips a hash" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "data.json")
        file = LockedJsonFile.new(path, lock_timeout: 1.0)
        file.write({ "a" => 1 })
        assert_equal({ "a" => 1 }, file.read)
      end
    end

    test "write replaces the file by rename rather than truncating it in place" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "data.json")
        file = LockedJsonFile.new(path, lock_timeout: 1.0)
        file.write({ "a" => 1 })
        inode_before = File.stat(path).ino
        file.write({ "a" => 2 })
        assert_not_equal inode_before, File.stat(path).ino, "write should replace the file via rename, not edit it in place"
        assert_equal({ "a" => 2 }, file.read)
        assert_not File.exist?("#{path}.tmp"), "the tmp sidecar should not survive a successful write"
      end
    end

    test "with_lock raises the given error_class instead of blocking forever behind a held lock" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "data.json")
        file = LockedJsonFile.new(path, lock_timeout: 0.2, error_class: FileHistoryService::LockTimeoutError)
        holder = File.open("#{path}.lock", File::RDWR | File::CREAT)
        holder.flock(File::LOCK_EX)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(FileHistoryService::LockTimeoutError) do
          file.with_lock { flunk "block must not run while the lock is held elsewhere" }
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 2.0, "must not hang indefinitely behind a stuck lock holder"
      ensure
        holder&.flock(File::LOCK_UN)
        holder&.close
      end
    end

    test "with_lock creates parent directories for the sidecar lock file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "data.json")
        file = LockedJsonFile.new(path, lock_timeout: 1.0)
        ran = false
        file.with_lock { ran = true }
        assert ran
      end
    end
  end
end
