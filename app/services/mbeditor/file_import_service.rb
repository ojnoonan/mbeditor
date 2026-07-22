# frozen_string_literal: true

require "fileutils"
require "pathname"

module Mbeditor
  # Writes files dragged into the explorer from outside the browser.
  #
  # Conflict handling is a two-pass protocol driven by the client. Pass one
  # runs with on_conflict: :ask — every entry whose target is free is written,
  # and the rest come back under :conflicts untouched. The client resolves
  # them and re-sends just those entries with :overwrite or :rename. Because
  # the existence check and the write happen inside the same call, the window
  # is closed at the protocol level: the client never gets to check in one
  # round trip and write in another. (File.exist? and File.open are still two
  # syscalls, so this is not an atomic guarantee against other processes.)
  #
  # Callers must hand over target paths that have already cleared the
  # controller's resolve_path / path_blocked_for_operations? guards; this
  # service does no sandboxing of its own.
  class FileImportService
    MAX_FILE_SIZE_BYTES = FileOperationService::MAX_FILE_SIZE_BYTES
    CONFLICT_MODES = %i[ask overwrite rename].freeze

    def initialize(workspace_root)
      @workspace_root = Pathname(workspace_root)
    end

    # entries: [{ target_path: <absolute String>, io: <#read, #rewind> }]
    # => { imported: [{path:, name:}], conflicts: [{path:}], errors: [{path:, error:}] }
    def import(entries, on_conflict: :ask)
      mode = on_conflict.to_s.to_sym
      raise ArgumentError, "unknown on_conflict: #{on_conflict.inspect}" unless CONFLICT_MODES.include?(mode)

      result = { imported: [], conflicts: [], errors: [] }
      Array(entries).each { |entry| import_entry(entry, mode, result) }
      result
    end

    private

    def import_entry(entry, mode, result)
      target = entry[:target_path].to_s
      io     = entry[:io]

      if File.exist?(target)
        case mode
        when :ask
          return result[:conflicts] << { path: relative_path(target) }
        when :rename
          target = free_path(target)
        end
      end

      write(target, io)
      result[:imported] << { path: relative_path(target), name: File.basename(target) }
    end

    def write(target, io)
      FileUtils.mkdir_p(File.dirname(target))
      io.rewind
      File.open(target, "wb") { |f| IO.copy_stream(io, f) }
    end

    # "logo.png" -> "logo 2.png" -> "logo 3.png" ...
    def free_path(target)
      dir  = File.dirname(target)
      ext  = File.extname(target)
      base = File.basename(target, ext)
      counter = 2
      counter += 1 while File.exist?(File.join(dir, "#{base} #{counter}#{ext}"))
      File.join(dir, "#{base} #{counter}#{ext}")
    end

    def relative_path(path)
      Pathname(path).relative_path_from(@workspace_root).to_s
    rescue ArgumentError
      path
    end
  end
end
