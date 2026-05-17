# frozen_string_literal: true

require "open3"

module Mbeditor
  module ProcessRunner
    module_function

    class TimeoutError < StandardError; end

    def call(cmd, timeout: nil, env: {}, stdin_data: nil, chdir: nil)
      out = +""
      err = +""
      exit_status = nil
      timed_out = false

      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir

      Open3.popen3(env, *cmd, **opts) do |stdin, stdout, stderr, wait_thr|
        stdin.write(stdin_data) if stdin_data
        stdin.close

        timer = if timeout
          Thread.new do
            sleep timeout
            timed_out = true
            Process.kill("-KILL", wait_thr.pid)
          rescue Errno::ESRCH
            nil
          end
        end

        out_thread = Thread.new { out = stdout.read }
        err_thread = Thread.new { err = stderr.read }
        out_thread.join
        err_thread.join

        exit_status = wait_thr.value
        timer&.kill
      end

      raise TimeoutError, "process timed out after #{timeout}s" if timed_out

      { stdout: out, stderr: err, exit_status: exit_status }
    end
  end
end
