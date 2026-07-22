# frozen_string_literal: true

require "open3"
require "shellwords"

module Mbeditor
  class AvailabilityProbe
    MUTEX = Mutex.new
    private_constant :MUTEX

    def self.rubocop_command(workspace_root)
      root = Pathname.new(workspace_root)
      command = Mbeditor.configuration.rubocop_command.to_s.strip
      command = "rubocop" if command.empty?
      tokens = Shellwords.split(command)

      local_bin = root.join("bin", "rubocop")
      return [local_bin.to_s] if tokens == ["rubocop"] && local_bin.exist?

      tokens
    rescue ArgumentError
      ["rubocop"]
    end

    def self.haml_lint_command(workspace_root)
      root = Pathname.new(workspace_root)
      workspace_bin = root.join("bin", "haml-lint")
      return [workspace_bin.to_s] if workspace_bin.exist?

      begin
        [Gem.bin_path("haml_lint", "haml-lint")]
      rescue Gem::Exception, Gem::GemNotFoundException
        ["haml-lint"]
      end
    end

    def self.rubocop(workspace_root)
      key = "rubocop:#{Mbeditor.configuration.rubocop_command}"
      probe_cached(key) do
        cmd = rubocop_command(workspace_root)
        _out, _err, status = Open3.capture3(*cmd, "--version")
        status.success?
      end
    end

    def self.haml_lint(workspace_root)
      cmd = haml_lint_command(workspace_root)
      key = "haml_lint:#{cmd.join(' ')}"
      probe_cached(key) do
        _out, _err, status = Open3.capture3(*cmd, "--version")
        status.success?
      end
    end

    def self.git(workspace_root)
      key = "git:#{workspace_root}"
      probe_cached(key) do
        _out, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "rev-parse", "--is-inside-work-tree")
        status.success?
      end
    end

    # A tool that was found stays cached forever (nothing uninstalls
    # mid-session), but a missing tool is re-probed after this many seconds so
    # installing e.g. rubocop while the server runs is picked up.
    NEGATIVE_PROBE_TTL = 60

    def self.reset!
      MUTEX.synchronize { @cache = {} }
      nil
    end

    def self.probe_cached(key)
      MUTEX.synchronize do
        @cache ||= {}
        entry = @cache[key]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if entry.nil? || (entry[:value] == false && (now - entry[:ts]) > NEGATIVE_PROBE_TTL)
          value = begin
            yield
          rescue StandardError
            false
          end
          entry = @cache[key] = { value: value, ts: now }
        end

        entry[:value]
      end
    end
    private_class_method :probe_cached
  end
end
