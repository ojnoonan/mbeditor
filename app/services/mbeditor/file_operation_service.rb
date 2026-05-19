# frozen_string_literal: true

require "pathname"

module Mbeditor
  class FileOperationService
    MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024

    class FileTooLargeError  < StandardError; end
    class FileExistsError    < StandardError; end
    class PathNotFoundError  < StandardError; end
    class TargetExistsError  < StandardError; end

    def initialize(workspace_root)
      @workspace_root = Pathname(workspace_root)
    end

    def save(path, content)
      raise FileTooLargeError if content.bytesize > MAX_FILE_SIZE_BYTES

      File.write(path, content)
      { ok: true, path: relative_path(path) }
    end

    def destroy_path(path)
      return { ok: true } unless File.exist?(path)

      if File.directory?(path)
        FileUtils.rm_rf(path)
        { ok: true, type: "folder", path: relative_path(path) }
      else
        File.delete(path)
        { ok: true, type: "file", path: relative_path(path) }
      end
    end

    def rename(old_path, new_path)
      raise PathNotFoundError unless File.exist?(old_path)
      raise TargetExistsError if File.exist?(new_path)

      FileUtils.mkdir_p(File.dirname(new_path))
      FileUtils.mv(old_path, new_path)
      { ok: true, oldPath: relative_path(old_path), path: relative_path(new_path), name: File.basename(new_path) }
    end

    def create_dir(path)
      raise FileExistsError if File.exist?(path)

      FileUtils.mkdir_p(path)
      { ok: true, type: "folder", path: relative_path(path), name: File.basename(path) }
    end

    def create_file(path, content)
      raise FileTooLargeError if content.bytesize > MAX_FILE_SIZE_BYTES
      raise FileExistsError if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      { ok: true, type: "file", path: relative_path(path), name: File.basename(path) }
    end

    private

    def relative_path(path)
      Pathname(path).relative_path_from(@workspace_root).to_s
    end
  end
end
