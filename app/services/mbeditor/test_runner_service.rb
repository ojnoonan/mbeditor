# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"

module Mbeditor
  # Runs a Ruby test file (Minitest or RSpec) and parses the output into a
  # structured result suitable for the editor UI.
  #
  # Follows the same process-group kill pattern used by the lint endpoint to
  # enforce a configurable timeout.
  module TestRunnerService
    module_function

    # Run the test file at +test_path+ inside +repo_path+.
    # Returns a Hash:
    #   {
    #     ok:       true/false,
    #     summary:  { total:, passed:, failed:, errored:, skipped:, duration: },
    #     tests:    [{ name:, status:, line:, message: }],
    #     raw:      String   # full stdout+stderr for fallback display
    #   }
    def run(repo_path, test_path, framework: nil, command: nil, timeout: 60)
      framework = detect_framework(repo_path, test_path) if framework.nil?
      return error_result("Could not detect test framework") unless framework

      cmd = build_command(repo_path, test_path, framework, command)
      raw, timed_out = execute_with_timeout(repo_path, cmd, timeout)

      return error_result("Test run timed out after #{timeout} seconds") if timed_out

      tests, summary = parse_output(raw, framework)
      {
        ok: true,
        framework: framework.to_s,
        summary: summary,
        tests: tests,
        raw: raw
      }
    rescue StandardError => e
      error_result(e.message)
    end

    # Given a source file path, resolve it to its matching test/spec file.
    # If the file is already a test/spec file, return it as-is.
    def resolve_test_file(repo_path, relative_path)
      return relative_path if test_file?(relative_path)

      candidates = test_file_candidates(relative_path)
      candidates.find { |c| File.exist?(File.join(repo_path, c)) }
    end

    def test_file?(path)
      path.match?(%r{(^|/)test/.*_test\.rb$}) ||
        path.match?(%r{(^|/)spec/.*_spec\.rb$}) ||
        path.end_with?("_test.rb") ||
        path.end_with?("_spec.rb")
    end

    def test_file_candidates(relative_path)
      return [] unless relative_path.end_with?(".rb")

      basename = File.basename(relative_path, ".rb")
      dir_parts = relative_path.split("/")

      candidates = []

      # app/models/user.rb -> test/models/user_test.rb
      if dir_parts[0] == "app" && dir_parts.length > 1
        sub_path = dir_parts[1..].join("/")
        sub_dir = File.dirname(sub_path)
        candidates << File.join("test", sub_dir, "#{basename}_test.rb")
        candidates << File.join("spec", sub_dir, "#{basename}_spec.rb")
      end

      # lib/foo.rb -> test/lib/foo_test.rb or test/foo_test.rb
      if dir_parts[0] == "lib"
        sub_path = dir_parts[1..].join("/")
        sub_dir = File.dirname(sub_path)
        candidates << File.join("test", "lib", sub_dir, "#{basename}_test.rb")
        candidates << File.join("test", sub_dir, "#{basename}_test.rb")
        candidates << File.join("spec", "lib", sub_dir, "#{basename}_spec.rb")
      end

      # Fallback: test/<basename>_test.rb
      candidates << File.join("test", "#{basename}_test.rb")
      candidates << File.join("spec", "#{basename}_spec.rb")

      candidates.uniq
    end

    def detect_framework(repo_path, test_path)
      return :rspec if test_path.end_with?("_spec.rb")
      return :minitest if test_path.end_with?("_test.rb")

      # Check project-level hints
      return :rspec if File.exist?(File.join(repo_path, ".rspec"))
      return :rspec if File.exist?(File.join(repo_path, "spec"))

      :minitest if File.exist?(File.join(repo_path, "test"))
    end

    def build_command(repo_path, test_path, framework, custom_command)
      full_path = File.join(repo_path, test_path)

      if custom_command.present?
        tokens = Shellwords.split(custom_command)
        return tokens + [full_path]
      end

      case framework.to_sym
      when :rspec
        bin = File.join(repo_path, "bin", "rspec")
        cmd = File.exist?(bin) ? [bin] : ["bundle", "exec", "rspec"]
        cmd + ["--format", "json", full_path]
      when :minitest
        bin = File.join(repo_path, "bin", "rails")
        if File.exist?(bin)
          [bin, "test", "--verbose", full_path]
        else
          ["bundle", "exec", "ruby", "-Itest", full_path, "--verbose"]
        end
      else
        ["bundle", "exec", "ruby", "-Itest", full_path]
      end
    end

    def execute_with_timeout(repo_path, cmd, timeout)
      raw = +""
      timed_out = false

      Open3.popen3(*cmd, chdir: repo_path, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        timer = Thread.new do
          sleep timeout
          timed_out = true
          Process.kill("-KILL", wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end

        out = stdout.read
        err = stderr.read
        raw = out.to_s + err.to_s
        wait_thr.value
        timer.kill
      end

      [raw, timed_out]
    end

    def parse_output(raw, framework)
      case framework.to_sym
      when :rspec
        parse_rspec_output(raw)
      when :minitest
        parse_minitest_output(raw)
      else
        [[], empty_summary]
      end
    end

    def parse_rspec_output(raw)
      # RSpec with --format json embeds JSON in the output
      json_match = raw.match(/(\{.*"summary_line".*\})/m)
      if json_match
        data = JSON.parse(json_match[1])
        summary = {
          total: data.dig("summary", "example_count") || 0,
          passed: (data.dig("summary", "example_count") || 0) - (data.dig("summary", "failure_count") || 0) - (data.dig("summary", "pending_count") || 0),
          failed: data.dig("summary", "failure_count") || 0,
          errored: 0,
          skipped: data.dig("summary", "pending_count") || 0,
          duration: data.dig("summary", "duration")&.round(3)
        }
        tests = (data["examples"] || []).map do |ex|
          {
            name: ex["full_description"] || ex["description"],
            status: ex["status"] == "passed" ? "pass" : (ex["status"] == "pending" ? "skip" : "fail"),
            line: ex.dig("line_number"),
            message: ex.dig("exception", "message")
          }
        end
        [tests, summary]
      else
        parse_minitest_output(raw) # fallback to text parsing
      end
    rescue JSON::ParserError
      parse_minitest_output(raw)
    end

    def parse_minitest_output(raw)
      lines = raw.lines

      # First pass: collect per-test results from verbose output.
      # Verbose format (--verbose): "ClassName#test_name = N.NNN s = [./F/E/S]"
      verbose_results = {}
      lines.each do |line|
        m = line.match(/\A([\w:]+#\w+)\s+=\s+[\d.]+\s+s\s+=\s+([.FES])\s*\z/)
        next unless m

        status = case m[2]
                 when "." then "pass"
                 when "F" then "fail"
                 when "E" then "error"
                 when "S" then "skip"
                 end
        verbose_results[m[1]] = { name: m[1], status: status, line: nil, message: nil }
      end

      # Second pass: parse failure/error blocks for messages and line numbers.
      # Format: "  1) Failure:\nTestName#method [file:line]:\nmessage"
      failure_entries = []
      lines.each_with_index do |line, idx|
        next unless line.match?(/^\s+\d+\)\s+(Failure|Error):/)

        name_line = lines[idx + 1]
        next unless name_line

        name = name_line.strip.split(" [").first.chomp(":")
        line_num = name_line[/:(\d+)\]/, 1]&.to_i
        msg_lines = []
        (idx + 2...lines.length).each do |j|
          break if lines[j].strip.empty? || lines[j].match?(/^\s+\d+\)\s+/)
          msg_lines << lines[j].strip
        end

        entry = {
          name: name,
          status: line.include?("Error") ? "error" : "fail",
          line: line_num,
          message: msg_lines.join("\n")
        }

        if verbose_results.key?(name)
          verbose_results[name][:line]    = line_num
          verbose_results[name][:message] = msg_lines.join("\n")
        else
          failure_entries << entry
        end
      end

      # Build final tests list: verbose entries first (sorted by name for stability),
      # then any failure entries not already covered by verbose output.
      tests = verbose_results.values + failure_entries

      summary = empty_summary

      # Parse summary line: "X runs, Y assertions, Z failures, W errors, V skips"
      # or "X tests, Y assertions, Z failures, W errors, V skips"
      summary_line = lines.find { |l| l.match?(/\d+ (runs|tests), \d+ assertions/) }
      if summary_line
        nums = summary_line.scan(/\d+/).map(&:to_i)
        summary[:total]   = nums[0] || 0
        summary[:failed]  = nums[2] || 0
        summary[:errored] = nums[3] || 0
        summary[:skipped] = nums[4] || 0
        summary[:passed]  = summary[:total] - summary[:failed] - summary[:errored] - summary[:skipped]
      end

      # Parse timing: "Finished in 0.123456s"
      time_line = lines.find { |l| l.match?(/Finished in [\d.]+s/) }
      if time_line
        summary[:duration] = time_line[/([\d.]+)s/, 1]&.to_f&.round(3)
      end

      [tests, summary]
    end

    def empty_summary
      { total: 0, passed: 0, failed: 0, errored: 0, skipped: 0, duration: nil }
    end

    def error_result(message)
      {
        ok: false,
        error: message,
        summary: empty_summary,
        tests: [],
        raw: ""
      }
    end
  end
end
