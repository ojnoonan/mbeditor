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
      original = AvailabilityProbe.method(:rg)
      AvailabilityProbe.define_singleton_method(:rg) { value }
      yield
    ensure
      AvailabilityProbe.singleton_class.send(:remove_method, :rg)
      AvailabilityProbe.define_singleton_method(:rg, original)
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

    # ---------------------------------------------------------------------------
    # rg availability
    # ---------------------------------------------------------------------------
    # The probe itself (caching + re-probing after a negative result) is owned
    # by AvailabilityProbe and covered in its own test; here we only assert the
    # delegation, so the two can't drift apart.

    test "rg_available? delegates to the shared AvailabilityProbe" do
      with_rg_available(true)  { assert SearchReplaceService.rg_available? }
      with_rg_available(false) { assert_not SearchReplaceService.rg_available? }
    end

    # ---------------------------------------------------------------------------
    # git grep tier
    # ---------------------------------------------------------------------------

    test "git grep tier is used in a git repo when rg is unavailable and finds untracked files" do
      system("git", "-C", @workspace, "init", "-q", exception: true)
      write_file("app/models/user.rb", "class User\nend\n")

      with_rg_available(false) do
        env, args = SearchReplaceService.send(:build_command, :git, @workspace, "User",
                                              use_regex: false, match_case: true, whole_word: false,
                                              excluded_paths: [], paths: nil)
        assert_equal "git", args.first
        # No LC_ALL override: the C locale is neutral for the -F -i default and
        # measurably slower for -E, so the tier inherits the process locale.
        assert_nil env["LC_ALL"]

        results = search("User")
        assert_equal 1, results.length
        assert_equal "app/models/user.rb", results.first[:file]
        assert_equal 1, results.first[:line]
      end
    end

    # An excluded directory must be kept out of git's own traversal, not merely
    # filtered out of the results afterwards. Post-filtering still pays for git
    # walking node_modules in full, which is what made search unusable on real
    # host apps; assert the pathspecs are actually on the command line.
    test "the git tier passes excluded paths to git as :(exclude) pathspecs" do
      _env, args = SearchReplaceService.send(:build_command, :git, @workspace, "x",
                                             use_regex: false, match_case: true, whole_word: false,
                                             excluded_paths: ["node_modules", "vendor/bundle"], paths: nil)
      assert_includes args, ":(exclude)node_modules"
      assert_includes args, ":(exclude)vendor/bundle"
    end

    test "the git tier excludes configured paths from the results it returns" do
      system("git", "-C", @workspace, "init", "-q", exception: true)
      write_file("app/models/user.rb", "class User\nend\n")
      write_file("node_modules/pkg/user.js", "var User = 1;\n")

      with_rg_available(false) do
        results = search("User", excluded_paths: ["node_modules"])
        assert_equal ["app/models/user.rb"], results.map { |r| r[:file] }
      end
    end

    # ---------------------------------------------------------------------------
    # search_respect_gitignore
    # ---------------------------------------------------------------------------

    def with_respect_gitignore(value)
      original = Mbeditor.configuration.search_respect_gitignore
      Mbeditor.configuration.search_respect_gitignore = value
      yield
    ensure
      Mbeditor.configuration.search_respect_gitignore = original
    end

    test "the rg tier drops --no-ignore only when gitignore is respected" do
      args_for = lambda do
        SearchReplaceService.send(:build_command, :rg, @workspace, "x",
                                  use_regex: false, match_case: true, whole_word: false,
                                  excluded_paths: [], paths: nil).last
      end

      with_respect_gitignore(false) { assert_includes args_for.call, "--no-ignore" }
      with_respect_gitignore(true) { assert_not_includes args_for.call, "--no-ignore" }
    end

    test "the git tier swaps --untracked and --no-index, which cannot be combined" do
      args_for = lambda do
        SearchReplaceService.send(:build_command, :git, @workspace, "x",
                                  use_regex: false, match_case: true, whole_word: false,
                                  excluded_paths: [], paths: nil).last
      end

      with_respect_gitignore(true) do
        args = args_for.call
        assert_includes args, "--untracked"
        assert_not_includes args, "--no-index"
      end
      with_respect_gitignore(false) do
        args = args_for.call
        assert_includes args, "--no-index"
        assert_not_includes args, "--untracked"
      end
    end

    test "gitignored files are searched only when the config allows it" do
      system("git", "-C", @workspace, "init", "-q", exception: true)
      File.write(File.join(@workspace, ".gitignore"), "ignored/\n")
      write_file("ignored/hidden.rb", "GITIGNORE_NEEDLE\n")
      write_file("visible.rb", "GITIGNORE_NEEDLE\n")

      with_rg_available(false) do
        with_respect_gitignore(false) do
          SearchReplaceService.invalidate_cache(@workspace)
          files = search("GITIGNORE_NEEDLE").map { |r| r[:file] }
          assert_includes files, "visible.rb"
          assert_includes files, "ignored/hidden.rb", "default behaviour searches ignored files"
        end

        with_respect_gitignore(true) do
          SearchReplaceService.invalidate_cache(@workspace)
          files = search("GITIGNORE_NEEDLE").map { |r| r[:file] }
          assert_includes files, "visible.rb"
          assert_not_includes files, "ignored/hidden.rb"
        end
      end
    ensure
      SearchReplaceService.invalidate_cache(@workspace)
    end

    test "grep tier command uses LC_ALL=C, -I, and drops slashed exclude-dirs" do
      env, args = SearchReplaceService.send(:build_command, :grep, @workspace, "x",
                                            use_regex: false, match_case: false, whole_word: false,
                                            excluded_paths: %w[node_modules vendor/bundle], paths: nil)
      assert_equal "C", env["LC_ALL"]
      assert_includes args, "-I"
      assert_includes args, "-i"
      assert_includes args, "--exclude-dir=node_modules"
      assert_not_includes args, "--exclude-dir=vendor/bundle"
    end

    # ---------------------------------------------------------------------------
    # search_page — single scan, cached pagination, totals
    # ---------------------------------------------------------------------------

    test "search_page reports exact total_count and pages from one cached scan" do
      write_file("many.rb", (1..20).map { |i| "match_token_#{i}" }.join("\n"))

      page1 = SearchReplaceService.search_page(@workspace, "match_token", offset: 0, limit: 5,
                                               use_regex: false, match_case: true, whole_word: false, excluded_paths: [])
      assert_equal 5, page1[:results].length
      assert_equal 20, page1[:total_count]
      assert page1[:has_more]
      assert_equal false, page1[:partial]

      # Second page must come from the cache — no new subprocess.
      singleton = class << SearchReplaceService; self; end
      singleton.alias_method :__orig_scan, :scan
      SearchReplaceService.define_singleton_method(:scan) { |*| raise "scan must not run for a cached page" }
      begin
        page2 = SearchReplaceService.search_page(@workspace, "match_token", offset: 5, limit: 5,
                                                 use_regex: false, match_case: true, whole_word: false, excluded_paths: [])
        assert_equal 5, page2[:results].length
        assert_equal 20, page2[:total_count]
      ensure
        singleton.remove_method :scan
        singleton.alias_method :scan, :__orig_scan
        singleton.remove_method :__orig_scan
      end
    ensure
      SearchReplaceService.invalidate_cache(@workspace)
    end

    test "search_page omits total_count when the result cap truncates the scan" do
      write_file("many.rb", (1..10).map { |i| "capped_token_#{i}" }.join("\n"))

      original = SearchReplaceService::MAX_RESULTS
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :MAX_RESULTS)
      SearchReplaceService.const_set(:MAX_RESULTS, 5)
      $VERBOSE = true

      page = SearchReplaceService.search_page(@workspace, "capped_token", offset: 0, limit: 3,
                                              use_regex: false, match_case: true, whole_word: false, excluded_paths: [])
      assert_equal 3, page[:results].length
      assert_nil page[:total_count]
      assert page[:partial]
    ensure
      $VERBOSE = nil
      SearchReplaceService.send(:remove_const, :MAX_RESULTS)
      SearchReplaceService.const_set(:MAX_RESULTS, original)
      $VERBOSE = true
      SearchReplaceService.invalidate_cache(@workspace)
    end

    test "invalidate_cache forces the next search to re-scan" do
      write_file("app.rb", "CACHE_NEEDLE\n")
      first = SearchReplaceService.search_page(@workspace, "CACHE_NEEDLE", offset: 0, limit: 10,
                                               use_regex: false, match_case: true, whole_word: false, excluded_paths: [])
      assert_equal 1, first[:total_count]

      write_file("app2.rb", "CACHE_NEEDLE\n")
      SearchReplaceService.invalidate_cache(@workspace)
      second = SearchReplaceService.search_page(@workspace, "CACHE_NEEDLE", offset: 0, limit: 10,
                                                use_regex: false, match_case: true, whole_word: false, excluded_paths: [])
      assert_equal 2, second[:total_count]
    ensure
      SearchReplaceService.invalidate_cache(@workspace)
    end

    # ---------------------------------------------------------------------------
    # Supersede — a new search kills the previous subprocess for the workspace
    # ---------------------------------------------------------------------------

    test "registering a new search terminates the previous one" do
      old_pid = Process.spawn("sleep", "30")
      SearchReplaceService.send(:register_search, @workspace, old_pid)

      new_pid = Process.spawn("sleep", "30")
      SearchReplaceService.send(:register_search, @workspace, new_pid)

      Timeout.timeout(5) { Process.wait(old_pid) }
      assert_equal 15, Process.last_status.termsig, "old search should die from SIGTERM"
    ensure
      begin
        Process.kill("KILL", new_pid)
        Process.wait(new_pid)
      rescue StandardError
        nil
      end
      SearchReplaceService.send(:clear_search, @workspace, new_pid)
    end

    # ---------------------------------------------------------------------------
    # Single-file scoped search (live refresh)
    # ---------------------------------------------------------------------------

    test "search with paths: restricts the scan to those files" do
      write_file("a.rb", "SCOPED_NEEDLE\n")
      write_file("b.rb", "SCOPED_NEEDLE\n")

      results = search("SCOPED_NEEDLE", paths: [File.join(@workspace, "a.rb")])

      assert_equal 1, results.length
      assert_equal "a.rb", results.first[:file]
    end

    # ---------------------------------------------------------------------------
    # Tier selection
    # ---------------------------------------------------------------------------

    test "a .git git refuses to open falls back to grep instead of returning nothing" do
      write_file("a.rb", "BROKEN_REPO_NEEDLE\n")
      # A gitdir pointer to somewhere that isn't there: `.git` exists, so the
      # old presence check picked the git tier, git grep failed, and the search
      # came back instantly empty. Stands in for the field cases — dubious
      # ownership, a moved worktree, no git binary.
      File.write(File.join(@workspace, ".git"), "gitdir: /nonexistent/gitdir\n")
      AvailabilityProbe.reset!

      with_rg_available(false) do
        assert_equal :grep, SearchReplaceService.backend(@workspace)
        assert_equal 1, search("BROKEN_REPO_NEEDLE").length
      end
    ensure
      AvailabilityProbe.reset!
    end
  end
end
