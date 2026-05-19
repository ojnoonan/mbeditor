# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class FileOperationServiceTest < ActiveSupport::TestCase
    test "save writes content and returns ok with relative path" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "hello.txt")
        result = service.save(path, "hello world")
        assert_equal({ ok: true, path: "hello.txt" }, result)
        assert_equal "hello world", File.read(path)
      end
    end

    test "save raises FileTooLargeError when content exceeds MAX_FILE_SIZE_BYTES" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "big.txt")
        big_content = "x" * (FileOperationService::MAX_FILE_SIZE_BYTES + 1)
        assert_raises(FileOperationService::FileTooLargeError) do
          service.save(path, big_content)
        end
        refute File.exist?(path)
      end
    end

    # destroy_path
    test "destroy_path is idempotent when path does not exist" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        result = service.destroy_path(File.join(dir, "ghost.rb"))
        assert_equal({ ok: true }, result)
      end
    end

    test "destroy_path deletes a file and returns type and path" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "bye.rb")
        File.write(path, "")
        result = service.destroy_path(path)
        assert_equal({ ok: true, type: "file", path: "bye.rb" }, result)
        refute File.exist?(path)
      end
    end

    test "destroy_path deletes a directory and returns type and path" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "bye_dir")
        FileUtils.mkdir_p(path)
        result = service.destroy_path(path)
        assert_equal({ ok: true, type: "folder", path: "bye_dir" }, result)
        refute File.exist?(path)
      end
    end

    # rename
    test "rename raises PathNotFoundError when source does not exist" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        assert_raises(FileOperationService::PathNotFoundError) do
          service.rename(File.join(dir, "ghost.rb"), File.join(dir, "dest.rb"))
        end
      end
    end

    test "rename raises TargetExistsError when destination already exists" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        old_path = File.join(dir, "old.rb")
        new_path = File.join(dir, "new.rb")
        File.write(old_path, "a")
        File.write(new_path, "b")
        assert_raises(FileOperationService::TargetExistsError) do
          service.rename(old_path, new_path)
        end
        assert File.exist?(old_path)
      end
    end

    test "rename moves file and returns ok hash with old and new paths" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        old_path = File.join(dir, "old.rb")
        new_path = File.join(dir, "sub", "new.rb")
        File.write(old_path, "content")
        result = service.rename(old_path, new_path)
        assert_equal({ ok: true, oldPath: "old.rb", path: "sub/new.rb", name: "new.rb" }, result)
        refute File.exist?(old_path)
        assert_equal "content", File.read(new_path)
      end
    end

    # create_dir
    test "create_dir raises FileExistsError when path already exists" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "existing_dir")
        FileUtils.mkdir_p(path)
        assert_raises(FileOperationService::FileExistsError) { service.create_dir(path) }
      end
    end

    test "create_dir creates directory and returns ok hash" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "app", "models")
        result = service.create_dir(path)
        assert_equal({ ok: true, type: "folder", path: "app/models", name: "models" }, result)
        assert File.directory?(path)
      end
    end

    # create_file
    test "create_file raises FileTooLargeError when content exceeds cap" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "big.rb")
        big = "x" * (FileOperationService::MAX_FILE_SIZE_BYTES + 1)
        assert_raises(FileOperationService::FileTooLargeError) { service.create_file(path, big) }
        refute File.exist?(path)
      end
    end

    test "create_file raises FileExistsError when path already exists" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "existing.rb")
        File.write(path, "old")
        assert_raises(FileOperationService::FileExistsError) { service.create_file(path, "new") }
        assert_equal "old", File.read(path)
      end
    end

    test "create_file writes content, creates parent dirs, returns ok hash" do
      Dir.mktmpdir do |dir|
        service = FileOperationService.new(dir)
        path = File.join(dir, "sub", "new.rb")
        result = service.create_file(path, "puts 'hi'")
        assert_equal({ ok: true, type: "file", path: "sub/new.rb", name: "new.rb" }, result)
        assert_equal "puts 'hi'", File.read(path)
      end
    end
  end
end
