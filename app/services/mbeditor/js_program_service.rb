# frozen_string_literal: true

module Mbeditor
  # Enumerates the workspace's own JavaScript source and hands it to the editor
  # so Monaco's TypeScript worker can build a real program from it.
  #
  # This is the file-based replacement for declaring every discovered name as
  # ambient `any` (JsGlobalsService). Under Sprockets a JS file with no
  # import/export is a *script*, so its top-level declarations land in the
  # global scope — which is exactly TypeScript's own model for script files.
  # Giving the worker the sources instead of a name list yields real inferred
  # types, member completions, and argument-count checking, and it still
  # reports "Cannot find name" for genuinely unknown identifiers.
  #
  # What it deliberately does NOT solve: UMD-wrapped libraries. React, lodash
  # and axios all assign their global inside a closure
  # (`factory(global.React = {})`), which TypeScript cannot follow statically —
  # loading their source produces no global at all. Those stay on hand-written
  # declarations (the React mini-UMD stub) or on JsGlobalsService's ambient
  # names, which is why that service is still here.
  #
  # No truncation: a workspace that exceeds any limit reports what it skipped
  # and why, rather than silently returning a partial program.
  class JsProgramService
    SOURCE_EXT = /\.(js|jsx|ts|tsx)\z/i

    # Minified bundles cost parse time and yield nothing useful — their globals
    # are one-letter names inside a closure. Matched by convention, then by
    # shape for bundles whose filename doesn't say so.
    MINIFIED_NAME = /[.\-]min\.(js|jsx|ts|tsx)\z/i
    MAX_LINE_LENGTH = 2_000

    # A single source file this large is a bundle or generated output, not
    # something a person edits.
    MAX_FILE_BYTES = 1024 * 1024

    CACHE_TTL = 10 # seconds

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def call(workspace_root)
        root = File.expand_path(workspace_root.to_s)
        now  = monotonic
        MUTEX.synchronize do
          entry = (@cache ||= {})[root]
          return entry[:data] if entry && (now - entry[:ts]) < CACHE_TTL
        end

        data = compute(root)
        MUTEX.synchronize { (@cache ||= {})[root] = { ts: monotonic, data: data } }
        data
      end

      # Content for a single workspace-relative path, for incremental refresh
      # after a file changes. Returns nil when the path isn't program material.
      def file(workspace_root, relative_path)
        root = File.expand_path(workspace_root.to_s)
        rel  = relative_path.to_s.delete_prefix("/")
        return nil unless rel.match?(SOURCE_EXT)
        return nil if rel.match?(MINIFIED_NAME)
        return nil if matcher(root).excluded?(rel)

        abs = File.expand_path(File.join(root, rel))
        return nil unless abs == File.join(root, rel) # no traversal out of the workspace
        return nil unless File.file?(abs) && !File.symlink?(abs)

        content = read_source(abs)
        content && { path: rel, content: content }
      end

      def invalidate(workspace_root)
        MUTEX.synchronize { (@cache ||= {}).delete(File.expand_path(workspace_root.to_s)) }
      end

      private

      def compute(root)
        return disabled_result unless Mbeditor.configuration.js_program

        files   = []
        skipped = []
        total   = 0

        each_candidate(root) do |rel, abs, stat|
          if stat.size > MAX_FILE_BYTES
            skipped << { path: rel, reason: "larger than #{MAX_FILE_BYTES} bytes" }
            next
          end

          content = read_source(abs)
          if content.nil?
            skipped << { path: rel, reason: "minified or unreadable" }
            next
          end

          total += content.bytesize
          files << { path: rel, content: content }
        end

        {
          ok: true,
          enabled: true,
          generatedAt: Time.now.to_i,
          fileCount: files.length,
          totalBytes: total,
          skipped: skipped,
          files: files.sort_by { |f| f[:path] }
        }
      end

      def disabled_result
        { ok: true, enabled: false, generatedAt: Time.now.to_i,
          fileCount: 0, totalBytes: 0, skipped: [], files: [] }
      end

      # Walks the workspace, pruning excluded directories before descending so
      # a node_modules tree is never entered. Symlinks are skipped outright:
      # this walk is an enumeration, not a resolve_path lookup, and following
      # them could both escape the workspace and loop.
      def each_candidate(root)
        m = matcher(root)
        stack = [root]
        while (dir = stack.pop)
          children(dir).each do |name|
            abs = File.join(dir, name)
            rel = abs.delete_prefix(root).delete_prefix("/")
            next if m.excluded?(rel)

            # One lstat answers symlink?, directory? and size — and lstat is
            # exactly right here, since a symlink must not be followed.
            stat = lstat(abs)
            next if stat.nil? || stat.symlink?

            if stat.directory?
              stack.push(abs)
            elsif name.match?(SOURCE_EXT) && !name.match?(MINIFIED_NAME)
              yield rel, abs, stat
            end
          end
        end
      end

      def children(dir)
        Dir.children(dir)
      rescue SystemCallError
        []
      end

      def lstat(abs)
        File.lstat(abs)
      rescue SystemCallError
        nil
      end

      def matcher(root)
        ExclusionMatcher.new(exclusion_patterns, root: root)
      end

      def exclusion_patterns
        Array(Mbeditor.configuration.excluded_paths).map(&:to_s) +
          Array(Mbeditor.configuration.js_program_exclude).map(&:to_s)
      end

      # Returns nil for anything that isn't usable program source: unreadable,
      # invalid encoding, or minified-by-shape (one very long line).
      def read_source(abs)
        content = File.read(abs, encoding: Encoding::UTF_8)
        return nil unless content.valid_encoding?
        return nil if content.each_line.any? { |line| line.chomp.length > MAX_LINE_LENGTH }

        content
      rescue SystemCallError, IOError
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
