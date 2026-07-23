# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ExclusionMatcherTest < ActiveSupport::TestCase
    # The real repo checkout — the probe has to run against the volume the
    # workspace actually lives on, not a synthetic path.
    REPO_ROOT = File.expand_path("../../..", __dir__)

    def matcher(*patterns)
      ExclusionMatcher.new(patterns, root: REPO_ROOT)
    end

    # -------------------------------------------------------------------------
    # Non-slash pattern — basename match
    # -------------------------------------------------------------------------

    test "non-slash pattern matches basename directly" do
      assert matcher("tmp").excluded?("tmp")
    end

    # -------------------------------------------------------------------------
    # Blank patterns
    # -------------------------------------------------------------------------

    test "blank patterns are ignored and do not match everything" do
      refute matcher("").excluded?("any/path.rb")
      refute matcher("", " ").excluded?("any/path.rb")
    end

    # -------------------------------------------------------------------------
    # Non-slash pattern — component at depth
    # -------------------------------------------------------------------------

    test "non-slash pattern matches a component at any depth" do
      assert matcher("tmp").excluded?("a/b/tmp/c/file.rb")
    end

    test "non-slash pattern does not match a partial component name" do
      refute matcher("tmp").excluded?("a/tmpfile.rb")
    end

    # -------------------------------------------------------------------------
    # Slash pattern — exact and prefix match
    # -------------------------------------------------------------------------

    test "slash pattern matches an exact relative path" do
      assert matcher("public/assets").excluded?("public/assets")
    end

    test "slash pattern matches a file under the prefix" do
      assert matcher("public/assets").excluded?("public/assets/app.js")
    end

    test "slash pattern does not match a path sharing the string but not as a directory prefix" do
      refute matcher("public/assets").excluded?("public/assets_extra/file.js")
    end

    # -------------------------------------------------------------------------
    # Unrecognized path
    # -------------------------------------------------------------------------

    test "returns false for a path that matches no pattern" do
      refute matcher("tmp", "log").excluded?("app/models/user.rb")
    end

    # -------------------------------------------------------------------------
    # Case folding — only on a filesystem that actually folds case.
    #
    # These assertions are gated on a runtime probe rather than on the platform
    # name: a case-sensitive volume can be mounted on macOS, and CI runs on
    # Linux, where the same path spellings are genuinely distinct files.
    # -------------------------------------------------------------------------

    def case_insensitive_fs?
      ExclusionMatcher.case_insensitive_filesystem?(REPO_ROOT)
    end

    test "case variant of a non-slash pattern is excluded on a case-insensitive filesystem" do
      skip "filesystem backing the workspace is case-sensitive" unless case_insensitive_fs?

      assert matcher("tmp").excluded?("TMP/cache.txt")
      assert matcher("tmp").excluded?("a/b/Tmp/c/file.rb")
    end

    test "case variant of .git is excluded on a case-insensitive filesystem" do
      skip "filesystem backing the workspace is case-sensitive" unless case_insensitive_fs?

      assert matcher(".git").excluded?(".GIT/hooks/post-checkout")
      assert matcher(".git").excluded?(".Git/hooks/post-checkout")
    end

    test "case variant of a slash pattern is excluded on a case-insensitive filesystem" do
      skip "filesystem backing the workspace is case-sensitive" unless case_insensitive_fs?

      assert matcher("public/assets").excluded?("Public/Assets")
      assert matcher("public/assets").excluded?("PUBLIC/assets/app.js")
    end

    test "case variants are left alone on a case-sensitive filesystem" do
      skip "filesystem backing the workspace is case-insensitive" if case_insensitive_fs?

      refute matcher("tmp").excluded?("TMP/cache.txt")
      refute matcher(".git").excluded?(".GIT/hooks/post-checkout")
    end

    test "case folding does not widen a partial component match" do
      refute matcher("tmp").excluded?("a/TMPfile.rb")
      refute matcher("public/assets").excluded?("Public/Assets_extra/file.js")
    end

    test "case_insensitive_filesystem? answers with a boolean and tolerates a missing root" do
      assert_includes [true, false], ExclusionMatcher.case_insensitive_filesystem?(REPO_ROOT)
      assert ExclusionMatcher.case_insensitive_filesystem?(File.join(REPO_ROOT, "no_such_dir_#{Process.pid}"))
    end

    # -------------------------------------------------------------------------
    # Unicode normalization — unconditional, on every filesystem.
    #
    # APFS stores one file for the NFC and NFD spellings of a name, so a byte
    # comparison lets an NFD request path reach an NFC-excluded directory.
    # Folding both to NFC everywhere costs only over-exclusion on filesystems
    # that do keep the two spellings apart.
    # -------------------------------------------------------------------------

    NFC_CAFE = "caf\u00E9"    # precomposed U+00E9
    NFD_CAFE = "cafe\u0301"   # e + combining acute U+0301

    test "NFD path is excluded by an NFC pattern" do
      assert matcher(NFC_CAFE).excluded?(NFD_CAFE)
      assert matcher(NFC_CAFE).excluded?("#{NFD_CAFE}/secret.txt")
      assert matcher("a/#{NFC_CAFE}").excluded?("a/#{NFD_CAFE}/secret.txt")
    end

    test "NFC path is excluded by an NFD pattern" do
      assert matcher(NFD_CAFE).excluded?(NFC_CAFE)
      assert matcher(NFD_CAFE).excluded?("#{NFC_CAFE}/secret.txt")
      assert matcher("a/#{NFD_CAFE}").excluded?("a/#{NFC_CAFE}/secret.txt")
    end

    test "normalization does not make unrelated non-ASCII paths match" do
      refute matcher(NFC_CAFE).excluded?("cafe/secret.txt")
      refute matcher(NFC_CAFE).excluded?("caf\u00E8/secret.txt") # U+00E8, a different letter
    end

    test "invalid UTF-8 in a path does not raise and does not bypass an exclusion" do
      invalid = "tmp/\xFF.txt".dup.force_encoding(Encoding::UTF_8)
      assert matcher("tmp").excluded?(invalid)
      refute matcher("log").excluded?(invalid)
    end
  end
end
