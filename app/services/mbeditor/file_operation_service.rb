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

      atomic_write(path, content)
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
      # A case-only rename on a case-insensitive filesystem (macOS) reports the
      # target as existing because it IS the source.
      same_file = File.identical?(old_path, new_path)
      raise TargetExistsError if File.exist?(new_path) && !same_file

      FileUtils.mkdir_p(File.dirname(new_path))
      # FileUtils.mv refuses a "same file" move, so the case-only rename goes
      # straight to rename(2); everything else keeps mv's cross-device fallback.
      same_file ? File.rename(old_path, new_path) : FileUtils.mv(old_path, new_path)
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

    # Write through a temp file in the same directory and rename over the
    # target: a truncate-then-write loses the file outright if the process dies
    # mid-save. The symlink is resolved first — renaming onto the link itself
    # would replace it with a regular file, and linked-in files are supported.
    def atomic_write(path, content)
      target = link_target(path)
      tmp = File.join(File.dirname(target), ".#{File.basename(target)}.mbeditor-tmp")
      mode = File.stat(target).mode & 0o7777 if File.exist?(target)
      File.write(tmp, content)
      File.chmod(mode, tmp) if mode
      File.rename(tmp, target)
    rescue StandardError
      FileUtils.rm_f(tmp) if tmp
      raise
    end

    def link_target(path)
      return path.to_s unless File.symlink?(path)

      begin
        File.realpath(path)
      rescue SystemCallError
        # realpath refuses a dangling link, but a save through one still has to
        # create the file it names — the same thing File.write did.
        File.expand_path(File.readlink(path), File.dirname(path))
      end
    rescue SystemCallError
      path.to_s
    end

    def relative_path(path)
      Pathname(path).relative_path_from(@workspace_root).to_s
    end
  end
end
