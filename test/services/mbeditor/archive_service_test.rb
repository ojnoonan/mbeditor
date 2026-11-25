# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class ArchiveServiceTest < ActiveSupport::TestCase
    def setup
      @dir = Dir.mktmpdir("mbeditor_archive_")
      @outside = Dir.mktmpdir("mbeditor_outside_")
      Mbeditor.configuration.excluded_paths = %w[.git tmp]
    end

    def teardown
      FileUtils.rm_rf(@dir)
      FileUtils.rm_rf(@outside)
      Mbeditor.configuration.excluded_paths = Configuration.new.excluded_paths
    end

    def service
      ArchiveService.new(@dir)
    end

    test "a named path inside a symlinked directory pointing outside is refused" do
      File.write(File.join(@outside, "secret.txt"), "TOPSECRET\n")
      File.symlink(@outside, File.join(@dir, "linkdir"))

      assert_empty service.collect([File.join(@dir, "linkdir", "secret.txt")])
    end

    test "a named path inside a symlinked directory that stays inside is kept" do
      FileUtils.mkdir_p(File.join(@dir, "real"))
      File.write(File.join(@dir, "real", "a.txt"), "x\n")
      File.symlink(File.join(@dir, "real"), File.join(@dir, "alias"))

      assert_equal ["alias/a.txt"], service.collect([File.join(@dir, "alias", "a.txt")]).map { |e| e[:name] }
    end

    test "an unreadable file raises with the relative name, never the absolute path" do
      skip "root can read anything" if Process.uid.zero?
      full = File.join(@dir, "locked.txt")
      File.write(full, "x")
      File.chmod(0, full)
      err = assert_raises(ArchiveService::Error) { service.build([full]) }

      assert_includes err.message, "locked.txt"
      refute_includes err.message, @dir
    ensure
      File.chmod(0o644, full) if full
    end

    test "a name over the tar limit raises naming the relative path" do
      rel = File.join(*(["d" * 40] * 7), "f.txt")
      FileUtils.mkdir_p(File.join(@dir, File.dirname(rel)))
      File.write(File.join(@dir, rel), "x")
      err = assert_raises(ArchiveService::Error) { service.build([@dir]) }

      assert_includes err.message, rel
      refute_includes err.message, @dir
    end
  end
end
