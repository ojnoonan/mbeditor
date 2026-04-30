# frozen_string_literal: true

require "open3"
require "timeout"

module Mbeditor
  # Finds method definitions in a file that have no call-sites anywhere in the
  # workspace.  Uses a single ripgrep (or grep) subprocess with an alternation
  # pattern so cost is O(1) subprocesses regardless of how many methods the
  # file contains.
  #
  # Results are cached per-file; entries are invalidated when the file's mtime
  # changes OR when the entry is older than CACHE_TTL_SECONDS (handles edits
  # to other files that may add or remove call-sites).
  #
  # Usage:
  #   UnusedMethodsService.call(workspace_root, abs_path,
  #                             excluded_dirnames: [], excluded_paths: [])
  #   → [{ name: "my_method", line: 42 }, ...]
  class UnusedMethodsService
    CACHE_TTL_SECONDS = 30
    RG_TIMEOUT        = 10
    GREP_TIMEOUT      = 30

    @cache       = {}
    @cache_mutex = Mutex.new

    class << self
      def call(workspace_root, file_path, excluded_dirnames: [], excluded_paths: [])
        file_path = file_path.to_s

        begin
          mtime = File.mtime(file_path).to_f
        rescue StandardError
          return []
        end

        # Return cached result if file mtime matches and the entry is fresh.
        cached = @cache_mutex.synchronize { @cache[file_path] }
        if cached && cached[:mtime] == mtime &&
           (Process.clock_gettime(Process::CLOCK_MONOTONIC) - cached[:ts]) < CACHE_TTL_SECONDS
          return cached[:result]
        end

        # Ensure the file is indexed (populates module_names / include_calls too).
        defs = RubyDefinitionService.defs_in_file(file_path)
        if defs.empty?
          # File not yet in cache; trigger a parse of just this one file by
          # calling the definition service with a dummy symbol.
          RubyDefinitionService.call(workspace_root, "__mbeditor_warmup__",
                                     excluded_dirnames: excluded_dirnames,
                                     excluded_paths:    excluded_paths)
          defs = RubyDefinitionService.defs_in_file(file_path)
        end
        return [] if defs.empty?

        method_names = defs.keys
        counts       = count_occurrences(method_names, workspace_root.to_s,
                                         excluded_dirnames: excluded_dirnames,
                                         excluded_paths:    excluded_paths)

        # A method with ≤1 total occurrence has only its own `def` line; no call-sites.
        unused = method_names.select { |n| counts.fetch(n, 0) <= 1 }
        result = unused.filter_map do |name|
          entries = defs[name]
          next unless entries&.any?
          { name: name, line: entries.first[:line] }
        end

        ts = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @cache_mutex.synchronize do
          @cache[file_path] = { mtime: mtime, ts: ts, result: result }
        end

        result
      rescue StandardError
        []
      end

      # Exposed for tests.
      def clear_cache!
        @cache_mutex.synchronize { @cache.clear }
      end

      private

      RG_AVAILABLE = system("which rg > /dev/null 2>&1")

      def count_occurrences(method_names, workspace_root, excluded_dirnames:, excluded_paths:)
        # Build one alternation pattern matching any of the method names as
        # whole identifiers.  We escape each name and join with |.
        escaped  = method_names.map { |n| Regexp.escape(n) }
        pattern  = "\\b(#{escaped.join('|')})\\b"

        if RG_AVAILABLE
          run_ripgrep(pattern, method_names, workspace_root, excluded_paths)
        else
          run_grep(pattern, method_names, workspace_root, excluded_dirnames)
        end
      end

      # ripgrep: --only-matching outputs one match per line (just the matched text).
      def run_ripgrep(pattern, method_names, workspace_root, excluded_paths)
        args = %w[rg --only-matching --no-filename --no-ignore --glob **/*.rb]
        excluded_paths.each { |p| args += ["--glob", "!#{p}"] }
        args += ["-e", pattern, workspace_root]

        counts = Hash.new(0)
        name_set = method_names.to_set
        Timeout.timeout(RG_TIMEOUT) do
          IO.popen(args, err: File::NULL) do |io|
            io.each_line { |line| name = line.chomp; counts[name] += 1 if name_set.include?(name) }
          end
        end
        counts
      rescue StandardError
        {}
      end

      # grep -oh: -o outputs only the matching part, -h suppresses filenames.
      def run_grep(pattern, method_names, workspace_root, excluded_dirnames)
        args = ["grep", "-roh", "-E", pattern, "--include=*.rb"]
        excluded_dirnames.each { |d| args += ["--exclude-dir=#{d}"] }
        args << workspace_root

        counts = Hash.new(0)
        name_set = method_names.to_set
        Timeout.timeout(GREP_TIMEOUT) do
          IO.popen(args, err: File::NULL) do |io|
            io.each_line { |line| name = line.chomp; counts[name] += 1 if name_set.include?(name) }
          end
        end
        counts
      rescue StandardError
        {}
      end
    end
  end
end
