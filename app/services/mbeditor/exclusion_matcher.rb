# frozen_string_literal: true

module Mbeditor
  # Decides whether a workspace-relative path falls under a configured
  # exclusion (`Mbeditor.configuration.excluded_paths`).
  #
  # Comparison is normalized rather than byte-for-byte, because the filesystem
  # the workspace lives on may resolve two different spellings of a name to the
  # same file:
  #
  #   * Case. APFS/HFS+ (and NTFS) resolve "TMP/cache.txt" to the excluded
  #     "tmp/", and ".GIT/hooks/post-checkout" to the real ".git/hooks/" — the
  #     latter is arbitrary code execution on the next git operation. Folding is
  #     applied only when the filesystem backing the workspace really is
  #     case-insensitive, probed at runtime: a case-sensitive volume can be
  #     mounted on macOS, and folding there would hide legitimately distinct
  #     paths.
  #
  #   * Unicode normalization. APFS stores one file for the NFC and NFD
  #     spellings of a name, so an NFD request path slips past an NFC pattern.
  #     NFC folding is applied unconditionally: filesystems that do keep the two
  #     spellings apart are rare enough, and the cost there is over-exclusion
  #     (hiding a path) rather than the write-through this class exists to
  #     prevent.
  class ExclusionMatcher
    MUTEX = Mutex.new
    private_constant :MUTEX

    # Roots are stable for the life of a process; the bound only keeps the test
    # suite (a fresh tmpdir workspace per test) from growing the memo forever.
    MAX_PROBE_CACHE = 256
    private_constant :MAX_PROBE_CACHE

    class << self
      # Whether the filesystem backing +root+ resolves paths case-insensitively.
      # Probed once per root, then memoized for the life of the process.
      def case_insensitive_filesystem?(root)
        key = File.expand_path(root.to_s)

        MUTEX.synchronize do
          @probe_cache ||= {}
          return @probe_cache[key] if @probe_cache.key?(key)

          @probe_cache = {} if @probe_cache.size >= MAX_PROBE_CACHE
          @probe_cache[key] = probe_case_insensitive(key)
        end
      end

      def reset_filesystem_probe!
        MUTEX.synchronize { @probe_cache = {} }
      end

      private

      # Asks the filesystem directly: look up a real directory under its own
      # name and under that name with the case flipped, and compare device +
      # inode (that is what File.identical? does). They only agree when the
      # filesystem folded the two spellings onto one directory.
      #
      # Climbs to the nearest ancestor whose name actually contains a cased
      # character, since a name like "42" flips to itself and proves nothing.
      # When nothing can be determined — no cased ancestor, a root that does not
      # exist, a permission error — it reports case-insensitive, which
      # over-excludes rather than leaving the hole open.
      def probe_case_insensitive(root)
        return true unless File.directory?(root)

        path = root
        loop do
          parent  = File.dirname(path)
          base    = File.basename(path)
          flipped = base.swapcase

          return File.identical?(path, File.join(parent, flipped)) unless flipped == base
          break if parent == path

          path = parent
        end

        true
      rescue SystemCallError
        true
      end
    end

    # +root+ is the workspace the paths are relative to; it decides only whether
    # case is folded. Defaults to the resolved workspace root.
    def initialize(patterns, root: nil)
      @fold_case = self.class.case_insensitive_filesystem?(root || WorkspaceRootResolver.call)
      normalized = patterns.map { |pattern| normalize(pattern.to_s) }.reject(&:empty?)
      # Split by shape once: a path pattern is compared against the whole
      # relative path, a bare name against its segments. This runs per file of
      # a workspace walk, so neither the split nor the basename belongs in the
      # per-pattern loop.
      @path_patterns, @name_patterns = normalized.partition { |pattern| pattern.include?("/") }
    end

    def excluded?(relative_path)
      rel = normalize(relative_path.to_s)
      return true if @path_patterns.any? { |pattern| rel == pattern || rel.start_with?("#{pattern}/") }
      return false if @name_patterns.empty?

      segments = rel.split("/")
      basename = File.basename(rel)
      @name_patterns.any? { |pattern| basename == pattern || segments.include?(pattern) }
    end

    private

    # "/" is ASCII and survives both steps, so the caller can normalize a whole
    # path in one pass and split it afterwards.
    def normalize(str)
      # ASCII is already NFC, so only the case step can apply.
      return @fold_case ? str.downcase : str if str.ascii_only?

      utf8 = str.encoding == Encoding::UTF_8 ? str : str.dup.force_encoding(Encoding::UTF_8)
      # Undecodable bytes become U+FFFD. This is a comparison key, never a path
      # we open, and scrubbing keeps a malformed name from skipping the fold
      # (and raising) on its way past an exclusion.
      utf8 = utf8.scrub unless utf8.valid_encoding?
      utf8 = utf8.unicode_normalize(:nfc)
      @fold_case ? utf8.downcase : utf8
    rescue ArgumentError, Encoding::CompatibilityError
      str
    end
  end
end
