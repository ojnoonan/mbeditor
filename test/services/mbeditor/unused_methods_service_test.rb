# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class UnusedMethodsServiceTest < ActiveSupport::TestCase
    def setup
      RubyDefinitionService.clear_cache!
      UnusedMethodsService.clear_cache!
      @workspace = Dir.mktmpdir("mbeditor_unused_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_rb(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    def call(file_path, **opts)
      UnusedMethodsService.call(@workspace, file_path, **opts)
    end

    # -------------------------------------------------------------------------
    # Basic: unused method detected
    # -------------------------------------------------------------------------

    test "returns method name and line for a method with no call-sites" do
      path = write_rb("app/models/user.rb", <<~RUBY)
        class User
          def orphan_method
          end
        end
      RUBY

      result = call(path)
      names = result.map { |r| r[:name] }
      assert_includes names, "orphan_method"
      entry = result.find { |r| r[:name] == "orphan_method" }
      assert_equal 2, entry[:line]
    end

    # -------------------------------------------------------------------------
    # Basic: used method not flagged
    # -------------------------------------------------------------------------

    test "does not flag a method that is called elsewhere in the workspace" do
      path = write_rb("app/models/user.rb", <<~RUBY)
        class User
          def greet
          end
        end
      RUBY
      write_rb("app/controllers/home_controller.rb", <<~RUBY)
        class HomeController
          def index
            user.greet
          end
        end
      RUBY

      result = call(path)
      refute result.any? { |r| r[:name] == "greet" }
    end

    # -------------------------------------------------------------------------
    # Returns empty array for a non-existent file
    # -------------------------------------------------------------------------

    test "returns empty array when file does not exist" do
      result = call("/nonexistent/path/file.rb")
      assert_equal [], result
    end

    # -------------------------------------------------------------------------
    # excluded_paths: dirname pattern skips that directory during scan
    # -------------------------------------------------------------------------

    test "excluded_paths dirname excludes directory from call-site scan" do
      path = write_rb("app/models/user.rb", <<~RUBY)
        class User
          def helper_method
          end
        end
      RUBY
      # The only call-site is inside the excluded directory.
      write_rb("vendor/gems/caller.rb", "User.new.helper_method\n")

      result = call(path, excluded_paths: %w[vendor])
      names = result.map { |r| r[:name] }
      assert_includes names, "helper_method",
        "helper_method should be flagged unused because vendor/ was excluded from scan"
    end
  end
end
