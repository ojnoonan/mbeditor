# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

module Mbeditor
  class SearchReplaceService
    MAX_REPLACE_FILES = 500
    PER_FILE_TIMEOUT = 5

    class << self
      def search(workspace_root, query, limit:, use_regex:, match_case:, whole_word:, excluded_paths:)
        results = []

        if AvailabilityProbe.rg
          args = ["rg", "--json", "--no-ignore"]
          args << "-F" unless use_regex
          args << "--ignore-case" unless match_case
          args << "--word-regexp" if whole_word
          Array(excluded_paths).map(&:to_s).reject(&:empty?).each { |p| args << "--glob=!#{p}" }
          args += ["--", query, workspace_root.to_s]

          IO.popen(args, err: File::NULL) do |io|
            io.each_line do |raw|
              break if results.length >= limit

              begin
                data = JSON.parse(raw)
              rescue JSON::ParserError
                next
              end
              next unless data["type"] == "match"

              md = data["data"]
              results << {
                file: relative_path(md.dig("path", "text").to_s, workspace_root),
                line: md.dig("line_number"),
                text: md.dig("lines", "text").to_s.strip
              }
            end
          end
        else
          base_flags = use_regex ? "-E" : "-F"
          args = ["grep", "-rn", base_flags]
          args << "-i" unless match_case
          args << "-w" if whole_word
          # grep --exclude-dir only accepts plain directory names, not paths with slashes
          Array(excluded_paths).map(&:to_s).reject(&:empty?).reject { |p| p.include?("/") }.select { |d| d.match?(/\A[\w.\/-]+\z/) }.each { |d| args << "--exclude-dir=#{d}" }
          args += [query, workspace_root.to_s]

          IO.popen(args, err: File::NULL) do |io|
            io.each_line do |raw|
              break if results.length >= limit

              raw.chomp!
              next unless raw =~ /\A(.+?):(\d+):(.*)\z/

              file_path = Regexp.last_match(1)
              next unless file_path.start_with?(workspace_root.to_s)

              rel = relative_path(file_path, workspace_root)
              next if ExclusionMatcher.new(excluded_paths).excluded?(rel)

              results << {
                file: rel,
                line: Regexp.last_match(2).to_i,
                text: Regexp.last_match(3).strip
              }
            end
          end
        end

        results
      end

      def count(workspace_root, query, use_regex:, match_case:, whole_word:, excluded_paths:)
        total = 0
        if AvailabilityProbe.rg
          args = ["rg", "--count", "--no-ignore"]
          args << "-F" unless use_regex
          args << "--ignore-case" unless match_case
          args << "--word-regexp" if whole_word
          Array(excluded_paths).map(&:to_s).reject(&:empty?).each { |p| args << "--glob=!#{p}" }
          args += ["--", query, workspace_root.to_s]
          IO.popen(args, err: File::NULL) do |io|
            io.each_line { |line| total += line.strip.split(":").last.to_i rescue 0 }
          end
        else
          base_flags = use_regex ? "-E" : "-F"
          args = ["grep", "-rc", base_flags]
          args << "-i" unless match_case
          args << "-w" if whole_word
          # grep --exclude-dir only accepts plain directory names, not paths with slashes
          Array(excluded_paths).map(&:to_s).reject(&:empty?).reject { |p| p.include?("/") }.each { |d| args << "--exclude-dir=#{d}" }
          args += [query, workspace_root.to_s]
          IO.popen(args, err: File::NULL) do |io|
            io.each_line { |line| total += line.strip.split(":").last.to_i rescue 0 }
          end
        end
        total
      rescue StandardError
        0
      end

      def replace(workspace_root, query, replacement, use_regex:, match_case:, whole_word:, excluded_paths:)
        workspace_root = workspace_root.to_s

        raw_results = search(workspace_root, query, limit: 10_000, use_regex: use_regex,
                             match_case: match_case, whole_word: whole_word, excluded_paths: excluded_paths)
        file_paths = raw_results.map { |r| r[:file] }.uniq

        if file_paths.length > MAX_REPLACE_FILES
          return { error: "Too many files matched (#{file_paths.length}). Narrow your search.",
                   replaced_count: 0, files_affected: [], errors: [], partial: false }
        end

        pattern = build_pattern(query, use_regex: use_regex, match_case: match_case, whole_word: whole_word)
        replaced_count = 0
        files_affected = []
        errors = []

        file_paths.each do |rel_path|
          full_path = File.join(workspace_root, rel_path)

          next if ExclusionMatcher.new(excluded_paths).excluded?(rel_path)

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
