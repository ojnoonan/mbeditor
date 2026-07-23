# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class SafePathTest < ActiveSupport::TestCase
    def setup
      @root = Dir.mktmpdir("mbeditor_safe_path_")
      @real_root = File.realpath(@root)
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    def within?(relative)
      SafePath.within?(@root, File.join(@root, relative))
    end

    test "accepts an existing file inside the root" do
      File.write(File.join(@root, "a.rb"), "x")
      assert within?("a.rb")
    end

    test "accepts a path that does not exist yet inside the root" do
      assert within?("not_created_yet.rb")
    end

    test "accepts a path several missing directories deep" do
      assert within?("lib/tasks/deep/new.rake")
    end

    test "accepts the root itself" do
      assert SafePath.within?(@root, @root)
    end

    test "rejects a live symlink whose target is outside the root" do
      outside = Tempfile.new("mbeditor_outside_")
      File.symlink(outside.path, File.join(@root, "live_link"))
      refute within?("live_link")
    ensure
      outside&.close!
    end

    test "rejects a dangling symlink whose target is outside the root" do
      File.symlink(File.join(Dir.tmpdir, "mbeditor_nonexistent_target"), File.join(@root, "dangling"))
      refute within?("dangling")
    end

    test "rejects a path under a dangling symlink pointing outside the root" do
      File.symlink(File.join(Dir.tmpdir, "mbeditor_nonexistent_dir"), File.join(@root, "dangling_dir"))
      refute within?("dangling_dir/child.rb")
    end

    test "rejects a chain of dangling symlinks ending outside the root" do
      File.symlink(File.join(@root, "hop2"), File.join(@root, "hop1"))
      File.symlink(File.join(Dir.tmpdir, "mbeditor_nonexistent_chain"), File.join(@root, "hop2"))
      refute within?("hop1")
    end

    test "accepts a dangling symlink whose target is inside the root" do
      File.symlink(File.join(@root, "target_to_be.rb"), File.join(@root, "inside_link"))
      assert within?("inside_link")
    end

    test "accepts a relative dangling symlink resolving inside the root" do
      FileUtils.mkdir_p(File.join(@root, "nested"))
      File.symlink("../sibling.rb", File.join(@root, "nested", "rel_link"))
      assert within?("nested/rel_link")
    end

    test "rejects a relative dangling symlink escaping the root" do
      FileUtils.mkdir_p(File.join(@root, "nested"))
      File.symlink("../../escaped.rb", File.join(@root, "nested", "rel_link"))
      refute within?("nested/rel_link")
    end

    test "rejects a symlink loop rather than hanging" do
      File.symlink(File.join(@root, "loop_b"), File.join(@root, "loop_a"))
      File.symlink(File.join(@root, "loop_a"), File.join(@root, "loop_b"))
      refute within?("loop_a")
    end
  end
end
