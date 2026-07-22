# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class AvailabilityProbeTest < Minitest::Test
    def setup
      @workspace = Pathname.new(Dir.mktmpdir)
    end

    def teardown
      AvailabilityProbe.reset!
      FileUtils.remove_entry(@workspace)
    end

    # rubocop_command

    def test_rubocop_command_returns_local_bin_when_present
      bin = @workspace.join("bin", "rubocop")
      FileUtils.mkdir_p(bin.dirname)
      FileUtils.touch(bin)

      assert_equal [bin.to_s], AvailabilityProbe.rubocop_command(@workspace)
    end

    def test_rubocop_command_returns_bare_rubocop_when_no_local_bin
      assert_equal ["rubocop"], AvailabilityProbe.rubocop_command(@workspace)
    end

    def test_rubocop_command_honours_configured_command
      Mbeditor.configuration.rubocop_command = "bundle exec rubocop"
      assert_equal ["bundle", "exec", "rubocop"], AvailabilityProbe.rubocop_command(@workspace)
    ensure
      Mbeditor.configuration.rubocop_command = nil
    end

    # haml_lint_command

    def test_haml_lint_command_returns_local_bin_when_present
      bin = @workspace.join("bin", "haml-lint")
      FileUtils.mkdir_p(bin.dirname)
      FileUtils.touch(bin)

      assert_equal [bin.to_s], AvailabilityProbe.haml_lint_command(@workspace)
    end

    def test_haml_lint_command_returns_string_array
      result = AvailabilityProbe.haml_lint_command(@workspace)
      assert_kind_of Array, result
      assert result.all? { |s| s.is_a?(String) }
      assert_includes result.last, "haml-lint"
    end

    # boolean probes

    def test_git_returns_true_for_git_repo
      assert_equal true, AvailabilityProbe.git(Rails.root)
    end

    def test_git_returns_false_for_non_git_directory
      assert_equal false, AvailabilityProbe.git(@workspace)
    end

    def test_rubocop_returns_boolean
      result = AvailabilityProbe.rubocop(@workspace)
      assert_includes [true, false], result
    end

    def test_haml_lint_returns_boolean
      result = AvailabilityProbe.haml_lint(@workspace)
      assert_includes [true, false], result
    end

    def test_rg_returns_boolean
      assert_includes [true, false], AvailabilityProbe.rg
    end

    def test_rg_returns_false_when_not_on_path
      Dir.mktmpdir do |empty_bin|
        original_path = ENV["PATH"]
        ENV["PATH"] = empty_bin
        AvailabilityProbe.reset!

        assert_equal false, AvailabilityProbe.rg
      ensure
        ENV["PATH"] = original_path
      end
    end

    # caching

    def test_rubocop_result_is_cached_subprocess_called_once
      Dir.mktmpdir do |dir|
        counter = File.join(dir, "count")
        File.write(counter, "0")
        script = File.join(dir, "fake-rubocop")
        File.write(script, "#!/bin/sh\nc=$(cat #{counter}); echo $((c+1)) > #{counter}; exit 0\n")
        File.chmod(0o755, script)
        Mbeditor.configuration.rubocop_command = script

        AvailabilityProbe.rubocop(@workspace)
        AvailabilityProbe.rubocop(@workspace)

        assert_equal "1\n", File.read(counter)
      end
    ensure
      Mbeditor.configuration.rubocop_command = nil
    end

    def test_ruby_lsp_probe_short_circuits_when_disabled
      original = Mbeditor.configuration.ruby_lsp
      Mbeditor.configuration.ruby_lsp = false

      refute AvailabilityProbe.ruby_lsp(@workspace)
    ensure
      Mbeditor.configuration.ruby_lsp = original
    end

    def test_ruby_lsp_command_prefers_config_then_bin_stub
      original = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = "custom-lsp --stdio"
      assert_equal ["custom-lsp", "--stdio"], AvailabilityProbe.ruby_lsp_command(@workspace)

      Mbeditor.configuration.ruby_lsp_command = nil
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        stub = File.join(dir, "bin", "ruby-lsp")
        File.write(stub, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, stub)
        assert_equal [stub], AvailabilityProbe.ruby_lsp_command(dir)
      end
    ensure
      Mbeditor.configuration.ruby_lsp_command = original
    end

    def test_rubocop_server_flag_uses_server_for_modern_rubocop
      Dir.mktmpdir do |dir|
        script = File.join(dir, "fake-rubocop")
        File.write(script, "#!/bin/sh\necho '1.66.1'\nexit 0\n")
        File.chmod(0o755, script)
        Mbeditor.configuration.rubocop_command = script
        Mbeditor.configuration.rubocop_server = true

        assert_equal "--server", AvailabilityProbe.rubocop_server_flag(@workspace)
      end
    ensure
      Mbeditor.configuration.rubocop_command = nil
      Mbeditor.configuration.rubocop_server = false # test_helper default
      AvailabilityProbe.reset!
    end

    def test_rubocop_server_flag_falls_back_for_old_rubocop_and_when_disabled
      Dir.mktmpdir do |dir|
        script = File.join(dir, "fake-rubocop")
        File.write(script, "#!/bin/sh\necho '1.20.0'\nexit 0\n")
        File.chmod(0o755, script)
        Mbeditor.configuration.rubocop_command = script
        Mbeditor.configuration.rubocop_server = true

        assert_equal "--no-server", AvailabilityProbe.rubocop_server_flag(@workspace)

        Mbeditor.configuration.rubocop_server = false
        assert_equal "--no-server", AvailabilityProbe.rubocop_server_flag(@workspace)
      end
    ensure
      Mbeditor.configuration.rubocop_command = nil
      Mbeditor.configuration.rubocop_server = false # test_helper default
      AvailabilityProbe.reset!
    end

    def test_negative_result_is_reprobed_after_ttl
      Dir.mktmpdir do |dir|
        counter = File.join(dir, "count")
        File.write(counter, "0")
        script = File.join(dir, "fake-rubocop")
        # Always fails — probe result stays false
        File.write(script, "#!/bin/sh\nc=$(cat #{counter}); echo $((c+1)) > #{counter}; exit 1\n")
        File.chmod(0o755, script)
        Mbeditor.configuration.rubocop_command = script

        refute AvailabilityProbe.rubocop(@workspace)
        refute AvailabilityProbe.rubocop(@workspace)
        assert_equal "1\n", File.read(counter), "within TTL the false result is cached"

        # Expire the negative entry by backdating its timestamp
        cache = AvailabilityProbe.instance_variable_get(:@cache)
        key = cache.keys.find { |k| k.start_with?("rubocop:") }
        cache[key][:ts] -= AvailabilityProbe::NEGATIVE_PROBE_TTL + 1

        refute AvailabilityProbe.rubocop(@workspace)
        assert_equal "2\n", File.read(counter), "expired negative result must re-probe"
      end
    ensure
      Mbeditor.configuration.rubocop_command = nil
      AvailabilityProbe.reset!
    end

    def test_rg_result_is_cached_subprocess_called_once
      with_fake_rg_on_path do |counter|
        AvailabilityProbe.reset!
        AvailabilityProbe.rg
        AvailabilityProbe.rg

        assert_equal "1\n", File.read(counter)
      end
    end

    def test_reset_clears_rg_cache_so_next_call_re_probes
      with_fake_rg_on_path do |counter|
        AvailabilityProbe.reset!
        AvailabilityProbe.rg
        AvailabilityProbe.reset!
        AvailabilityProbe.rg

        assert_equal "2\n", File.read(counter)
      end
    end

    def test_reset_clears_cache_so_next_call_re_probes
      Dir.mktmpdir do |dir|
        counter = File.join(dir, "count")
        File.write(counter, "0")
        script = File.join(dir, "fake-rubocop")
        File.write(script, "#!/bin/sh\nc=$(cat #{counter}); echo $((c+1)) > #{counter}; exit 0\n")
        File.chmod(0o755, script)
        Mbeditor.configuration.rubocop_command = script

        AvailabilityProbe.rubocop(@workspace)
        AvailabilityProbe.reset!
        AvailabilityProbe.rubocop(@workspace)

        assert_equal "2\n", File.read(counter)
      end
    ensure
      Mbeditor.configuration.rubocop_command = nil
    end

    private

    # Puts a fake, counting `rg` executable first on PATH for the block's
    # duration, yielding the path to its invocation-counter file.
    def with_fake_rg_on_path
      Dir.mktmpdir do |dir|
        counter = File.join(dir, "count")
        File.write(counter, "0")
        script = File.join(dir, "rg")
        File.write(script, "#!/bin/sh\nc=$(cat #{counter}); echo $((c+1)) > #{counter}; exit 0\n")
        File.chmod(0o755, script)

        original_path = ENV["PATH"]
        ENV["PATH"] = "#{dir}:#{original_path}"
        begin
          yield counter
        ensure
          ENV["PATH"] = original_path
        end
      end
    end
  end
end
