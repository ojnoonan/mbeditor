# frozen_string_literal: true

require "open3"
require "timeout"

module Mbeditor
  # Looks up Ruby core / gem method documentation using the +ri+ CLI tool.
  # Falls back silently if +ri+ is unavailable or times out.
  #
  # Returns an array in the same format as RubyDefinitionService:
  #   [{ file: String, line: Integer, signature: String, comments: String }]
  #
  # +line+ is always 0 for ri results (no workspace file location).
  # Results are cached in-process to avoid repeated subprocess overhead.
  class RiDefinitionService
    TIMEOUT_SECONDS = 3
    MAX_DESC_LINES  = 3

    # When a method is defined on many classes, prefer these over the
    # first-alphabetical class, which is almost never the one meant:
    # `new` would resolve to Addrinfo and `each` to ARGF.
    #
    # Ordered most-general first. We don't know the receiver's type, so the
    # honest answer for a bare `each` is Enumerable's, not the first class
    # ri happens to list.
    PREFERRED_CLASSES = %w[
      BasicObject Object Kernel Module Class
      Enumerable Comparable
      Array Hash String Symbol Integer Float Numeric Range Enumerator
      Struct Set Time File IO Exception Proc Method NilClass
    ].freeze

    # Keyed by symbol, so a long session accumulates one entry per name ever
    # hovered. Cleared wholesale at the cap — the next lookups just re-run ri.
    MAX_CACHE_ENTRIES = 500

    @cache = {}
    @mutex = Mutex.new

    class << self
      def call(symbol)
        cached = @mutex.synchronize { @cache[symbol] }
        return cached unless cached.nil?

        result = new(symbol).call
        @mutex.synchronize do
          @cache.clear if @cache.size >= MAX_CACHE_ENTRIES
          @cache[symbol] = result
        end
        result
      end

      # Exposed for tests — clears the in-process cache.
      def clear_cache!
        @mutex.synchronize { @cache.clear }
      end
    end

    def initialize(symbol)
      @symbol = symbol
    end

    def call
      output = run_ri
      return [] if output.nil? || output.strip.empty?
      return [] if output.start_with?("Nothing known")

      parse(output)
    rescue StandardError
      []
    end

    private

    # "map()" or "each()" — a name and empty parens, telling you nothing about
    # arguments, block or return value.
    def bare_signature?(signature)
      signature.to_s.strip.match?(/\A[\w.:]+\(\)\z/)
    end

    def run_ri
      out = nil
      Open3.popen3("ri", "--no-pager", "--format=rdoc", @symbol) do |stdin, stdout, _stderr, wait_thr|
        stdin.close
        begin
          Timeout.timeout(TIMEOUT_SECONDS) { out = stdout.read }
        rescue Timeout::Error
          begin; Process.kill("TERM", wait_thr.pid); rescue StandardError; nil; end
        end
      end
      out
    rescue Errno::ENOENT
      nil
    end

    # Parse rdoc-formatted ri output.
    #
    # ri output can contain multiple "=== Implementation from ClassName" blocks
    # when a method is defined on many classes. We parse all of them and prefer
    # implementations from fundamental Ruby classes (BasicObject, Object, etc.)
    # over the first-alphabetical class (which is almost never what you want).
    def parse(output)
      lines = output.split("\n")
      return [] if lines.empty?

      blocks = extract_blocks(lines)
      return [] if blocks.empty?

      # Rank by position in PREFERRED_CLASSES, not by ri's own ordering, so the
      # most general implementation wins rather than whichever preferred class
      # ri happened to print first.
      #
      # Choose only among recognised classes when there are any — otherwise a
      # rich signature on some obscure class (Enumerator::Lazy#map) would beat
      # the terse one on the class actually meant.
      preferred = blocks.select { |b| PREFERRED_CLASSES.include?(b[:impl]) }
      candidates = preferred.any? ? preferred : blocks

      # Within that set, skip entries ri prints as a bare "map()" — they
      # document nothing — before falling back to class order.
      best = candidates.min_by do |b|
        [bare_signature?(b[:sigs].first) ? 1 : 0,
         PREFERRED_CLASSES.index(b[:impl]) || PREFERRED_CLASSES.length]
      end
      return [] if best.nil? || best[:sigs].empty?

      desc = best[:desc]
               .first(MAX_DESC_LINES)
               .join(" ")
               .gsub(/<[^>]+>/, "")
               .strip

      [{
        file:      best[:source],
        line:      0,
        signature: best[:sigs].first,
        comments:  desc
      }]
    end

    # Returns an array of { source:, impl:, sigs:, desc: } — one per
    # "=== Implementation from X" block, or a single entry for simpler output.
    def extract_blocks(lines)
      global_source = extract_source(lines)
      impl_indices  = lines.each_index.select { |i| lines[i].match?(/\A=== Implementation from /) }

      if impl_indices.empty?
        block = build_block(lines, global_source, nil)
        block ? [block] : []
      else
        impl_indices.filter_map.with_index do |start, idx|
          finish  = (impl_indices[idx + 1] || lines.length) - 1
          section = lines[start..finish]
          impl    = lines[start][/\A=== Implementation from (.+)/, 1].to_s.strip
          # A "(from ...)" inside this section overrides the global source
          local_src = section.find { |l| l.strip.start_with?("(from ") }
          src = local_src ? local_src.strip.delete_prefix("(from ").chomp(")") : global_source
          build_block(section, src, impl)
        end
      end
    end

    # Extract signature lines and description from a single block of lines.
    def build_block(lines, source, impl)
      sep_indices = lines.each_index.select { |i| lines[i].match?(/\A-{5,}\z/) }
      return nil if sep_indices.length < 2

      # ri pads signatures into columns for its terminal output, e.g.
      # "each(sep=$/)             {|line| block }  -> ARGF". Those runs of
      # spaces are meaningless here and render as a gaping hole in the hover.
      sigs = lines[(sep_indices[0] + 1)..(sep_indices[1] - 1)]
               .map { |l| l.strip.squeeze(" ") }
               .reject(&:empty?)
      return nil if sigs.empty?

      desc = (lines[(sep_indices[1] + 1)..] || [])
               .map(&:strip)
               .reject { |l| l.match?(/\A[=<]/) || l.match?(/\A-{5,}\z/) ||
                             l.start_with?("(from ") || l.start_with?("===") }
               .reject(&:empty?)

      { source: source, impl: impl, sigs: sigs, desc: desc }
    end

    def extract_source(lines)
      match = lines.find { |l| l.strip.start_with?("(from ") }
      return "ruby" unless match

      match.strip.delete_prefix("(from ").chomp(")")
    end
  end
end
