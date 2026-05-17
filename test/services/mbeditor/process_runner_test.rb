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

    def test_chdir_sets_working_directory_for_subprocess
      Dir.mktmpdir do |dir|
        real_dir = File.realpath(dir)
        result = ProcessRunner.call(["pwd"], chdir: real_dir)

        assert_equal "#{real_dir}\n", result[:stdout]
      end
    end
  end
end
