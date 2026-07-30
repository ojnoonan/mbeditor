# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Mbeditor
  # Runs against a throwaway repo rather than the project checkout: the hunk
  # classification only means anything against known content.
  class GitLineDiffServiceTest < ActiveSupport::TestCase
    def setup
      @repo = Dir.mktmpdir("mbeditor_line_diff_")
      git "init", "--quiet"
      git "config", "user.email", "test@example.com"
      git "config", "user.name", "Test"
      git "config", "commit.gpgsign", "false"
    end

    def teardown
      FileUtils.rm_rf(@repo)
    end

    def git(*args)
      out, status = GitService.run_git(@repo, *args)
      raise "git #{args.join(' ')} failed: #{out}" unless status.success?

      out
    end

    def write(path, lines)
      File.write(File.join(@repo, path), lines.join("\n") + "\n")
    end

    def commit(path, lines)
      write(path, lines)
      git "add", path
      git "commit", "--quiet", "-m", "commit #{path}"
    end

    def line_diff(path = "file.txt")
      GitLineDiffService.new(repo_path: @repo, file_path: path).call
    end

    test "a committed file with no working-tree edits is clean" do
      commit "file.txt", %w[one two three]

      assert_equal({ "added" => [], "modified" => [], "deleted" => [], "tracked" => true }, line_diff)
    end

    test "inserted lines are reported as added at their new positions" do
      commit "file.txt", %w[one two three]
      write "file.txt", %w[one inserted-a inserted-b two three]

      result = line_diff
      assert_equal [{ "start" => 2, "end" => 3 }], result["added"]
      assert_equal [], result["modified"]
      assert_equal [], result["deleted"]
    end

    test "changed lines are reported as modified, not as add plus delete" do
      commit "file.txt", %w[one two three]
      write "file.txt", %w[one CHANGED three]

      result = line_diff
      assert_equal [{ "start" => 2, "end" => 2 }], result["modified"]
      assert_equal [], result["added"]
      assert_equal [], result["deleted"]
    end

    test "removed lines are reported as a deletion marker on the preceding line" do
      commit "file.txt", %w[one two three four]
      write "file.txt", %w[one four]

      result = line_diff
      assert_equal [{ "start" => 1, "end" => 1 }], result["deleted"],
                   "two and three followed line 1 in the new file"
      assert_equal [], result["added"]
      assert_equal [], result["modified"]
    end

    test "removing the opening lines reports the marker above line one" do
      commit "file.txt", %w[one two three]
      write "file.txt", %w[three]

      assert_equal [{ "start" => 0, "end" => 0 }], line_diff["deleted"]
    end

    test "an untracked file counts entirely as added" do
      commit "other.txt", %w[x]
      write "new.txt", %w[a b c]

      result = line_diff("new.txt")
      assert_equal [{ "start" => 1, "end" => 3 }], result["added"]
      assert_equal false, result["tracked"]
    end

    test "an empty untracked file reports nothing" do
      commit "other.txt", %w[x]
      File.write(File.join(@repo, "empty.txt"), "")

      result = line_diff("empty.txt")
      assert_equal [], result["added"]
      assert_equal false, result["tracked"]
    end

    test "several hunks in one file are classified independently" do
      commit "file.txt", %w[a b c d e f g h]
      write "file.txt", %w[a INSERTED b c CHANGED f g h]

      result = line_diff
      assert_equal [{ "start" => 2, "end" => 2 }], result["added"]
      # d and e collapse into the single line CHANGED. git emits that as one
      # hunk with lines on both sides, so it reads as modified rather than as a
      # modification plus a deletion — same call VS Code's gutter makes.
      assert_equal [{ "start" => 5, "end" => 5 }], result["modified"]
      assert_equal [], result["deleted"]
    end

    test "a staged change still counts, since the diff is taken against HEAD" do
      commit "file.txt", %w[one two]
      write "file.txt", %w[one CHANGED]
      git "add", "file.txt"

      assert_equal [{ "start" => 2, "end" => 2 }], line_diff["modified"]
    end
  end
end
