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

    # "--server" when rubocop supports server mode (>= 1.31) and it isn't
    # disabled via config, else "--no-server". Server mode keeps a daemon with
    # the app's cop config loaded, cutting per-lint latency from seconds to
    # ~100ms; rubocop starts/reuses the daemon automatically.
    def self.rubocop_server_flag(workspace_root)
      return "--no-server" unless Mbeditor.configuration.rubocop_server

      key = "rubocop_server:#{Mbeditor.configuration.rubocop_command}"
      supported = probe_cached(key) do
        cmd = rubocop_command(workspace_root)
        # Bounded: a misbehaving rubocop_command must not hang the probe.
        result = ProcessRunner.call(cmd + ["--version"], timeout: 5)
        version = result[:stdout].to_s.strip[/\d+(?:\.\d+)+/]
        result[:exit_status]&.success? && version && Gem::Version.new(version) >= Gem::Version.new("1.31")
      end
      supported ? "--server" : "--no-server"
    end

    def self.ruby_lsp_command(workspace_root)
      configured = Mbeditor.configuration.ruby_lsp_command
      if configured
        return configured.map(&:to_s) if configured.is_a?(Array)

        begin
          return Shellwords.split(configured.to_s)
        rescue ArgumentError
          return ["ruby-lsp"]
        end
      end

      root = Pathname.new(workspace_root)
      local_bin = root.join("bin", "ruby-lsp")
      return [local_bin.to_s] if local_bin.exist?

      begin
        [Gem.bin_path("ruby-lsp", "ruby-lsp")]
      rescue Gem::Exception, Gem::GemNotFoundException
        ["bundle", "exec", "ruby-lsp"]
      end
    end

    def self.ruby_lsp(workspace_root)
      return false if Mbeditor.configuration.ruby_lsp == false

      cmd = ruby_lsp_command(workspace_root)
      key = "ruby_lsp:#{cmd.join(' ')}"
      probe_cached(key) do
        result = ProcessRunner.call(cmd + ["--version"], timeout: 10, chdir: workspace_root.to_s)
        result[:exit_status]&.success? || false
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
