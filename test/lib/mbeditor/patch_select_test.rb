# frozen_string_literal: true

require "test_helper"
require "open3"

begin
  require "mini_racer"
rescue LoadError
  # setup skips when MiniRacer is missing.
end

module Mbeditor
  class PatchSelectTest < ActiveSupport::TestCase
    SOURCE = File.expand_path("../../../app/assets/javascripts/mbeditor/patch_select.js", __dir__)

    def setup
      skip "mini_racer not available" unless defined?(::MiniRacer)

      @ctx = ::MiniRacer::Context.new
      @ctx.eval("var window = globalThis;")
      @ctx.eval(File.read(SOURCE))
      @dir = Dir.mktmpdir("mbeditor_select_")
      git("init", "-q")
      @numbers = (1..30).map { |i| "line #{i}\n" }.join
      write("a.txt", @numbers)
      write("b.txt", "bee\n")
      write("gone.txt", "bye\n")
      write("old.txt", "keep\nme\nhere\nplease\n")
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "base")
    end

    def teardown
      FileUtils.rm_rf(@dir) if @dir
    end

    def git(*args)
      out, status = Open3.capture2e("git", *args, chdir: @dir)
      assert status.success?, out
      out
    end

    def write(rel, body)
      File.binwrite(File.join(@dir, rel), body)
    end

    def read(rel)
      File.read(File.join(@dir, rel))
    end

    # Makes the working-tree edits, captures them as a staged diff, then puts
    # the tree back so the patch can be applied selectively.
    def capture_patch
      yield
      git("add", "-A")
      patch = git("diff", "--cached", "-M")
      git("reset", "-q", "--hard", "HEAD")
      git("clean", "-fdq")
      patch
    end

    def parse(patch)
      @ctx.eval("MbeditorPatchSelect.parse(#{patch.to_json})")
    end

    def build(patch, selection)
      @ctx.eval("MbeditorPatchSelect.build(MbeditorPatchSelect.parse(#{patch.to_json}), #{selection.to_json})")
    end

    def apply(patch)
      PatchApplyService.new(@dir).call(patch, check: false)
    end

    def multi_hunk_patch
      capture_patch do
        write("a.txt", @numbers.sub("line 1\n", "LINE 1\n").sub("line 15\n", "LINE 15\n").sub("line 30\n", "LINE 30\n"))
        write("b.txt", "BEE\n")
      end
    end

    test "parse splits files and hunks and rebuilding everything is byte-identical" do
      patch = multi_hunk_patch
      files = parse(patch)

      assert_equal %w[a.txt b.txt], files.map { |f| f["path"] }
      assert_equal [3, 1], files.map { |f| f["hunks"].length }
      assert_equal patch, build(patch, [[true, true, true], [true]])
    end

    test "dropping the middle hunk applies the others and leaves that one untouched" do
      patch = multi_hunk_patch
      apply(build(patch, [[true, false, true], [true]]))

      lines = read("a.txt").lines
      assert_equal "LINE 1\n", lines[0]
      assert_equal "line 15\n", lines[14]
      assert_equal "LINE 30\n", lines[29]
      assert_equal "BEE\n", read("b.txt")
    end

    test "dropping a file removes it from the patch" do
      patch = multi_hunk_patch
      built = build(patch, [[true, true, true], [false]])
      apply(built)

      refute_includes built, "b.txt"
      assert_equal "bee\n", read("b.txt")
      assert_equal "LINE 15\n", read("a.txt").lines[14]
    end

    test "a file with every hunk unchecked is dropped" do
      patch = multi_hunk_patch

      refute_includes build(patch, [[false, false, false], [true]]), "a.txt"
    end

    def mixed_patch
      capture_patch do
        write("a.txt", @numbers.sub("line 1\n", "LINE 1\n"))
        write("new.txt", "fresh\n")
        FileUtils.rm(File.join(@dir, "gone.txt"))
        FileUtils.mv(File.join(@dir, "old.txt"), File.join(@dir, "renamed.txt"))
        write("renamed.txt", "keep\nme\nhere\nTHANKS\n")
      end
    end

    test "created, deleted and renamed sections are atomic and report their status" do
      files = parse(mixed_patch)
      by_path = files.to_h { |f| [f["path"], f] }

      assert_equal %w[created deleted modified renamed], files.map { |f| f["status"] }.sort
      assert_equal "old.txt", by_path["renamed.txt"]["from"]
      assert_equal [true, true, true], %w[new.txt gone.txt renamed.txt].map { |p| by_path[p]["atomic"] }
      assert_equal false, by_path["a.txt"]["atomic"]
    end

    test "keeping only the modify and the delete skips the create and the rename" do
      patch = mixed_patch
      files = parse(patch)
      keep = files.map { |f| [%w[a.txt gone.txt].include?(f["path"])] * [f["hunks"].length, 1].max }
      apply(build(patch, keep))

      assert_equal "LINE 1\n", read("a.txt").lines.first
      refute File.exist?(File.join(@dir, "gone.txt"))
      refute File.exist?(File.join(@dir, "new.txt"))
      refute File.exist?(File.join(@dir, "renamed.txt"))
      assert File.exist?(File.join(@dir, "old.txt"))
    end

    test "keeping only the create and the rename skips the modify and the delete" do
      patch = mixed_patch
      files = parse(patch)
      keep = files.map { |f| [%w[new.txt renamed.txt].include?(f["path"])] * [f["hunks"].length, 1].max }
      apply(build(patch, keep))

      assert_equal "fresh\n", read("new.txt")
      assert_equal "keep\nme\nhere\nTHANKS\n", read("renamed.txt")
      refute File.exist?(File.join(@dir, "old.txt"))
      assert File.exist?(File.join(@dir, "gone.txt"))
      assert_equal @numbers, read("a.txt")
    end

    test "count units and touched paths follow the selection" do
      patch = mixed_patch
      files = parse(patch)
      sel = @ctx.eval("MbeditorPatchSelect.defaultSelection(MbeditorPatchSelect.parse(#{patch.to_json}))")
      count = @ctx.eval("MbeditorPatchSelect.count(MbeditorPatchSelect.parse(#{patch.to_json}), #{sel.to_json})")

      assert_equal({ "selected" => 4, "total" => 4 }, count)
      none = sel.map { |s| s.map { false } }
      touched = @ctx.eval("MbeditorPatchSelect.touchedPaths(MbeditorPatchSelect.parse(#{patch.to_json}), #{none.to_json})")
      assert_empty touched
      assert_equal files.length, sel.length
    end

    test "a plain non-git multi-file patch splits per file" do
      plain = "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n--- not a header\n+++ nor this\n"
      files = parse(plain)

      assert_equal %w[a.txt b.txt], files.map { |f| f["path"] }
      assert_equal plain, build(plain, [[true], [true]])
    end

    test "hunk counts keep a removed '-- y' and an added '++ z' line inside their hunk" do
      patch = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,2 +1,2 @@\n x\n--- y\n+++ z\n@@ -9 +9 @@\n-q\n+r\n"
      files = parse(patch)

      assert_equal 1, files.length
      assert_equal 2, files[0]["hunks"].length
      assert_equal patch, build(patch, [[true, true]])
    end

    test "without usable counts the old heuristic still splits plain-patch files" do
      patch = "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-1\n+2\n--- a/b\n+++ b/b\n@@ -1 +1 @@\n-1\n+2\n"

      assert_equal %w[a b], parse(patch).map { |f| f["path"] }
    end

    test "git C-quoted paths are unquoted" do
      patch = "diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\n--- \"a/caf\\303\\251.txt\"\n+++ \"b/caf\\303\\251.txt\"\n@@ -1 +1 @@\n-a\n+b\n"

      assert_equal "café.txt", parse(patch)[0]["path"]
    end

    test "touchedPaths prefers the server's file list when it lines up" do
      patch = "diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\n--- \"a/x\"\n+++ \"b/x\"\n@@ -1 +1 @@\n-a\n+b\n"
      out = @ctx.eval("(function(){var f=MbeditorPatchSelect.parse(#{patch.to_json});" \
                      "return MbeditorPatchSelect.touchedPaths(f,[[true]],[{path:'server/path.txt'}]);})()")

      assert_equal ["server/path.txt"], out
    end
  end
end
