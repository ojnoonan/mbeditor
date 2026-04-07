# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RubyDefinitionServiceTest < ActiveSupport::TestCase
    def setup
      RubyDefinitionService.clear_cache!
      @workspace = Dir.mktmpdir("mbeditor_def_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_rb(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def call(symbol, **opts)
      RubyDefinitionService.call(@workspace, symbol, **opts)
    end

    # -------------------------------------------------------------------------
    # Basic instance method
    # -------------------------------------------------------------------------

    test "finds a simple def statement" do
      write_rb("app/models/user.rb", <<~RUBY)
        class User
          def find_by_email
          end
        end
      RUBY

      results = call("find_by_email")
      assert_equal 1, results.length
      assert_equal "app/models/user.rb", results[0][:file]
      assert_equal 2, results[0][:line]
      assert_includes results[0][:signature], "def find_by_email"
    end

    # -------------------------------------------------------------------------
    # Class method (def self.x)
    # -------------------------------------------------------------------------

    test "finds def self.method" do
      write_rb("lib/util.rb", <<~RUBY)
        module Util
          def self.parse_token(str)
            str.strip
          end
        end
      RUBY

      results = call("parse_token")
      assert_equal 1, results.length
      assert_equal 2, results[0][:line]
      assert_includes results[0][:signature], "def self.parse_token"
    end

    # -------------------------------------------------------------------------
    # Comment extraction
    # -------------------------------------------------------------------------

    test "extracts contiguous # comments above the def" do
      write_rb("app/services/greeter.rb", <<~RUBY)
        class Greeter
          # Returns a greeting string.
          # @param name [String]
          def greet(name)
            "Hello, \#{name}"
          end
        end
      RUBY

      results = call("greet")
      assert_equal 1, results.length
      assert_includes results[0][:comments], "Returns a greeting string."
      assert_includes results[0][:comments], "@param name [String]"
    end

    test "stops comment extraction at a blank line" do
      write_rb("app/services/greeter.rb", <<~RUBY)
        class Greeter
          # This comment is separated by a blank line and should NOT be included.

          # This comment IS directly above the def and should be included.
          def greet(name)
          end
        end
      RUBY

      results = call("greet")
      assert_equal 1, results.length
      refute_includes results[0][:comments], "separated by a blank line"
      assert_includes results[0][:comments], "directly above"
    end

    test "returns empty comments when def has no preceding # lines" do
      write_rb("app/models/post.rb", <<~RUBY)
        class Post
          def title
            @title
          end
        end
      RUBY

      results = call("title")
      assert_equal 1, results.length
      assert_equal "", results[0][:comments]
    end

    # -------------------------------------------------------------------------
    # Multiple results
    # -------------------------------------------------------------------------

    test "returns results from multiple files" do
      write_rb("app/models/user.rb", "class User\n  def validate\n  end\nend\n")
      write_rb("app/models/order.rb", "class Order\n  def validate\n  end\nend\n")

      results = call("validate")
      assert_equal 2, results.length
      files = results.map { |r| r[:file] }
      assert_includes files, "app/models/user.rb"
      assert_includes files, "app/models/order.rb"
    end

    # -------------------------------------------------------------------------
    # Symbol not found
    # -------------------------------------------------------------------------

    test "returns empty array when symbol is not defined anywhere" do
      write_rb("app/models/user.rb", "class User; end\n")

      results = call("totally_missing_method_xyz")
      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # Max results cap
    # -------------------------------------------------------------------------

    test "caps results at MAX_RESULTS (20)" do
      25.times do |i|
        write_rb("app/models/model_#{i}.rb", "class M#{i}\n  def the_method\n  end\nend\n")
      end

      results = call("the_method")
      assert results.length <= RubyDefinitionService::MAX_RESULTS
    end

    # -------------------------------------------------------------------------
    # Excluded directories
    # -------------------------------------------------------------------------

    test "skips files inside excluded dirnames" do
      write_rb("app/models/user.rb", "class User\n  def the_method\n  end\nend\n")
      write_rb("tmp/cache/generated.rb", "class Cache\n  def the_method\n  end\nend\n")

      results = call("the_method", excluded_dirnames: %w[tmp])
      assert results.all? { |r| !r[:file].start_with?("tmp/") }
    end

    # -------------------------------------------------------------------------
    # Does NOT match method name in a string literal
    # -------------------------------------------------------------------------

    test "does not return false positives from method names inside strings" do
      write_rb("app/models/doc.rb", <<~RUBY)
        class Doc
          DESCRIPTION = "Call def greet or use the greet helper"
        end
      RUBY

      results = call("greet")
      assert_equal [], results
    end

    # -------------------------------------------------------------------------
    # excluded_paths parameter
    # -------------------------------------------------------------------------

    test "skips files under an excluded_paths path prefix" do
      write_rb("app/models/user.rb",       "class User\n  def the_method\n  end\nend\n")
      write_rb("public/assets/bundle.rb",  "class Bundle\n  def the_method\n  end\nend\n")

      results = call("the_method", excluded_paths: %w[public/assets])

      assert results.any? { |r| r[:file] == "app/models/user.rb" },
             "app/models/user.rb should be included"
      assert results.none? { |r| r[:file].start_with?("public/assets/") },
             "files under public/assets should be excluded"
    end

    test "skips files matching an excluded_paths basename" do
      write_rb("app/models/user.rb",       "class User\n  def the_method\n  end\nend\n")
      write_rb("app/models/generated.rb",  "class Generated\n  def the_method\n  end\nend\n")

      results = call("the_method", excluded_paths: %w[generated.rb])

      assert results.any? { |r| r[:file] == "app/models/user.rb" },
             "app/models/user.rb should be included"
      assert results.none? { |r| r[:file].end_with?("generated.rb") },
             "files named generated.rb should be excluded"
    end

    # -------------------------------------------------------------------------
    # Malformed file does not crash the scan
    # -------------------------------------------------------------------------

    test "skips unparseable files without raising" do
      write_rb("app/bad.rb", "def this is not valid ruby {{ {{{")
      write_rb("app/good.rb", "class Good\n  def good_method\n  end\nend\n")

      results = call("good_method")
      assert_equal 1, results.length
      assert_equal "app/good.rb", results[0][:file]
    end
  end
end
