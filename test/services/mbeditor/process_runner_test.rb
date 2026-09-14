# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ProcessRunnerTest < Minitest::Test
    def test_returns_stdout_stderr_and_exit_status_for_normal_subprocess
      result = ProcessRunner.call(["echo", "hello"])

      assert_equal "hello\n", result[:stdout]
      assert_equal "", result[:stderr]
      assert result[:exit_status].success?
    end

    def test_stderr_output_appears_in_stderr_not_stdout
      result = ProcessRunner.call(["bash", "-c", "echo errout >&2"])

      assert_equal "", result[:stdout]
      assert_equal "errout\n", result[:stderr]
    end

    def test_stdin_data_is_written_to_subprocess_stdin
      result = ProcessRunner.call(["cat"], stdin_data: "hello from stdin\n")

      assert_equal "hello from stdin\n", result[:stdout]
    end

    def test_env_variables_are_visible_to_subprocess
      result = ProcessRunner.call(["bash", "-c", "echo $MY_VAR"], env: { "MY_VAR" => "secret42" })

      assert_equal "secret42\n", result[:stdout]
    end

    def test_nil_timeout_runs_subprocess_to_completion_without_error
      result = ProcessRunner.call(["echo", "done"], timeout: nil)

      assert_equal "done\n", result[:stdout]
      assert result[:exit_status].success?
    end

    def test_raises_timeout_error_when_subprocess_exceeds_timeout
      assert_raises(ProcessRunner::TimeoutError) do
        ProcessRunner.call(["sleep", "10"], timeout: 0.01)
      end
    end

    # A timer thread used to race normal exit: it could flag a timeout after the
    # process had already succeeded. Run something that finishes well inside a
    # short timeout, repeatedly, and no run may raise.
    def test_process_finishing_just_inside_the_timeout_is_not_reported_as_timed_out
      20.times do
        result = ProcessRunner.call(["true"], timeout: 0.05)
        assert result[:exit_status].success?
      end
    end

    def test_max_bytes_caps_retained_output_without_blocking_the_subprocess
      result = ProcessRunner.call(["bash", "-c", "head -c 500000 /dev/zero | tr '\\0' 'a'"], max_bytes: 1000)

      assert result[:exit_status].success?, "the producer must run to completion, not block on a full pipe"
      assert_operator result[:stdout].bytesize, :<, 500_000
      assert_operator result[:stdout].bytesize, :>=, 1000
    end

    def test_chdir_sets_working_directory_for_subprocess
      Dir.mktmpdir do |dir|
        real_dir = File.realpath(dir)
        result = ProcessRunner.call(["pwd"], chdir: real_dir)

        assert_equal "#{real_dir}\n", result[:stdout]
      end
    end

    # -------------------------------------------------------------------------
    # Audit log
    # -------------------------------------------------------------------------

    def subprocess_events
      AuditLog.payload[:server][:events].select { |e| e[:event] == :subprocess }
    end

    def with_clean_audit_log
      Mbeditor.configuration.audit_log = true
      AuditLog.clear!
      yield
    ensure
      AuditLog.clear!
      Mbeditor.configuration.audit_log = true
    end

    def test_audit_records_an_unknown_executable_as_other_without_leaking_the_command
      with_clean_audit_log do
        ProcessRunner.call(["/bin/echo", "audit-marker-string"])

        entries = subprocess_events
        assert_equal 1, entries.length
        assert_equal :other, entries.first[:tool]
        assert_equal :ok, entries.first[:status]
        assert_kind_of Numeric, entries.first[:ms]

        dump = AuditLog.payload.to_s
        refute_includes dump, "audit-marker-string"
        refute_includes dump, "/bin/echo"
        refute_includes dump, "echo"
      end
    end

    def test_audit_maps_a_known_executable_to_its_symbol
      with_clean_audit_log do
        ProcessRunner.call(["git", "--version"])

        entries = subprocess_events
        assert_equal 1, entries.length
        assert_equal :git, entries.first[:tool]
        assert_equal :ok, entries.first[:status]
      end
    end

    def test_audit_records_a_timeout_even_though_call_raises
      with_clean_audit_log do
        assert_raises(ProcessRunner::TimeoutError) do
          ProcessRunner.call(["sleep", "5"], timeout: 0.05)
        end

        entries = subprocess_events
        assert_equal 1, entries.length
        assert_equal :timeout, entries.first[:status]
        assert_equal :other, entries.first[:tool]
      end
    end

    def test_audit_records_a_nonzero_exit_as_error
      with_clean_audit_log do
        ProcessRunner.call(["bash", "-c", "exit 3"])

        assert_equal :error, subprocess_events.first[:status]
      end
    end
  end
end
