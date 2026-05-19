# frozen_string_literal: true

module Mbeditor
  class ExclusionMatcher
    def initialize(patterns)
      @patterns = patterns.map(&:to_s).reject(&:empty?)
    end

    def excluded?(relative_path)
      @patterns.any? { |pattern| matches?(pattern, relative_path) }
    end

    private

    def matches?(pattern, rel)
      if pattern.include?("/")
        rel == pattern || rel.start_with?("#{pattern}/")
      else
        File.basename(rel) == pattern || rel.split("/").include?(pattern)
      end
    end
  end
end
