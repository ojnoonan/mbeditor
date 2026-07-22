# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

module Mbeditor
  # Project-wide text search and replace-in-files.
  #
  # Search runs through a three-tier backend picked per call:
  #   rg (fastest) > git grep (fast, respects .gitignore) > grep (portable).
  # A single subprocess per query collects the full (capped) result set, which
  # is cached briefly so pagination serves pages from memory instead of
  # re-scanning the workspace. A new query supersedes (kills) any search still
  # running for the same workspace so stacked keystrokes can't pile up
  # concurrent full-tree scans.
  class SearchReplaceService
    MAX_REPLACE_FILES = 500
    PER_FILE_TIMEOUT = 5
    # Full-result cap per query. Also the ceiling for reported total counts.
    MAX_RESULTS = 10_000
    RESULT_CACHE_TTL = 30 # seconds; also invalidated on mbeditor file mutations
    RESULT_CACHE_MAX_ENTRIES = 3
    RG_PROBE_TTL = 60 # seconds between re-probes for rg on PATH

    STATE_MUTEX = Mutex.new
    private_constant :STATE_MUTEX

    class << self
      # Whether searches should honour .gitignore. Shared by CodeSearchService
      # so the two search paths can't drift apart again.
      def respect_gitignore?
        Mbeditor.configuration.search_respect_gitignore == true
      end

      # Probed with a TTL (not frozen at boot) so installing ripgrep while the
      # server is running is picked up within a minute.
      def rg_available?
        now = monotonic
        STATE_MUTEX.synchronize do
          if @rg_checked_at.nil? || (now - @rg_checked_at) > RG_PROBE_TTL
            @rg_available = system("which rg > /dev/null 2>&1")
            @rg_checked_at = now
          end
          @rg_available
        end
      end

      # Returns up to +limit+ result rows. When +paths+ is given the scan is
      # restricted to those files (used by the live result-refresh) and the
      # result cache is bypassed.
      def search(workspace_root, query, limit:, use_regex:, match_case:, whole_word:, excluded_paths:, paths: nil)
        if paths
          return scan(workspace_root, query, use_regex: use_regex, match_case: match_case,
                      whole_word: whole_word, excluded_paths: excluded_paths,
                      paths: paths, max: limit)[:results]
        end

        full = full_results(workspace_root, query, use_regex: use_regex, match_case: match_case,
                            whole_word: whole_word, excluded_paths: excluded_paths)
        full[:results].first(limit)
      end

      # Page into the cached full result set. total_count is only reported when
      # the scan completed (not capped, not timed out).
      def search_page(workspace_root, query, offset:, limit:, use_regex:, match_case:, whole_word:, excluded_paths:)
        full = full_results(workspace_root, query, use_regex: use_regex, match_case: match_case,
                            whole_word: whole_word, excluded_paths: excluded_paths)
        results = full[:results]
        {
          results: results[offset, limit] || [],
          has_more: results.length > offset + limit,
          total_count: full[:complete] ? results.length : nil,
          partial: !full[:complete]
        }
      end

      def count(workspace_root, query, use_regex:, match_case:, whole_word:, excluded_paths:)
        full_results(workspace_root, query, use_regex: use_regex, match_case: match_case,
                     whole_word: whole_word, excluded_paths: excluded_paths)[:results].length
      rescue StandardError
        0
      end

      def invalidate_cache(workspace_root = nil)
        STATE_MUTEX.synchronize do
          @result_cache ||= {}
          if workspace_root
            root = workspace_root.to_s
            @result_cache.delete_if { |key, _| key[0] == root }
          else
            @result_cache = {}
          end
        end
      end

      def replace(workspace_root, query, replacement, use_regex:, match_case:, whole_word:, excluded_paths:)
        workspace_root = workspace_root.to_s

        raw_results = search(workspace_root, query, limit: MAX_RESULTS, use_regex: use_regex,
                             match_case: match_case, whole_word: whole_word, excluded_paths: excluded_paths)
        file_paths = raw_results.map { |r| r[:file] }.uniq

        if file_paths.length > MAX_REPLACE_FILES
          return { error: "Too many files matched (#{file_paths.length}). Narrow your search.",
                   replaced_count: 0, files_affected: [], errors: [], partial: false }
        end

        pattern = build_pattern(query, use_regex: use_regex, match_case: match_case, whole_word: whole_word)
        matcher = ExclusionMatcher.new(excluded_paths)
        replaced_count = 0
        files_affected = []
        errors = []

        file_paths.each do |rel_path|
          full_path = File.join(workspace_root, rel_path)

          next if matcher.excluded?(rel_path)

          unless File.file?(full_path)
            errors << { file: rel_path, error: "File not found" }
            next
          end

          if File.size(full_path) > FileOperationService::MAX_FILE_SIZE_BYTES
            errors << { file: rel_path, error: "File too large" }
            next
          end

          begin
            Timeout.timeout(PER_FILE_TIMEOUT) do
              content = File.binread(full_path).force_encoding("UTF-8")
                           .encode("UTF-8", invalid: :replace, undef: :replace)
              replacements_in_file = content.scan(pattern).length
              new_content = content.gsub(pattern, replacement)
              if new_content != content
                File.binwrite(full_path, new_content.encode("UTF-8", invalid: :replace, undef: :replace))
                files_affected << rel_path
                replaced_count += replacements_in_file
              end
            end
          rescue Timeout::Error
            errors << { file: rel_path, error: "Timed out processing file" }
          rescue StandardError => e
            errors << { file: rel_path, error: e.message }
          end
        end

        invalidate_cache(workspace_root) if files_affected.any?

        {
          replaced_count: replaced_count,
          files_affected: files_affected,
          errors: errors,
          partial: errors.any? && files_affected.any?
        }
      rescue RegexpError => e
        { error: "Invalid regex: #{e.message}", replaced_count: 0, files_affected: [], errors: [], partial: false }
      end

      private

      def full_results(workspace_root, query, use_regex:, match_case:, whole_word:, excluded_paths:)
        key = [workspace_root.to_s, query, use_regex, match_case, whole_word,
               Array(excluded_paths).map(&:to_s).sort]
        now = monotonic
        STATE_MUTEX.synchronize do
          @result_cache ||= {}
          entry = @result_cache[key]
          return entry[:data] if entry && (now - entry[:ts]) < RESULT_CACHE_TTL
        end

        data = scan(workspace_root, query, use_regex: use_regex, match_case: match_case,
                    whole_word: whole_word, excluded_paths: excluded_paths,
                    paths: nil, max: MAX_RESULTS, supersede: true)

        # Don't cache superseded scans — their results are truncated by the kill.
        unless data[:superseded]
          STATE_MUTEX.synchronize do
            @result_cache[key] = { ts: monotonic, data: data }
            @result_cache.delete(@result_cache.keys.first) while @result_cache.length > RESULT_CACHE_MAX_ENTRIES
          end
        end
        data
      end

      def scan(workspace_root, query, use_regex:, match_case:, whole_word:, excluded_paths:, paths:, max:, supersede: false)
        root = workspace_root.to_s
        tier = pick_tier(root)
        env, args = build_command(tier, root, query, use_regex: use_regex, match_case: match_case,
                                  whole_word: whole_word, excluded_paths: excluded_paths, paths: paths)
        matcher = ExclusionMatcher.new(excluded_paths)
        results = []
        timed_out = false
        timeout_secs = Mbeditor.configuration.search_timeout

        io = IO.popen(env, args, err: File::NULL)
        pid = io.pid
        register_search(root, pid) if supersede
        watchdog = nil
        if timeout_secs && timeout_secs.to_i > 0
          watchdog = Thread.new do
            sleep timeout_secs
            timed_out = true
            kill_quietly(pid)
          end
        end

        begin
          io.each_line do |raw|
            break if results.length >= max

            row = parse_line(tier, raw, root)
            next unless row
            next if matcher.excluded?(row[:file])

            results << row
          end
        rescue IOError, Errno::EIO
          # pipe torn down by a kill — return what we have
        ensure
          watchdog&.kill
          kill_quietly(pid)
          begin
            io.close
          rescue StandardError
            nil
          end
        end

        superseded = supersede && !current_search?(root, pid)
        clear_search(root, pid) if supersede
        {
          results: results,
          complete: !timed_out && !superseded && results.length < max,
          superseded: superseded
        }
      end

      def pick_tier(root)
        return :rg if rg_available?
        return :git if File.exist?(File.join(root, ".git"))

        :grep
      end

      def build_command(tier, root, query, use_regex:, match_case:, whole_word:, excluded_paths:, paths:)
        exclusions = Array(excluded_paths).map(&:to_s).reject(&:empty?)

        case tier
        when :rg
          args = ["rg", "--json"]
          args << "--no-ignore" unless respect_gitignore?
          args << "-F" unless use_regex
          args << "--ignore-case" unless match_case
          args << "--word-regexp" if whole_word
          exclusions.each { |p| args << "--glob=!#{p}" }
          args << "--"
          args << query
          args += paths ? paths.map { |p| File.expand_path(p, root) } : [root]
          [{}, args]
        when :git
          args = ["git", "-C", root, "grep", "-I", "-n", "--no-color"]
          # --untracked adds untracked-but-not-ignored files; --no-index
          # searches the working tree including ignored files. git rejects the
          # two together.
          args << (respect_gitignore? ? "--untracked" : "--no-index")
          args << "-F" unless use_regex
          args << "-E" if use_regex
          args << "-i" unless match_case
          args << "-w" if whole_word
          args += ["-e", query, "--"]
          args += paths.map { |p| relative_path(File.expand_path(p, root), root) } if paths
          # C locale restores fast byte-wise case folding for -i (non-ASCII
          # characters simply don't case-fold, which is acceptable here).
          [{ "LC_ALL" => "C" }, args]
        else
          base_flags = use_regex ? "-E" : "-F"
          args = ["grep", "-I", "-Hn", base_flags]
          args << "-r" unless paths
          args << "-i" unless match_case
          args << "-w" if whole_word
          # grep --exclude-dir only accepts plain directory names, not paths with
          # slashes; slashed patterns are enforced by the ExclusionMatcher
          # post-filter instead.
          exclusions.reject { |p| p.include?("/") }.select { |d| d.match?(/\A[\w.-]+\z/) }.each { |d| args << "--exclude-dir=#{d}" }
          args << query
          args += paths ? paths.map { |p| File.expand_path(p, root) } : [root]
          [{ "LC_ALL" => "C" }, args]
        end
      end

      def parse_line(tier, raw, root)
        if tier == :rg
          begin
            data = JSON.parse(raw)
          rescue JSON::ParserError
            return nil
          end
          return nil unless data["type"] == "match"

          md = data["data"]
          return {
            file: relative_path(md.dig("path", "text").to_s, root),
            line: md.dig("line_number"),
            text: md.dig("lines", "text").to_s.strip
          }
        end

        # git grep / grep emit "path:line:text" — possibly with bytes that are
        # not valid UTF-8; scrub before any regex work so a stray binary line
        # can't raise ArgumentError.
        line = raw.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub("�") unless line.valid_encoding?
        return nil unless line =~ /\A(.+?):(\d+):(.*)\z/m

        file_path = Regexp.last_match(1)
        if tier == :grep
          return nil unless file_path.start_with?(root)

          file_path = relative_path(file_path, root)
        end

        { file: file_path, line: Regexp.last_match(2).to_i, text: Regexp.last_match(3).strip }
      end

      def register_search(root, pid)
        STATE_MUTEX.synchronize do
          @active_searches ||= {}
          old = @active_searches[root]
          kill_quietly(old) if old
          @active_searches[root] = pid
        end
      end

      def current_search?(root, pid)
        STATE_MUTEX.synchronize { (@active_searches || {})[root] == pid }
      end

      def clear_search(root, pid)
        STATE_MUTEX.synchronize do
          @active_searches.delete(root) if @active_searches && @active_searches[root] == pid
        end
      end

      def kill_quietly(pid)
        Process.kill("TERM", pid) if pid
      rescue StandardError
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def build_pattern(query, use_regex:, match_case:, whole_word:)
        flags = match_case ? 0 : Regexp::IGNORECASE
        if use_regex
          Regexp.new(whole_word ? "\\b(?:#{query})\\b" : query, flags)
        else
          Regexp.new(whole_word ? "\\b#{Regexp.escape(query)}\\b" : Regexp.escape(query), flags)
        end
      end

      def relative_path(absolute_path, workspace_root)
        absolute_path.delete_prefix("#{workspace_root}/")
      end
    end
  end
end
