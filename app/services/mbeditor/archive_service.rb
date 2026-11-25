# frozen_string_literal: true

require "rubygems/package"
require "stringio"
require "zlib"

module Mbeditor
  # Bundles a selection of workspace files and directories into one .tar.gz,
  # for the explorer's multi-select download.
  #
  # tar.gz rather than zip because Gem::Package::TarWriter and Zlib ship with
  # Ruby; a zip writer would mean adding rubyzip to a gemspec that declares
  # only rails and sprockets-rails.
  #
  # Callers pass paths that have already been through resolve_path. The walk
  # re-checks every entry it discovers anyway — see #collect.
  class ArchiveService
    # Same caps as #import (EditorsController::IMPORT_MAX_FILES /
    # IMPORT_MAX_TOTAL_BYTES). Deliberately a refusal, not a truncation: an
    # archive that is silently short looks complete when it is opened.
    MAX_FILES = 100
    MAX_TOTAL_BYTES = 50 * 1024 * 1024

    class LimitExceededError < StandardError; end

    # A message safe to show: names the workspace-relative path and never the
    # absolute one that Errno messages carry.
    class Error < StandardError; end

    def self.read_error(rel, err)
      Error.new("Cannot read #{rel}: #{SystemCallError.new(nil, err.errno).message}")
    end

    def initialize(workspace_root)
      @root = workspace_root.to_s.chomp("/")
      # Named paths are checked against the real root: a symlinked ancestor
      # (macOS /tmp, a linked-in directory) makes lexical comparison unreliable.
      @real_root = begin
        File.realpath(@root)
      rescue SystemCallError
        @root
      end
      @matcher = ExclusionMatcher.new(Mbeditor.configuration.excluded_paths, root: @root)
    end

    # +full_paths+ are absolute paths inside the workspace. Returns the
    # .tar.gz bytes; 50 MB compresses fine in memory, so there is no streaming
    # response to keep alive.
    def build(full_paths)
      entries = collect(full_paths)
      raise "Nothing to archive" if entries.empty?

      if entries.length > MAX_FILES
        raise LimitExceededError, "Too many files (#{entries.length}). Limit is #{MAX_FILES}."
      end

      total = entries.sum { |e| e[:size] }
      if total > MAX_TOTAL_BYTES
        raise LimitExceededError,
              "Selection is too large (#{human(total)}). Limit is #{human(MAX_TOTAL_BYTES)}."
      end

      write(entries)
    end

    # Breadth-first walk of the selection, yielding regular files only. Public
    # so AiBundleService reuses the containment, exclusion and symlink rules.
    def collect(full_paths)
      entries = []
      seen_dirs = {}
      # A named path inside a symlinked directory passes the lexical check and
      # lstat only inspects the leaf, so the real location is compared too. Only
      # named paths need it: the walk never descends into a symlink.
      queue = full_paths.select { |p| real_inside?(p) }
      path = nil

      until queue.empty?
        path = queue.shift
        # Containment is re-checked on every entry the walk discovers, not just
        # on the paths the request named. A directory being inside the
        # workspace says nothing about what turns up underneath it, and this is
        # the only check standing between a name on disk and bytes in a file
        # the user downloads.
        next unless contained?(path)

        rel = relative(path)
        next if rel.start_with?("/") || rel.split("/").include?("..")
        next if !rel.empty? && @matcher.excluded?(rel)

        st = safe_lstat(path)
        next if st.nil?

        # Symlinks are skipped, which is deliberately stricter than
        # ApplicationController#resolve_path, which follows them. That policy
        # is about opening the one file a developer named and put in the tree.
        # A recursive walk is a different question: following a link here would
        # copy bytes from outside the workspace into a file the user
        # downloads, and a link back up the tree loops forever. Neither is
        # something the developer asked for by selecting a folder.
        next if st.symlink?

        if st.directory?
          # Cycle guard even so — the symlink skip already rules out the usual
          # loop, but a bind mount or a hard-linked directory does not need one.
          key = [st.dev, st.ino]
          next if seen_dirs.key?(key)

          seen_dirs[key] = true
          queue.concat(Dir.children(path).sort.map { |name| File.join(path, name) })
        elsif st.file?
          entries << { path: path, name: rel, mode: st.mode & 0o777, size: st.size }
        end
      end

      entries
    rescue SystemCallError => e
      raise self.class.read_error(path ? relative(path) : "", e)
    end

    private

    def real_inside?(path)
      real = File.realpath(File.symlink?(path) ? File.dirname(path) : path)
      real == @real_root || real.start_with?("#{@real_root}/")
    rescue SystemCallError
      false
    end

    def write(entries)
      buffer = StringIO.new(+"".b)
      Zlib::GzipWriter.wrap(buffer) do |gz|
        Gem::Package::TarWriter.new(gz) do |tar|
          entries.each do |entry|
            # Read first, then declare the size from the bytes in hand:
            # TarWriter bounds the entry to the size it was given, so a file
            # that changed since it was stat-ed would otherwise write a short
            # or over-long member.
            data = begin
              File.binread(entry[:path])
            rescue SystemCallError => e
              raise self.class.read_error(entry[:name], e)
            end
            begin
              tar.add_file_simple(entry[:name], entry[:mode], data.bytesize) { |io| io.write(data) }
            rescue Gem::Package::TooLongFileName
              raise Error, "Path is too long for a tar archive (#{entry[:name].bytesize} bytes, limit 256): #{entry[:name]}"
            end
          end
        end
      end
      buffer.string
    end

    def contained?(path)
      full = File.expand_path(path)
      full == @root || full.start_with?("#{@root}/")
    end

    def relative(path)
      path == @root ? "" : path.delete_prefix("#{@root}/")
    end

    # A file can vanish between listing its directory and stat-ing it.
    def safe_lstat(path)
      File.lstat(path)
    rescue Errno::ENOENT
      nil
    end

    def human(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end
  end
end
