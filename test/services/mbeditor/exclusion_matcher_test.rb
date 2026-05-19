# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ExclusionMatcherTest < ActiveSupport::TestCase
    def matcher(*patterns)
      ExclusionMatcher.new(patterns)
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
  end
end
