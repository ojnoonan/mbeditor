# frozen_string_literal: true

require "test_helper"
require "stringio"

module Mbeditor
  class FileImportServiceTest < ActiveSupport::TestCase
    # The service accepts anything that responds to #read and #size, which is
    # what ActionDispatch::Http::UploadedFile gives us in the controller.
    def upload(content)
      StringIO.new(content)
    end

    def entry(dir, rel, content)
      { target_path: File.join(dir, rel), io: upload(content) }
    end

    test "import writes a file and returns it under imported" do
      Dir.mktmpdir do |dir|
        result = FileImportService.new(dir).import([entry(dir, "notes.txt", "hello")])

        assert_equal [{ path: "notes.txt", name: "notes.txt" }], result[:imported]
        assert_empty result[:conflicts]
        assert_empty result[:errors]
        assert_equal "hello", File.read(File.join(dir, "notes.txt"))
      end
    end

    test "import creates intermediate directories for nested targets" do
      Dir.mktmpdir do |dir|
        result = FileImportService.new(dir).import([entry(dir, "assets/img/logo.svg", "<svg/>")])

        assert_equal ["assets/img/logo.svg"], result[:imported].map { |e| e[:path] }
        assert_equal "<svg/>", File.read(File.join(dir, "assets/img/logo.svg"))
      end
    end

    test "import preserves binary content byte for byte" do
      Dir.mktmpdir do |dir|
        bytes = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".dup.force_encoding(Encoding::BINARY)
        FileImportService.new(dir).import([entry(dir, "logo.png", bytes)])

        assert_equal bytes, File.binread(File.join(dir, "logo.png"))
      end
    end

    test "ask mode reports an existing target without touching it" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "notes.txt"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "notes.txt", "replacement")], on_conflict: :ask
        )

        assert_empty result[:imported]
        assert_equal [{ path: "notes.txt" }], result[:conflicts]
        assert_equal "original", File.read(File.join(dir, "notes.txt"))
      end
    end

    test "ask mode writes the free entries in a batch that also conflicts" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "taken.txt"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "taken.txt", "replacement"), entry(dir, "free.txt", "new")],
          on_conflict: :ask
        )

        assert_equal ["free.txt"], result[:imported].map { |e| e[:path] }
        assert_equal ["taken.txt"], result[:conflicts].map { |e| e[:path] }
        assert_equal "original", File.read(File.join(dir, "taken.txt"))
        assert_equal "new", File.read(File.join(dir, "free.txt"))
      end
    end

    test "import rejects an unknown on_conflict mode" do
      Dir.mktmpdir do |dir|
        assert_raises(ArgumentError) do
          FileImportService.new(dir).import([entry(dir, "a.txt", "x")], on_conflict: :clobber)
        end
      end
    end
  end
end
