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
  end
end
