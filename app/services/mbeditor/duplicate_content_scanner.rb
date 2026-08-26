# frozen_string_literal: true

require "find"

module Mbeditor
  # Finds files that look like they were written back to disk with their own
  # content appended to themselves.
  #
  # The corruption this detects came from the collaborative buffer: two clients
  # that each found an empty shared document seeded it from disk, and Yjs merged
  # both inserts at offset 0 into two concatenated copies. That bug is fixed
  # (CollaborationDocStore.claim_seed), but files saved while it was live are
  # still on disk, so there has to be a way to find them.
  #
  # Two signals, cheapest first:
  #
  #   * :exact          — the file is byte-for-byte X + X. What a duplicated save
  #                       produces before anyone edits it again.
  #   * :repeated_block — the first ANCHOR_LINES lines of the file occur again
  #                       later, verbatim. Survives edits made after the
  #                       corruption, which is the common case for a file noticed
  #                       days later.
  #
  # Report-only. Nothing here writes.
  class DuplicateContentScanner
    ANCHOR_LINES  = 10
    MIN_LINES     = 20 # below this, a repeat is unremarkable
    MAX_FILE_SIZE = 5 * 1024 * 1024

    Finding = Struct.new(:path, :reason, :line, :lines, keyword_init: true)

    def self.check(content)
      return nil if content.nil? || content.empty?

      lines = content.lines
      return nil if lines.size < MIN_LINES

      half = content.bytesize / 2
      if content.bytesize.even? && content.byteslice(0, half) == content.byteslice(half, half)
        return { reason: :exact, line: (lines.size / 2) + 1 }
      end

      at = repeated_anchor_line(lines)
      at ? { reason: :repeated_block, line: at } : nil
    end

    # Line number (1-based) of a later verbatim recurrence of the file's opening
    # block, or nil. The anchor starts at the first non-blank line so a leading
    # blank does not shift it out of alignment with its copy.
    def self.repeated_anchor_line(lines)
      start = lines.index { |l| !l.strip.empty? }
      return nil if start.nil? || (start + ANCHOR_LINES) > lines.size

      anchor = lines[start, ANCHOR_LINES]
      # A block of identical lines (padding, a long table) repeats for boring
      # reasons; require the anchor itself to carry some variety.
      return nil if anchor.uniq.size < 3

      idx = ((start + 1)..(lines.size - ANCHOR_LINES)).find { |i| lines[i, ANCHOR_LINES] == anchor }
      idx && (idx + 1)
    end
    private_class_method :repeated_anchor_line

    def initialize(root, excluded: Mbeditor.configuration.excluded_paths)
      @root = File.expand_path(root.to_s)
      @matcher = ExclusionMatcher.new(excluded, root: @root)
    end

    def call
      findings = []
      Find.find(@root) do |path|
        rel = path == @root ? "" : path.delete_prefix("#{@root}/")
        if File.directory?(path)
          Find.prune if !rel.empty? && @matcher.excluded?(rel)
          next
        end
        next if @matcher.excluded?(rel)
        next unless File.file?(path) && File.size(path).between?(1, MAX_FILE_SIZE)

        content = read_text(path)
        next unless content

        hit = self.class.check(content)
        next unless hit

        findings << Finding.new(path: rel, reason: hit[:reason], line: hit[:line], lines: content.lines.size)
      end
      findings.sort_by { |f| [f.reason == :exact ? 0 : 1, f.path] }
    end

    private

    # nil for anything that is not readable UTF-8 text — a NUL byte is the same
    # binary test the rest of the editor uses.
    def read_text(path)
      content = File.read(path, encoding: "UTF-8")
      return nil unless content.valid_encoding?
      return nil if content.include?("\0")

      content
    rescue SystemCallError
      nil
    end
  end
end
