# frozen_string_literal: true

require "open3"

module Mbeditor
  module ProcessRunner
    module_function

    class TimeoutError < StandardError; end

    CHUNK_BYTES = 64 * 1024
    private_constant :CHUNK_BYTES

    # +max_bytes+ bounds how much of each stream is kept in memory (nil =
    # unbounded). Anything past the cap is still read and discarded — stopping
    # would block the child on a full pipe and hang the wait below.
    def call(cmd, timeout: nil, env: {}, stdin_data: nil, chdir: nil, max_bytes: nil)
      out = +""
      err = +""
      exit_status = nil
      timed_out = false

      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir

      Open3.popen3(env, *cmd, **opts) do |stdin, stdout, stderr, wait_thr|
        stdin.write(stdin_data) if stdin_data
        stdin.close

        out_thread = Thread.new { out = read_capped(stdout, max_bytes) }
        err_thread = Thread.new { err = read_capped(stderr, max_bytes) }

        # A deadline join rather than a timer thread: a timer racing normal
        # exit could flag a timeout (and SIGKILL a recycled pid) after the
        # process had already succeeded. The reader threads above keep the
        # pipes drained meanwhile, so this cannot deadlock.
        if timeout
          deadline  = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          timed_out = !wait_thr.join(timeout)

          # A grandchild that inherited the pipe holds it open after the child
          # exits, so the unbounded joins below could outlive the process
          # itself. Bound them by the same deadline the timer thread enforced.
          remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
          overrun   = !out_thread.join(remaining) || !err_thread.join(remaining)

          if timed_out || overrun
            begin
              Process.kill("-KILL", wait_thr.pid)
            rescue Errno::ESRCH
              nil
            end
          end
        end

        out_thread.join
        err_thread.join
        exit_status = wait_thr.value
      end

      raise TimeoutError, "process timed out after #{timeout}s" if timed_out

      { stdout: out, stderr: err, exit_status: exit_status }
    end

    def read_capped(io, max_bytes)
      return io.read.to_s unless max_bytes

      buf = +""
      while (chunk = io.read(CHUNK_BYTES))
        buf << chunk if buf.bytesize < max_bytes
      end
      # IO#read with a length returns binary; IO#read without one applies the
      # default external encoding, and callers expect the latter.
      buf.force_encoding(Encoding.default_external)
    end
  end
end
