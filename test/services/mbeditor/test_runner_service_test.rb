# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class TestRunnerServiceTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
    # -------------------------------------------------------------------------
    # resolve_test_file
    # -------------------------------------------------------------------------

    test "resolves app/models/user.rb to test/models/user_test.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test", "models"))
        File.write(File.join(dir, "test", "models", "user_test.rb"), "")

        result = TestRunnerService.resolve_test_file(dir, "app/models/user.rb")
        assert_equal "test/models/user_test.rb", result
      end
    end

    test "resolves app/controllers/users_controller.rb to test/controllers/users_controller_test.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test", "controllers"))
        File.write(File.join(dir, "test", "controllers", "users_controller_test.rb"), "")

        result = TestRunnerService.resolve_test_file(dir, "app/controllers/users_controller.rb")
        assert_equal "test/controllers/users_controller_test.rb", result
      end
    end

    test "resolves spec file for rspec projects" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec", "models"))
        File.write(File.join(dir, "spec", "models", "user_spec.rb"), "")

        result = TestRunnerService.resolve_test_file(dir, "app/models/user.rb")
        assert_equal "spec/models/user_spec.rb", result
      end
    end

    test "returns test file as-is when it is already a test file" do
      result = TestRunnerService.resolve_test_file("/tmp", "test/models/user_test.rb")
      assert_equal "test/models/user_test.rb", result
    end

    test "returns spec file as-is when it is already a spec file" do
      result = TestRunnerService.resolve_test_file("/tmp", "spec/models/user_spec.rb")
      assert_equal "spec/models/user_spec.rb", result
    end

    test "returns nil when no matching test file exists" do
      Dir.mktmpdir do |dir|
        result = TestRunnerService.resolve_test_file(dir, "app/models/user.rb")
        assert_nil result
      end
    end

    # -------------------------------------------------------------------------
    # test_file?
    # -------------------------------------------------------------------------

    test "test_file? returns true for _test.rb files" do
      assert TestRunnerService.test_file?("test/models/user_test.rb")
      assert TestRunnerService.test_file?("user_test.rb")
    end

    test "test_file? returns true for _spec.rb files" do
      assert TestRunnerService.test_file?("spec/models/user_spec.rb")
      assert TestRunnerService.test_file?("user_spec.rb")
    end

    test "test_file? returns false for regular files" do
      refute TestRunnerService.test_file?("app/models/user.rb")
      refute TestRunnerService.test_file?("lib/foo.rb")
    end

    # -------------------------------------------------------------------------
    # detect_framework
    # -------------------------------------------------------------------------

    test "detect_framework returns :minitest for _test.rb file" do
      assert_equal :minitest, TestRunnerService.detect_framework("/tmp", "test/models/user_test.rb")
    end

    test "detect_framework returns :rspec for _spec.rb file" do
      assert_equal :rspec, TestRunnerService.detect_framework("/tmp", "spec/models/user_spec.rb")
    end

    test "detect_framework detects rspec from .rspec file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rspec"), "--format documentation\n")
        assert_equal :rspec, TestRunnerService.detect_framework(dir, "app/models/user.rb")
      end
    end

    test "detect_framework detects minitest from test directory" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test"))
        assert_equal :minitest, TestRunnerService.detect_framework(dir, "app/models/user.rb")
      end
    end

    test 'detect_framework detects rspec from spec directory' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'spec'))
        assert_equal :rspec, TestRunnerService.detect_framework(dir, 'app/models/user.rb')
      end
    end

    test 'detect_framework returns nil when no hints found' do
      Dir.mktmpdir do |dir|
        assert_nil TestRunnerService.detect_framework(dir, 'app/models/user.rb')
      end
    end

    # -------------------------------------------------------------------------
    # test_file_candidates
    # -------------------------------------------------------------------------

    test 'test_file_candidates for app/models produces expected paths' do
      candidates = TestRunnerService.test_file_candidates('app/models/user.rb')
      assert_includes candidates, 'test/models/user_test.rb'
      assert_includes candidates, 'spec/models/user_spec.rb'
    end

    test 'test_file_candidates for lib file produces test/lib path' do
      candidates = TestRunnerService.test_file_candidates('lib/mbeditor/configuration.rb')
      assert_includes candidates, 'test/lib/mbeditor/configuration_test.rb'
      assert_includes candidates, 'spec/lib/mbeditor/configuration_spec.rb'
    end

    test 'test_file_candidates includes fallback basename entry' do
      candidates = TestRunnerService.test_file_candidates('some/nested/thing.rb')
      assert_includes candidates, 'test/thing_test.rb'
      assert_includes candidates, 'spec/thing_spec.rb'
    end

    test 'test_file_candidates returns empty for non-rb file' do
      assert_equal [], TestRunnerService.test_file_candidates('README.md')
    end

    test 'test_file_candidates returns unique entries' do
      candidates = TestRunnerService.test_file_candidates('app/models/user.rb')
      assert_equal candidates, candidates.uniq
    end

    # -------------------------------------------------------------------------
    # empty_summary
    # -------------------------------------------------------------------------

    test 'empty_summary returns zero counts with nil duration' do
      s = TestRunnerService.empty_summary
      assert_equal 0, s[:total]
      assert_equal 0, s[:passed]
      assert_equal 0, s[:failed]
      assert_equal 0, s[:errored]
      assert_equal 0, s[:skipped]
      assert_nil s[:duration]
    end

    # -------------------------------------------------------------------------
    # parse_minitest_output
    # -------------------------------------------------------------------------

    test "parse_minitest_output extracts summary from minitest output" do
      output = <<~OUTPUT
        Run options: --seed 12345

        # Running:

        ...F.

        Finished in 0.012345s, 405.1234 runs/s, 405.1234 assertions/s.

          1) Failure:
        UserTest#test_name [test/models/user_test.rb:10]:
        Expected false to be truthy.

        5 runs, 5 assertions, 1 failures, 0 errors, 0 skips
      OUTPUT

      tests, summary = TestRunnerService.parse_minitest_output(output)

      assert_equal 5, summary[:total]
      assert_equal 4, summary[:passed]
      assert_equal 1, summary[:failed]
      assert_equal 0, summary[:errored]
      assert_equal 0, summary[:skipped]
      assert_in_delta 0.012, summary[:duration], 0.001

      assert_equal 1, tests.length
      assert_equal "UserTest#test_name", tests[0][:name]
      assert_equal "fail", tests[0][:status]
      assert_equal 10, tests[0][:line]
    end

    test "parse_minitest_output handles all-passing output" do
      output = <<~OUTPUT
        Run options: --seed 12345

        # Running:

        ...

        Finished in 0.005s, 600.0 runs/s, 600.0 assertions/s.

        3 runs, 3 assertions, 0 failures, 0 errors, 0 skips
      OUTPUT

      tests, summary = TestRunnerService.parse_minitest_output(output)

      assert_equal 3, summary[:total]
      assert_equal 3, summary[:passed]
      assert_equal 0, summary[:failed]
      assert_empty tests
    end

    test 'parse_minitest_output handles error output' do
      output = <<~OUTPUT
        Run options: --seed 9999

        # Running:

        E

        Finished in 0.003s, 333.3 runs/s, 333.3 assertions/s.

          1) Error:
        UserTest#test_raises_error:
        NoMethodError: undefined method `foo' for nil:NilClass
            test/models/user_test.rb:10:in `test_raises_error'

        1 runs, 1 assertions, 0 failures, 1 errors, 0 skips
      OUTPUT

      tests, summary = TestRunnerService.parse_minitest_output(output)

      assert_equal 1, summary[:total]
      assert_equal 0, summary[:passed]
      assert_equal 0, summary[:failed]
      assert_equal 1, summary[:errored]
      assert_equal 1, tests.length
      assert_equal 'error', tests[0][:status]
      assert_match 'UserTest#test_raises_error', tests[0][:name]
    end

    test 'parse_minitest_output returns empty defaults for empty input' do
      tests, summary = TestRunnerService.parse_minitest_output('')
      assert_equal [], tests
      assert_equal 0, summary[:total]
      assert_nil summary[:duration]
    end

    test 'parse_minitest_output accepts tests keyword variant in summary line' do
      output = "3 tests, 3 assertions, 0 failures, 0 errors, 0 skips\n"
      _tests, summary = TestRunnerService.parse_minitest_output(output)
      assert_equal 3, summary[:total]
    end

    # -------------------------------------------------------------------------
    # parse_rspec_output
    # -------------------------------------------------------------------------

    RSPEC_JSON = '{"examples":[' \
      '{"full_description":"User is valid","status":"passed","line_number":4},' \
      '{"full_description":"User fails","status":"failed","line_number":8,' \
      '"exception":{"class":"RSpec::Expectations::ExpectationNotMetError","message":"expected true got false"}},' \
      '{"full_description":"User pending","status":"pending","line_number":12}],' \
      '"summary":{"duration":0.1234,"example_count":3,"failure_count":1,"pending_count":1},' \
      '"summary_line":"3 examples, 1 failure, 1 pending"}'

    test 'parse_rspec_output extracts summary from json' do
      _tests, summary = TestRunnerService.parse_rspec_output(RSPEC_JSON)
      assert_equal 3, summary[:total]
      assert_equal 1, summary[:passed]
      assert_equal 1, summary[:failed]
      assert_equal 1, summary[:skipped]
      assert_in_delta 0.123, summary[:duration], 0.001
    end

    test 'parse_rspec_output maps example statuses correctly' do
      tests, _summary = TestRunnerService.parse_rspec_output(RSPEC_JSON)
      assert_equal 3, tests.length
      assert_equal 'pass', tests[0][:status]
      assert_equal 'fail', tests[1][:status]
      assert_equal 'skip', tests[2][:status]
    end

    test 'parse_rspec_output includes failure message and line number' do
      tests, _summary = TestRunnerService.parse_rspec_output(RSPEC_JSON)
      assert_equal 'expected true got false', tests[1][:message]
      assert_equal 8, tests[1][:line]
    end

    test 'parse_rspec_output falls back to minitest parser when no json present' do
      raw = "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\nFinished in 0.005s\n"
      _tests, summary = TestRunnerService.parse_rspec_output(raw)
      assert_equal 3, summary[:total]
    end

    test 'parse_rspec_output falls back gracefully on invalid json' do
      raw = '{"summary_line":"broken'
      tests, summary = TestRunnerService.parse_rspec_output(raw)
      assert_kind_of Array, tests
      assert_kind_of Hash, summary
    end

    test 'parse_rspec_output with rspec plain-text format returns empty counts without raising' do
      # RSpec --format progress (no --format json) emits text that the minitest
      # fallback parser cannot understand — documents the known limitation.
      raw = <<~OUTPUT
        ..F

        Failures:

          1) User is valid
             Failure/Error: expect(user).to be_valid
               expected #<User> to be valid, but got errors: name can't be blank
             # ./spec/models/user_spec.rb:5:in `block (2 levels) in <top (required)>'

        Finished in 0.05432 seconds (files took 1.23 seconds to load)
        3 examples, 1 failure

      OUTPUT

      tests, summary = TestRunnerService.parse_rspec_output(raw)
      assert_kind_of Array, tests
      assert_kind_of Hash, summary
      assert_equal 0, summary[:total]
    end

    # -------------------------------------------------------------------------
    # error_result
    # -------------------------------------------------------------------------

    test "error_result returns well-formed error hash" do
      result = TestRunnerService.error_result("something broke")
      assert_equal false, result[:ok]
      assert_equal "something broke", result[:error]
      assert_kind_of Array, result[:tests]
      assert_kind_of Hash, result[:summary]
    end

    # -------------------------------------------------------------------------
    # execute_with_timeout
    # -------------------------------------------------------------------------

    test "execute_with_timeout returns combined stdout and stderr as a single string" do
      Dir.mktmpdir do |dir|
        cmd = ["bash", "-c", "echo out; echo err >&2"]
        raw = TestRunnerService.execute_with_timeout(dir, cmd, 5)

        assert_includes raw, "out\n"
        assert_includes raw, "err\n"
      end
    end

    test "truncate_raw caps oversized output at the tail and keeps it valid UTF-8" do
      short = "all good\n"
      assert_same short, TestRunnerService.truncate_raw(short)

      # An odd byte offset so the cut lands mid-character.
      raw = "x" + ("é" * 200_000)
      out = TestRunnerService.truncate_raw(raw)

      assert_operator out.bytesize, :<=, TestRunnerService::MAX_RAW_BYTES
      assert out.valid_encoding?, "a split multi-byte character must be scrubbed"
      assert out.end_with?("é")
    end

    test "execute_with_timeout raises ProcessRunner::TimeoutError when subprocess exceeds timeout" do
      Dir.mktmpdir do |dir|
        assert_raises(ProcessRunner::TimeoutError) do
          TestRunnerService.execute_with_timeout(dir, ["sleep", "10"], 0.01)
        end
      end
    end

    # -------------------------------------------------------------------------
    # run (timeout handling)
    # -------------------------------------------------------------------------

    test "run returns timeout error result when subprocess times out" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test"))
        test_file = File.join(dir, "test", "slow_test.rb")
        File.write(test_file, "")

        # bash -c 'sleep 10' treats the trailing file arg as $0, so sleep runs
        result = TestRunnerService.run(dir, "test/slow_test.rb",
                                       command: "bash -c 'sleep 10'",
                                       timeout: 0.01)

        assert_equal false, result[:ok]
        assert_match(/timed out/i, result[:error])
      end
    end

    # -------------------------------------------------------------------------
    # test_name_at_line
    # -------------------------------------------------------------------------

    MINITEST_FILE = <<~RUBY
      class UserTest < ActiveSupport::TestCase
        def test_first_thing
          assert true
        end

        test "does a second thing" do
          assert true
        end

        def test_third_thing?
          assert true
        end
      end
    RUBY

    def with_minitest_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "user_test.rb")
        File.write(path, MINITEST_FILE)
        yield path, dir
      end
    end

    test "test_name_at_line finds an enclosing def test_ method" do
      with_minitest_file do |path|
        assert_equal "test_first_thing", TestRunnerService.test_name_at_line(path, 3)
      end
    end

    test "test_name_at_line converts a Rails test macro to its generated method name" do
      with_minitest_file do |path|
        assert_equal "test_does_a_second_thing", TestRunnerService.test_name_at_line(path, 7)
      end
    end

    test "test_name_at_line keeps a trailing question mark in the method name" do
      with_minitest_file do |path|
        assert_equal "test_third_thing?", TestRunnerService.test_name_at_line(path, 11)
      end
    end

    test "test_name_at_line resolves to the nearest preceding test when between tests" do
      with_minitest_file do |path|
        # Line 5 is the blank line after the first test's `end`.
        assert_equal "test_first_thing", TestRunnerService.test_name_at_line(path, 5)
      end
    end

    test "test_name_at_line returns nil above the first test and for a missing file" do
      with_minitest_file do |path, dir|
        assert_nil TestRunnerService.test_name_at_line(path, 1)
        assert_nil TestRunnerService.test_name_at_line(File.join(dir, "nope.rb"), 3)
      end
    end

    # -------------------------------------------------------------------------
    # build_command — line filtering
    # -------------------------------------------------------------------------

    test "build_command targets the whole file when no line is given" do
      Dir.mktmpdir do |dir|
        cmd = TestRunnerService.build_command(dir, "test/user_test.rb", :minitest, nil)
        assert_includes cmd, File.join(dir, "test/user_test.rb")
        assert_not_includes cmd, "-n"
      end
    end

    test "build_command uses path:line for rspec" do
      Dir.mktmpdir do |dir|
        cmd = TestRunnerService.build_command(dir, "spec/user_spec.rb", :rspec, nil, line: 12)
        assert_equal "#{File.join(dir, 'spec/user_spec.rb')}:12", cmd.last
        assert_includes cmd, "--format"
      end
    end

    test "build_command uses path:line for minitest when bin/rails exists" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin", "rails"), "")

        cmd = TestRunnerService.build_command(dir, "test/user_test.rb", :minitest, nil, line: 7)
        assert_equal File.join(dir, "bin", "rails"), cmd.first
        assert_equal "#{File.join(dir, 'test/user_test.rb')}:7", cmd.last
      end
    end

    test "build_command uses a name filter for the plain minitest runner" do
      with_minitest_file do |path, dir|
        rel = File.basename(path)
        cmd = TestRunnerService.build_command(dir, rel, :minitest, nil, line: 7)

        assert_equal "-n", cmd[-2]
        assert_equal "/\\Atest_does_a_second_thing\\z/", cmd.last
      end
    end

    test "build_command falls back to the whole file when no test encloses the line" do
      with_minitest_file do |path, dir|
        cmd = TestRunnerService.build_command(dir, File.basename(path), :minitest, nil, line: 1)

        assert_not_includes cmd, "-n"
        assert_equal "--verbose", cmd.last
      end
    end

    test "build_command applies line filtering to custom commands by framework" do
      with_minitest_file do |path, dir|
        rel = File.basename(path)

        minitest_cmd = TestRunnerService.build_command(dir, rel, :minitest, "bundle exec ruby -Itest", line: 7)
        assert_equal "-n", minitest_cmd[-2]
        assert_equal "/\\Atest_does_a_second_thing\\z/", minitest_cmd.last

        rspec_cmd = TestRunnerService.build_command(dir, rel, :rspec, "bundle exec rspec", line: 7)
        assert_equal "#{File.join(dir, rel)}:7", rspec_cmd.last
      end
    end

    test "build_command ignores a non-positive line" do
      Dir.mktmpdir do |dir|
        cmd = TestRunnerService.build_command(dir, "test/user_test.rb", :rspec, nil, line: 0)
        assert_equal File.join(dir, "test/user_test.rb"), cmd.last
      end
    end

    # "Open failing files" is only as good as this: a failure with no
    # workspace-relative path is a row you cannot click.
    test "parse_minitest_output extracts the failing file, absolute or relative" do
      raw = <<~OUT
        UserTest#test_broken = 0.01 s = F
        OrderTest#test_also_broken = 0.02 s = F

          1) Failure:
        UserTest#test_broken [/repo/test/models/user_test.rb:12]:
        Expected true to be false.

          2) Failure:
        OrderTest#test_also_broken [test/models/order_test.rb:34]:
        Nope.

        2 runs, 2 assertions, 2 failures, 0 errors, 0 skips
      OUT

      tests, summary = TestRunnerService.parse_minitest_output(raw, repo_path: "/repo")
      by_name = tests.to_h { |t| [t[:name], t] }

      assert_equal "test/models/user_test.rb", by_name["UserTest#test_broken"][:file]
      assert_equal 12, by_name["UserTest#test_broken"][:line]
      assert_equal "test/models/order_test.rb", by_name["OrderTest#test_also_broken"][:file]
      assert_equal 2, summary[:failed]
    end

    test "parse_minitest_output drops a path outside the workspace" do
      raw = <<~OUT
          1) Error:
        GemTest#test_x [/usr/lib/ruby/gems/foo/test_foo.rb:9]:
        Boom.
      OUT

      tests, = TestRunnerService.parse_minitest_output(raw, repo_path: "/repo")
      assert_nil tests.first[:file]
      assert_equal 9, tests.first[:line]
    end
  end
end
