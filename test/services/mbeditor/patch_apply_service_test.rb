# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class PatchApplyServiceTest < ActiveSupport::TestCase
    def setup
      @dir = Dir.mktmpdir("mbeditor_patch_")
      system("git", "init", "-q", @dir, exception: true)
      File.write(File.join(@dir, "a.txt"), "one\ntwo\nthree\n")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def apply(patch, check: false)
      PatchApplyService.new(@dir).call(patch, check: check)
    end

    def read(rel)
      File.read(File.join(@dir, rel))
    end

    MODIFY = <<~DIFF
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -1,3 +1,3 @@
       one
      -two
      +TWO
       three
    DIFF

    test "check lists files and writes nothing" do
      result = apply(MODIFY, check: true)

      assert_equal [{ path: "a.txt", added: 1, removed: 1, status: :modified }], result[:files]
      assert_equal MODIFY, result[:patch]
      assert_equal "one\ntwo\nthree\n", read("a.txt")
    end

    test "apply writes the change" do
      apply(MODIFY)

      assert_equal "one\nTWO\nthree\n", read("a.txt")
    end

    test "strips surrounding prose and a markdown fence, and CRLF" do
      reply = "Sure, here it is:\r\n\r\n```diff\r\n#{MODIFY.gsub("\n", "\r\n")}```\r\n\r\nHope that helps."
      result = apply(reply)

      assert_equal "one\nTWO\nthree\n", read("a.txt")
      assert_equal MODIFY, result[:patch]
    end

    test "wrong hunk counts are recounted" do
      apply(MODIFY.sub("@@ -1,3 +1,3 @@", "@@ -1,9 +1,9 @@"))

      assert_equal "one\nTWO\nthree\n", read("a.txt")
    end

    test "a mixed-ending patch for a CRLF file is left alone" do
      File.binwrite(File.join(@dir, "w.txt"), "a\r\nb\r\n")
      patch = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n"
      apply(patch)

      assert_equal "a\r\nB\r\n".b, File.binread(File.join(@dir, "w.txt"))
    end

    test "creates and deletes files" do
      create = "diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+hi\n"
      result = apply(create)
      assert_equal [{ path: "n.txt", added: 1, removed: 0, status: :created }], result[:files]
      assert_equal "hi\n", read("n.txt")

      delete = "diff --git a/a.txt b/a.txt\ndeleted file mode 100644\n--- a/a.txt\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-one\n-two\n-three\n"
      result = apply(delete)
      assert_equal :deleted, result[:files].first[:status]
      refute File.exist?(File.join(@dir, "a.txt"))
    end

    test "a create, delete and modify in one patch check cleanly then apply" do
      File.write(File.join(@dir, "gone.txt"), "bye\n")
      patch = <<~DIFF
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        #{MODIFY.chomp}
      DIFF

      checked = apply(patch, check: true)
      assert_equal({ "new.txt" => :created, "gone.txt" => :deleted, "a.txt" => :modified },
                   checked[:files].to_h { |f| [f[:path], f[:status]] })
      refute File.exist?(File.join(@dir, "new.txt"))
      assert File.exist?(File.join(@dir, "gone.txt"))
      assert_equal "one\ntwo\nthree\n", read("a.txt")

      apply(patch)
      assert_equal "hello\nworld\n", read("new.txt")
      refute File.exist?(File.join(@dir, "gone.txt"))
      assert_equal "one\nTWO\nthree\n", read("a.txt")
    end

    test "reports a rename" do
      rename = "diff --git a/a.txt b/b.txt\nsimilarity index 100%\nrename from a.txt\nrename to b.txt\n"
      result = apply(rename)

      assert_equal :renamed, result[:files].first[:status]
      assert_equal "b.txt", result[:files].first[:path]
      assert_equal "a.txt", result[:files].first[:from]
      assert File.exist?(File.join(@dir, "b.txt"))
    end

    test "rejects parent-directory and .git paths" do
      config_before = File.read(File.join(@dir, ".git", "config"))
      ["../x", ".git/config", "sub/.git/hooks/pre-commit"].each do |path|
        patch = "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1 @@\n+x\n"
        assert_raises(PatchApplyService::Error, path) { apply(patch) }
      end
      refute File.exist?(File.join(@dir, "..", "x"))
      assert_equal config_before, File.read(File.join(@dir, ".git", "config"))
    end

    test "a failing hunk returns git's stderr" do
      bad = MODIFY.sub("-two", "-nope")
      err = assert_raises(PatchApplyService::Error) { apply(bad, check: true) }

      assert_match(/a\.txt/, err.message)
      assert_match(/patch does not apply/, err.message)
    end

    test "no diff in the text is an error" do
      assert_raises(PatchApplyService::Error) { apply("just prose") }
    end

    test "oversized patch is refused" do
      assert_raises(PatchApplyService::Error) { apply("x" * (PatchApplyService::MAX_PATCH_BYTES + 1)) }
    end

    test "workspace below the repository root resolves paths relative to it" do
      sub = File.join(@dir, "sub")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, "x.txt"), "a\nb\n")
      patch = "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n"
      result = PatchApplyService.new(sub).call(patch, check: false)

      assert_equal "x.txt", result[:files].first[:path]
      assert_equal "a\nB\n", File.read(File.join(sub, "x.txt"))
    end

    test "works outside any git repository" do
      Dir.mktmpdir("mbeditor_norepo_") do |plain|
        File.write(File.join(plain, "a.txt"), "one\ntwo\nthree\n")
        PatchApplyService.new(plain).call(MODIFY, check: false)

        assert_equal "one\nTWO\nthree\n", File.read(File.join(plain, "a.txt"))
      end
    end

    test "refuses a patch that creates a symlink" do
      ["new file mode 120000", "new mode 120000"].each do |line|
        patch = "diff --git a/ln b/ln\n#{line}\n--- /dev/null\n+++ b/ln\n@@ -0,0 +1 @@\n+/etc/passwd\n"
        err = assert_raises(PatchApplyService::Error, line) { apply(patch) }

        assert_match(/symbolic link/, err.message)
      end
      refute File.symlink?(File.join(@dir, "ln"))
    end

    test "blocked paths are refused on check and apply, naming the path" do
      patch = "diff --git a/tmp/x.txt b/tmp/x.txt\nnew file mode 100644\n--- /dev/null\n+++ b/tmp/x.txt\n@@ -0,0 +1 @@\n+x\n"
      [true, false].each do |check|
        err = assert_raises(PatchApplyService::Error) do
          PatchApplyService.new(@dir).call(patch, check: check, blocked: ->(rel) { rel.start_with?("tmp/") })
        end

        assert_includes err.message, "tmp/x.txt"
      end
      refute File.exist?(File.join(@dir, "tmp"))
    end

    test "every fenced diff block in a reply is applied" do
      File.write(File.join(@dir, "b.txt"), "x\n")
      reply = "First:\n```diff\n#{MODIFY}```\nand then\n```diff\n" \
              "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n```\nDone.\n"
      result = apply(reply)

      assert_equal %w[a.txt b.txt], result[:files].map { |f| f[:path] }
      assert_equal "one\nTWO\nthree\n", read("a.txt")
      assert_equal "y\n", read("b.txt")
    end

    test "a CRLF mismatch fails with a hint and writes nothing" do
      File.binwrite(File.join(@dir, "a.txt"), "one\r\ntwo\r\nthree\r\n")
      err = assert_raises(PatchApplyService::Error) { apply(MODIFY) }

      assert_match(/does not apply/, err.message)
      assert_match(/line endings or trailing newline differ/, err.message)
      assert_equal "one\r\ntwo\r\nthree\r\n", File.binread(File.join(@dir, "a.txt"))
    end

    test "a genuine mismatch gets no whitespace hint" do
      err = assert_raises(PatchApplyService::Error) { apply(MODIFY.sub("-two", "-nope")) }

      refute_match(/line endings/, err.message)
    end

    test "a headerless two-file patch applies when --recount would misread it" do
      File.write(File.join(@dir, "b.txt"), "x\n")
      patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n" \
              "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n"
      apply(patch)

      assert_equal "one\nTWO\nthree\n", read("a.txt")
      assert_equal "y\n", read("b.txt")
    end

    test "a content line starting with -- does not break the patch under recount" do
      File.write(File.join(@dir, "m.md"), "x\n-- y\nz\n")
      patch = "diff --git a/m.md b/m.md\n--- a/m.md\n+++ b/m.md\n@@ -1,3 +1,3 @@\n x\n--- y\n+++ w\n z\n"
      apply(patch)

      assert_equal "x\n++ w\nz\n", read("m.md")
    end

    test "non-ASCII created paths come back unquoted with their created status" do
      patch = "diff --git a/café.txt b/café.txt\nnew file mode 100644\n--- /dev/null\n+++ b/café.txt\n@@ -0,0 +1 @@\n+x\n"
      result = apply(patch, check: true)

      assert_equal [["café.txt", :created]], result[:files].map { |f| [f[:path], f[:status]] }
    end
  end
end
