# frozen_string_literal: true

module Mbeditor
  # Sidecar-lock + atomic-write primitive for a single JSON file on disk.
  # Extracted from EditorStateService so FileHistoryService could stop
  # hand-rolling its own flock loop and, worse, writing in place with
  # truncate/rewind — a crash mid-write there truncated history instead of
  # leaving the previous file untouched.
  class LockedJsonFile
    LockTimeoutError    = Class.new(StandardError)
    LOCK_RETRY_INTERVAL = 0.01

    def initialize(path, lock_timeout:, error_class: LockTimeoutError)
      @path = path
      @lock_timeout = lock_timeout
      @error_class = error_class
    end

    # Readers take no lock at all: every write lands by rename, so a read sees
    # either the whole previous file or the whole new one — never the empty
    # window a truncate-then-write leaves, which readers would otherwise have
    # to swallow as {}.
    def read
      return {} unless File.exist?(@path)

      raw = File.read(@path)
      raw.empty? ? {} : JSON.parse(raw)
    end

    # The file is replaced by rename, not edited in place, so a crash mid-write
    # leaves the previous contents intact rather than a truncated file.
    def write(payload)
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, payload.is_a?(String) ? payload : payload.to_json)
      File.rename(tmp, @path)
    end

    # The lock sits on a sidecar file, not on the data file itself: the data
    # file is replaced by rename, so a lock held on the inode it had before
    # the write would exclude nobody afterwards.
    #
    # Acquires the lock without blocking forever: a blocking acquire would let
    # a single stuck holder (e.g. a request paused at a breakpoint mid-write)
    # wedge every later writer indefinitely, so this retries a non-blocking
    # flock with a bounded deadline and raises rather than hanging the worker.
    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT) do |f|
        lock_exclusive!(f)
        yield
      end
    end

    private

    def lock_exclusive!(file)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise @error_class, "could not acquire lock within #{@lock_timeout}s"
        end
        sleep LOCK_RETRY_INTERVAL
      end
    end
  end
end
