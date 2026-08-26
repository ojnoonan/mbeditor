# frozen_string_literal: true

require "open3"
require "json"
require "timeout"
require "shellwords"
require "etc"

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
    # A user-supplied regex is matched in-process, and Timeout.timeout cannot
    # interrupt a CRuby regex — only Regexp's own timeout (Ruby >= 3.2) can.
    # Below that the gemspec floor (3.0) leaves a catastrophic pattern
    # unguarded, which is the pre-existing behaviour.
    REGEXP_TIMEOUT = 1 # seconds
    REGEXP_TIMEOUT_SUPPORTED = Regexp.method_defined?(:timeout)

    STATE_MUTEX = Mutex.new
    private_constant :STATE_MUTEX

    class << self
      # Whether searches should honour .gitignore. Shared by CodeSearchService
      # so the two search paths can't drift apart again.
      def respect_gitignore?
        Mbeditor.configuration.search_respect_gitignore == true
      end

      # Delegated so there is one rg probe for the whole engine. It is lazy
      # (not frozen at boot) and re-checks negative results, so installing
      # ripgrep while the server runs is picked up within a minute.
      def rg_available?
        AvailabilityProbe.rg
      end

      # The resolved ripgrep executable, shared with CodeSearchService so both
      # search paths run the same binary.
      def rg_command
        AvailabilityProbe.rg_command || "rg"
      end

      # Whether the git tier is usable on this workspace. The presence of a
      # `.git` entry is not enough: a repo git refuses to open (dubious
      # ownership under Docker, a `.git` file pointing at a gitdir that moved,
      # a git binary missing from the server's PATH) still has one. `git grep`
      # then fails, its stderr goes to /dev/null, and search returns instantly
      # with nothing — silently, and with no way to tell it apart from "no
      # matches". AvailabilityProbe.git runs `rev-parse --is-inside-work-tree`,
      # which fails in exactly those cases, so a bad repo falls through to
      # plain grep instead of to an empty result set.
      def git_tier?(root)
        File.exist?(File.join(root, ".git")) && AvailabilityProbe.git(root)
      end

      # Which backend a search on this workspace will actually use. Reported by
      # GET /workspace: the difference between the tiers is 10-30x, so "why is
      # search slow" needs to be answerable without reading the source.
      def backend(workspace_root)
        pick_tier(workspace_root.to_s)
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
          # Bumped so a scan already in flight can tell its results are stale
          # and skip filling the cache it just emptied. One counter for every
          # root: an unrelated invalidation only costs a cache miss.
          @cache_generation = (@cache_generation || 0) + 1
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
        matcher = ExclusionMatcher.new(excluded_paths, root: workspace_root)
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
              # Block form for a literal search: the two-argument gsub expands
              # \1, \& and \\ in the replacement, which a non-regex replace
              # must insert verbatim.
              new_content = if use_regex
                content.gsub(pattern, replacement)
              else
                content.gsub(pattern) { replacement }
              end
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
        generation = STATE_MUTEX.synchronize do
          @result_cache ||= {}
          entry = @result_cache[key]
          return entry[:data] if entry && (now - entry[:ts]) < RESULT_CACHE_TTL

          @cache_generation ||= 0
        end

        data = scan(workspace_root, query, use_regex: use_regex, match_case: match_case,
                    whole_word: whole_word, excluded_paths: excluded_paths,
                    paths: nil, max: MAX_RESULTS, supersede: true)

        # Don't cache superseded scans — their results are truncated by the kill.
        unless data[:superseded]
          STATE_MUTEX.synchronize do
            # A save landed while this scan ran: these rows predate it, and
            # storing them now would serve pre-save matches for a full TTL.
            next if (@cache_generation ||= 0) != generation

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
        matcher = ExclusionMatcher.new(excluded_paths, root: root)
        results = []
        timed_out = false
        timeout_secs = Mbeditor.configuration.search_timeout

        # pgroup: the grep tier is a sh -c pipeline; killing only the shell
        # would leave find/xargs/grep running. TERM goes to the whole group.
        io = IO.popen(env, args, err: File::NULL, pgroup: true)
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

        # Used to locate the match within each hit line so a result can carry
        # its columns. Invalid user regexes are already reported elsewhere;
        # here a nil pattern just means the rows come back without columns.
        pattern = begin
          build_pattern(query, use_regex: use_regex, match_case: match_case, whole_word: whole_word)
        rescue RegexpError
          nil
        end

        begin
          io.each_line do |raw|
            break if results.length >= max

            row = parse_line(tier, raw, root, pattern)
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
        return :git if git_tier?(root)

        :grep
      end

      def build_command(tier, root, query, use_regex:, match_case:, whole_word:, excluded_paths:, paths:)
        exclusions = Array(excluded_paths).map(&:to_s).reject(&:empty?)

        case tier
        when :rg
          args = [rg_command, "--json"]
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
          # Exclusions have to reach git as pathspecs, not just be dropped from
          # the results by the matcher below: otherwise git walks node_modules
          # and every other excluded tree in full before we discard the matches.
          # The "." anchor is required: newer git reads a pathspec list of
          # nothing but :(exclude) entries as "everything except these", but
          # older git refuses it outright ("fatal: There is nothing to exclude
          # from"), exits 128, and search silently returns empty.
          args << "." if paths.nil? && exclusions.any?
          args += exclusions.map { |p| ":(exclude)#{p}" }
          # No LC_ALL=C: measured neutral for the -F -i default and 2.2x slower
          # for -E, and the UTF-8 locale case-folds non-ASCII correctly.
          [{}, args]
        else
          grep = ["grep", "-I", "-Hn", "--line-buffered", use_regex ? "-E" : "-F"]
          grep << "-i" unless match_case
          grep << "-w" if whole_word
          # -e + -- so a query starting with "-" can't be parsed as options.
          grep += ["-e", query, "--"]
          if paths
            [{ "LC_ALL" => "C" }, grep + paths.map { |p| File.expand_path(p, root) }]
          else
            # find prunes every exclusion — slashed ones included, which
            # --exclude-dir cannot express — *before* the walk, then feeds the
            # survivors to grep in parallel batches. grep -r with post-filtered
            # exclusions read vendor/bundle and public/assets in full on every
            # search; measured 7.2 s -> 0.09 s on a 350 MB tree. --line-buffered
            # keeps concurrent greps from tearing lines mid-row on the shared
            # pipe.
            prune = exclusions.flat_map do |p|
              p.include?("/") ? ["-path", File.join(root, p), "-o"] : ["-name", p, "-o"]
            end
            find = ["find", root]
            find += ["("] + prune[0..-2] + [")", "-prune", "-o"] unless prune.empty?
            find += ["-type", "f", "-print0"]
            workers = Etc.nprocessors.clamp(2, 8)
            xargs = ["xargs", "-0", "-P", workers.to_s, "-n", "500"] + grep
            cmd = "#{Shellwords.shelljoin(find)} | #{Shellwords.shelljoin(xargs)}"
            [{ "LC_ALL" => "C" }, ["sh", "-c", cmd]]
          end
        end
      end

      def parse_line(tier, raw, root, pattern = nil)
        if tier == :rg
          begin
            data = JSON.parse(raw)
          rescue JSON::ParserError
            return nil
          end
          return nil unless data["type"] == "match"

          md = data["data"]
          raw_text = md.dig("lines", "text").to_s
          # rg reports submatch offsets in BYTES; Monaco columns are character
          # based, so slice the prefix and measure it as characters.
          sub = Array(md["submatches"]).first
          cols = if sub && sub["start"] && sub["end"]
            bytes = raw_text.dup.force_encoding(Encoding::BINARY)
            start_chars = bytes[0, sub["start"]].to_s.force_encoding(Encoding::UTF_8).scrub.length
            match_chars = bytes[sub["start"], sub["end"] - sub["start"]].to_s.force_encoding(Encoding::UTF_8).scrub.length
            { col: start_chars + 1, end_col: start_chars + match_chars + 1 }
          else
            match_columns(raw_text, pattern)
          end
          return {
            file: relative_path(md.dig("path", "text").to_s, root),
            line: md.dig("line_number"),
            text: raw_text.strip,
            lead: leading_ws(raw_text)
          }.merge(cols)
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

        raw_text = Regexp.last_match(3)
        { file: file_path, line: Regexp.last_match(2).to_i, text: raw_text.strip, lead: leading_ws(raw_text) }
          .merge(match_columns(raw_text, pattern))
      end

      # How many characters `strip` took off the FRONT of the line. `col`/
      # `end_col` are measured against the raw line (see match_columns), so
      # without this the client cannot say where the match sits inside the
      # trimmed `text` it renders — which is what highlighting needs.
      def leading_ws(raw_text)
        raw_text.length - raw_text.lstrip.length
      end

      # 1-based Monaco columns for the first match on a hit line. Returns an
      # empty hash when there is no usable pattern or it doesn't match — the
      # row is still a valid result, it just opens at the start of the line.
      # Measured against the RAW line, never the stripped `text`: the client
      # cannot recover the leading whitespace the strip removed.
      def match_columns(raw_text, pattern)
        return {} unless pattern

        m = pattern.match(raw_text)
        return {} unless m

        { col: m.begin(0) + 1, end_col: m.end(0) + 1 }
      rescue StandardError
        {}
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
        return unless pid

        Process.kill("TERM", -pid)
      rescue StandardError
        begin
          Process.kill("TERM", pid)
        rescue StandardError
          nil
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def build_pattern(query, use_regex:, match_case:, whole_word:)
        flags = match_case ? 0 : Regexp::IGNORECASE
        source = if use_regex
          whole_word ? "\\b(?:#{query})\\b" : query
        else
          whole_word ? "\\b#{Regexp.escape(query)}\\b" : Regexp.escape(query)
        end
        return Regexp.new(source, flags, timeout: REGEXP_TIMEOUT) if REGEXP_TIMEOUT_SUPPORTED

        Regexp.new(source, flags)
      end

      def relative_path(absolute_path, workspace_root)
        absolute_path.delete_prefix("#{workspace_root}/")
      end
    end
  end
end
