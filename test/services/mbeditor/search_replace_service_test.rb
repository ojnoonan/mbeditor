# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class SearchReplaceServiceTest < ActiveSupport::TestCase
    def setup
      @workspace = Dir.mktmpdir("mbeditor_search_replace_test_")
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def write_file(relative_path, content)
      full = File.join(@workspace, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def with_rg_available(value)
      original = SearchReplaceService::RG_AVAILABLE
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :RG_AVAILABLE)
      SearchReplaceService.const_set(:RG_AVAILABLE, value)
      $VERBOSE = true
      yield
    ensure
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :RG_AVAILABLE)
      SearchReplaceService.const_set(:RG_AVAILABLE, original)
      $VERBOSE = true
    end

    def search(query, **opts)
      defaults = { limit: 100, use_regex: false, match_case: true, whole_word: false, excluded_paths: [] }
      SearchReplaceService.search(@workspace, query, **defaults.merge(opts))
    end

    def count(query, **opts)
      defaults = { use_regex: false, match_case: true, whole_word: false, excluded_paths: [] }
      SearchReplaceService.count(@workspace, query, **defaults.merge(opts))
    end

    def replace(query, replacement, **opts)
      defaults = { use_regex: false, match_case: true, whole_word: false, excluded_paths: [] }
      SearchReplaceService.replace(@workspace, query, replacement, **defaults.merge(opts))
    end

    def with_file_size_cap(n)
      original = FileOperationService::MAX_FILE_SIZE_BYTES
      $VERBOSE = nil
      FileOperationService.send(:remove_const, :MAX_FILE_SIZE_BYTES)
      FileOperationService.const_set(:MAX_FILE_SIZE_BYTES, n)
      $VERBOSE = true
      yield
    ensure
      $VERBOSE = nil
      FileOperationService.send(:remove_const, :MAX_FILE_SIZE_BYTES)
      FileOperationService.const_set(:MAX_FILE_SIZE_BYTES, original)
      $VERBOSE = true
    end

    def with_instant_timeout
      original = Timeout.method(:timeout)
      Timeout.define_singleton_method(:timeout) { |*_| raise Timeout::Error }
      yield
    ensure
      Timeout.define_singleton_method(:timeout, &original)
    end

    # ---------------------------------------------------------------------------
    # .replace — tracer bullet
    # ---------------------------------------------------------------------------

    test ".replace returns correct shape for a basic string replace" do
      write_file("app/models/user.rb", "class User\n  ROLE = 'admin'\nend\n")

      result = replace("admin", "superuser")

      assert_equal 1, result[:replaced_count]
      assert_includes result[:files_affected], "app/models/user.rb"
      assert_equal [], result[:errors]
      assert_equal false, result[:partial]
      assert_includes File.read(File.join(@workspace, "app/models/user.rb")), "superuser"
    end

    test ".replace with use_regex:true treats query as a regex" do
      write_file("lib/app.rb", "foo123\nfoo456\nbaz\n")

      result = replace("foo\\d+", "bar", use_regex: true)

      assert_equal 2, result[:replaced_count]
      assert_includes result[:files_affected], "lib/app.rb"
      assert_equal "bar\nbar\nbaz\n", File.read(File.join(@workspace, "lib/app.rb"))
    end

    test ".replace with whole_word:true only replaces complete words" do
      write_file("lib/words.rb", "admin administrator superadmin\n")

      result = replace("admin", "root", whole_word: true)

      assert_equal 1, result[:replaced_count]
      content = File.read(File.join(@workspace, "lib/words.rb"))
      assert_includes content, "root"
      assert_includes content, "administrator"
      assert_includes content, "superadmin"
    end

    test ".replace with match_case:false replaces regardless of case" do
      write_file("lib/app.rb", "ADMIN\nadmin\nAdmin\n")

      result = replace("admin", "user", match_case: false)

      assert_equal 3, result[:replaced_count]
      assert_equal "user\nuser\nuser\n", File.read(File.join(@workspace, "lib/app.rb"))
    end

    test ".replace skips files in excluded_paths" do
      write_file("app/code.rb",   "NEEDLE\n")
      write_file("vendor/lib.rb", "NEEDLE\n")

      result = replace("NEEDLE", "PIN", excluded_paths: ["vendor"])

      assert_includes result[:files_affected], "app/code.rb"
      assert_not_includes result[:files_affected], "vendor/lib.rb"
      assert_equal [], result[:errors]
    end

    test ".replace surfaces error for file exceeding size limit" do
      write_file("lib/big.rb", "NEEDLE\n")

      with_file_size_cap(0) do
        result = replace("NEEDLE", "PIN")
        assert result[:errors].any? { |e| e[:error].include?("File too large") }
        assert_not_includes result[:files_affected], "lib/big.rb"
      end
    end

    test ".replace surfaces error when per-file timeout is exceeded" do
      write_file("lib/app.rb", "NEEDLE\n")

      with_instant_timeout do
        result = replace("NEEDLE", "PIN")
        assert result[:errors].any? { |e| e[:error].include?("Timed out") }
        assert_equal [], result[:files_affected]
      end
    end

    test ".replace returns error response when file count exceeds MAX_REPLACE_FILES" do
      write_file("lib/app.rb", "NEEDLE\n")
      original = SearchReplaceService::MAX_REPLACE_FILES
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :MAX_REPLACE_FILES)
      SearchReplaceService.const_set(:MAX_REPLACE_FILES, 0)
      $VERBOSE = true

      result = replace("NEEDLE", "PIN")

      assert result.key?(:error)
      assert_match(/too many files/i, result[:error])
    ensure
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :MAX_REPLACE_FILES)
      SearchReplaceService.const_set(:MAX_REPLACE_FILES, original)
      $VERBOSE = true
    end

    test ".replace sets partial:true when some files replaced and some errored" do
      write_file("lib/good.rb", "NEEDLE\n")                       # 7 bytes — under cap
      write_file("lib/bad.rb",  "NEEDLE" + ("x" * 100) + "\n")   # 107 bytes — over cap

      with_file_size_cap(50) do
        result = replace("NEEDLE", "PIN")
        assert_equal true, result[:partial]
        assert result[:files_affected].any?
        assert result[:errors].any? { |e| e[:error].include?("File too large") }
      end
    end

    test ".replace handles binary/mixed-encoding files without raising" do
      binary_path = File.join(@workspace, "lib", "binary.rb")
      FileUtils.mkdir_p(File.dirname(binary_path))
      File.binwrite(binary_path, "NEEDLE\xFF\xFE\n")

      result = replace("NEEDLE", "PIN")

      assert_nil result[:error]
      assert_includes result[:files_affected], "lib/binary.rb"
    end

    # ---------------------------------------------------------------------------
    # .count — basic
    # ---------------------------------------------------------------------------

    test "count returns an Integer equal to matched lines" do
      write_file("app/models/user.rb", "class User\nend\n")

      result = count("User")

      assert_kind_of Integer, result
      assert_equal 1, result
    end

    test "count returns 0 when query matches nothing" do
      write_file("app/models/user.rb", "class User\nend\n")

      assert_equal 0, count("NoSuchTokenXYZ")
    end

    test "count excludes lines in excluded_paths directories" do
      write_file("app/code.rb",   "NEEDLE\n")
      write_file("vendor/lib.rb", "NEEDLE\nNEEDLE\n")

      result = count("NEEDLE", excluded_paths: ["vendor"])

      assert_equal 1, result
    end

    test "grep branch counts matching lines and returns Integer" do
      write_file("app/models/user.rb", "class User\nUser = 1\nend\n")

      with_rg_available(false) do
        result = count("User")

        assert_kind_of Integer, result
        assert result >= 1
      end
    end

    test "grep branch returns 0 for no matches" do
      write_file("app/models/user.rb", "class User\nend\n")

      with_rg_available(false) do
        assert_equal 0, count("NoSuchTokenXYZ")
      end
    end

    test "count grep branch respects excluded_paths for plain directory names" do
      write_file("app/code.rb",   "NEEDLE\n")
      write_file("vendor/lib.rb", "NEEDLE\nNEEDLE\n")

      with_rg_available(false) do
        result = count("NEEDLE", excluded_paths: ["vendor"])

        assert_equal 1, result
      end
    end

    # ---------------------------------------------------------------------------
    # Basic string match
    # ---------------------------------------------------------------------------

    # ---------------------------------------------------------------------------
    # Whole-word
    # ---------------------------------------------------------------------------

    test "whole_word true only matches complete words" do
      write_file("lib/words.rb", "foo\nfoobar\nfoo_baz\n")

      results = search("foo", whole_word: true)

      assert_equal 1, results.length
      assert_equal "foo", results.first[:text]
    end

    # ---------------------------------------------------------------------------
    # Case sensitivity
    # ---------------------------------------------------------------------------

    test "match_case false matches regardless of case" do
      write_file("lib/words.rb", "Hello World\n")

      results = search("hello", match_case: false)

      assert_equal 1, results.length
    end

    test "match_case true does not match wrong case" do
      write_file("lib/words.rb", "Hello World\n")

      results = search("hello", match_case: true)

      assert_equal [], results
    end

    # ---------------------------------------------------------------------------
    # Regex
    # ---------------------------------------------------------------------------

    test "use_regex true treats query as a regular expression" do
      write_file("lib/foo.rb", "foo_bar\nfoo123\nbaz\n")

      results = search("foo\\w+", use_regex: true)

      assert_equal 2, results.length
      assert results.all? { |r| r[:text].match?(/foo\w+/) }
    end

    # ---------------------------------------------------------------------------
    # excluded_paths
    # ---------------------------------------------------------------------------

    test "excluded_paths keeps matching files out of results" do
      write_file("app/code.rb",   "NEEDLE\n")
      write_file("vendor/lib.rb", "NEEDLE\n")

      results = search("NEEDLE", excluded_paths: ["vendor"])

      files = results.map { |r| r[:file] }
      assert_includes     files, "app/code.rb"
      assert_not_includes files, "vendor/lib.rb"
    end

    # ---------------------------------------------------------------------------
    # grep fallback branch
    # ---------------------------------------------------------------------------

    test "grep branch returns same file/line/text shape when RG_AVAILABLE is false" do
      write_file("app/models/user.rb", "class User\nend\n")

      with_rg_available(false) do
        results = search("User")

        assert_equal 1, results.length
        result = results.first
        assert_equal "app/models/user.rb", result[:file]
        assert_equal 1, result[:line]
        assert_includes result[:text], "User"
      end
    end

    test "grep branch respects excluded_paths for plain directory names" do
      write_file("app/code.rb",   "NEEDLE\n")
      write_file("vendor/lib.rb", "NEEDLE\n")

      with_rg_available(false) do
        results = search("NEEDLE", excluded_paths: ["vendor"])

        files = results.map { |r| r[:file] }
        assert_includes     files, "app/code.rb"
        assert_not_includes files, "vendor/lib.rb"
      end
    end

    test "returns empty array when query does not match anything" do
      write_file("app/models/user.rb", "class User\nend\n")

      results = search("NoSuchTokenXYZ")

      assert_equal [], results
    end

    test "limit stops collection after N results" do
      write_file("many.rb", (1..20).map { |i| "match_token_#{i}" }.join("\n"))

      results = search("match_token", limit: 5)

      assert_equal 5, results.length
    end

    test "returns array of hashes with file, line, text for a matching string" do
      write_file("app/models/user.rb", "class User\nend\n")

      results = search("User")

      assert_equal 1, results.length
      result = results.first
      assert_equal "app/models/user.rb", result[:file]
      assert_equal 1, result[:line]
      assert_includes result[:text], "User"
    end
  end
end
