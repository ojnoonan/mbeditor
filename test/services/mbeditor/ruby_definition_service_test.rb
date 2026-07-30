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

    test "skips files inside excluded dirname when passed as excluded_paths" do
      write_rb("app/models/user.rb", "class User\n  def the_method\n  end\nend\n")
      write_rb("tmp/cache/generated.rb", "class Cache\n  def the_method\n  end\nend\n")

      results = call("the_method", excluded_paths: %w[tmp])
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
    # included_dirs filtering
    # -------------------------------------------------------------------------

    test "only scans files within included_dirs" do
      write_rb("app/models/user.rb",        "class User\n  def the_method\n  end\nend\n")
      write_rb("db/migrate/20240101_foo.rb", "class Foo\n  def the_method\n  end\nend\n")
      write_rb("spec/models/user_spec.rb",   "class UserSpec\n  def the_method\n  end\nend\n")

      results = call("the_method", included_dirs: %w[app/models])
      assert_equal 1, results.length
      assert_equal "app/models/user.rb", results[0][:file]
    end

    test "empty included_dirs scans the whole workspace" do
      write_rb("app/models/user.rb", "class User\n  def the_method\n  end\nend\n")
      write_rb("lib/util.rb",        "module Util\n  def the_method\n  end\nend\n")

      results = call("the_method", included_dirs: [])
      assert results.length >= 2, "expected both files to be found"
    end

    test "non-existent included_dirs falls back to scanning workspace root" do
      write_rb("app/models/user.rb", "class User\n  def the_method\n  end\nend\n")

      results = call("the_method", included_dirs: %w[app/nonexistent])
      assert results.any?, "expected fallback scan to find the method"
    end

    test "module_defined_in respects included_dirs" do
      write_rb("app/concerns/searchable.rb", "module Searchable; end\n")
      write_rb("lib/searchable.rb",          "module Searchable; end\n")

      result = RubyDefinitionService.module_defined_in(
        @workspace, "Searchable",
        included_dirs: %w[app/concerns]
      )
      assert_equal File.join(@workspace, "app/concerns/searchable.rb"), result
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

    # -------------------------------------------------------------------------
    # defs_in_file self-warms on cache miss
    # -------------------------------------------------------------------------

    test "defs_in_file returns correct results for a file never scanned" do
      write_rb("app/models/user.rb", <<~RUBY)
        class User
          def find_by_email(email)
          end

          def save!
          end
        end
      RUBY
      abs_path = File.join(@workspace, "app/models/user.rb")

      result = RubyDefinitionService.defs_in_file(abs_path)

      assert_includes result.keys, "find_by_email"
      assert_includes result.keys, "save!"
      assert_equal 2, result["find_by_email"].first[:line]
      assert_includes result["find_by_email"].first[:signature], "def find_by_email"
    end

    # -------------------------------------------------------------------------
    # includes_in_file self-warms on cache miss
    # -------------------------------------------------------------------------

    test "includes_in_file returns correct modules for a file never scanned" do
      write_rb("app/models/article.rb", <<~RUBY)
        class Article
          include Searchable
          extend ClassMethods
          prepend Validatable
        end
      RUBY
      abs_path = File.join(@workspace, "app/models/article.rb")

      result = RubyDefinitionService.includes_in_file(abs_path)

      assert_includes result, "Searchable"
      assert_includes result, "ClassMethods"
      assert_includes result, "Validatable"
    end

    test "includes_in_file returns empty array for a file with no include calls" do
      write_rb("app/models/plain.rb", <<~RUBY)
        class Plain
          def hello; end
        end
      RUBY
      abs_path = File.join(@workspace, "app/models/plain.rb")

      result = RubyDefinitionService.includes_in_file(abs_path)

      assert_equal [], result
    end

    # -------------------------------------------------------------------------
    # Public interface contract
    # -------------------------------------------------------------------------

    test "scan is not part of the public interface" do
      assert_not RubyDefinitionService.respond_to?(:scan),
                 "scan should not be publicly callable"
    end

    test "cache lifecycle methods are not part of the public interface" do
      %i[file_cache mutex load_disk_cache_once persist_cache].each do |m|
        assert_not RubyDefinitionService.respond_to?(m),
                   "#{m} should not be publicly callable"
      end
    end

    test "six specified public methods are all accessible" do
      %i[call defs_in_file module_defined_in includes_in_file cache_path= clear_cache!].each do |m|
        assert RubyDefinitionService.respond_to?(m),
               "#{m} should be publicly callable"
      end
    end

    # -------------------------------------------------------------------------
    # Disk-cache cap (entries carry full file contents, so it must be bounded)
    # -------------------------------------------------------------------------

    def cache_hash
      RubyDefinitionService.send(:file_cache)
    end

    def with_cache_cap(n)
      original = RubyDefinitionService::MAX_CACHE_ENTRIES
      $VERBOSE = nil
      RubyDefinitionService.send(:remove_const, :MAX_CACHE_ENTRIES)
      RubyDefinitionService.const_set(:MAX_CACHE_ENTRIES, n)
      $VERBOSE = true
      yield
    ensure
      $VERBOSE = nil
      RubyDefinitionService.send(:remove_const, :MAX_CACHE_ENTRIES)
      RubyDefinitionService.const_set(:MAX_CACHE_ENTRIES, original)
      $VERBOSE = true
    end

    def with_cache_path
      Dir.mktmpdir do |dir|
        original = RubyDefinitionService.cache_path
        RubyDefinitionService.cache_path = File.join(dir, "defs.json")
        yield RubyDefinitionService.cache_path
      ensure
        RubyDefinitionService.cache_path = original
      end
    end

    test "persisting trims the cache to MAX_CACHE_ENTRIES, dropping the oldest first" do
      5.times { |i| write_rb("file#{i}.rb", "def m#{i}\nend\n") }

      with_cache_cap(3) do
        with_cache_path do |path|
          svc = RubyDefinitionService.new(@workspace, nil)
          5.times { |i| svc.send(:cache_entry_for, File.join(@workspace, "file#{i}.rb")) }
          assert_equal 5, cache_hash.length, "entries accumulate during a scan"

          RubyDefinitionService.send(:persist_cache)

          assert_equal 3, cache_hash.length
          remaining = cache_hash.keys.map { |k| File.basename(k) }
          assert_equal %w[file2.rb file3.rb file4.rb], remaining
          assert_equal 3, JSON.parse(File.read(path)).length
        end
      end
    end

    test "a re-read entry survives eviction ahead of older untouched ones" do
      3.times { |i| write_rb("f#{i}.rb", "def m#{i}\nend\n") }

      with_cache_cap(2) do
        with_cache_path do
          svc = RubyDefinitionService.new(@workspace, nil)
          svc.send(:cache_entry_for, File.join(@workspace, "f0.rb"))
          svc.send(:cache_entry_for, File.join(@workspace, "f1.rb"))
          # Touch the oldest entry — it must now be the most recently used.
          svc.send(:cache_entry_for, File.join(@workspace, "f0.rb"))
          svc.send(:cache_entry_for, File.join(@workspace, "f2.rb"))

          RubyDefinitionService.send(:persist_cache)

          remaining = cache_hash.keys.map { |k| File.basename(k) }
          assert_equal %w[f0.rb f2.rb], remaining, "f1 was least recently used"
        end
      end
    end

    test "definitions still resolve after the cache has been trimmed" do
      write_rb("target.rb", "def findable_method\nend\n")

      with_cache_cap(1) do
        with_cache_path do
          RubyDefinitionService.call(@workspace, "findable_method")
          RubyDefinitionService.send(:persist_cache)
          assert_operator cache_hash.length, :<=, 1

          results = RubyDefinitionService.call(@workspace, "findable_method")
          assert_equal 1, results.length
          assert_equal "target.rb", results.first[:file]
        end
      end
    end
  end
end
