# frozen_string_literal: true

require "ripper"

module Mbeditor
  # Line ranges of every method (and enclosing class/module) in Ruby source.
  #
  # Ripper rather than Prism: it is stdlib on every Ruby this gem supports.
  # Events fire bottom-up, so a node's end line is the last significant token
  # the scanner produced before it reduced, and owners are resolved afterwards
  # by range containment instead of a stack.
  #
  #   call(src) => { methods: [{ name:, singleton:, owner:, start_line:,
  #                               doc_start_line:, end_line: }],
  #                  owners:  [{ kind:, name:, start_line:, end_line: }] }
  #               | { error: "..." }  (owners also hold `class << self` as kind "sclass")
  class RubyMethodRangesService
    MAX_BYTES = 200 * 1024

    # Tokens that carry no code; a def never ends on one of these.
    BLANK = %i[sp nl ignored_nl comment embdoc_beg embdoc embdoc_end words_sep ignored_sp].freeze

    class Collector < Ripper::SexpBuilder
      attr_reader :methods_found, :owners_found

      def initialize(*)
        super
        @methods_found = []
        @owners_found = []
        @last_line = 1
      end

      (Ripper::SCANNER_EVENTS - BLANK).each do |ev|
        define_method(:"on_#{ev}") do |tok|
          @last_line = lineno
          super(tok)
        end
      end

      def on_def(name, *rest)
        record(name, false)
        super
      end

      def on_defs(target, period, name, *rest)
        record(name, true)
        super
      end

      def on_class(const, *rest)
        owner(:class, const)
        super
      end

      def on_sclass(target, *rest)
        @owners_found << { kind: "sclass", name: "<< self", start_line: first_line(target), end_line: @last_line }
        super
      end

      def on_module(const, *rest)
        owner(:module, const)
        super
      end

      private

      def record(ident, singleton)
        @methods_found << { name: ident[1], singleton: singleton, start_line: ident[2][0], end_line: @last_line }
      end

      def owner(kind, const)
        @owners_found << { kind: kind.to_s, name: const_name(const), start_line: first_line(const), end_line: @last_line }
      end

      def const_name(node)
        return "" unless node.is_a?(Array)

        case node[0]
        when :@const then node[1]
        when :const_ref, :var_ref, :top_const_ref then const_name(node[1])
        when :const_path_ref then "#{const_name(node[1])}::#{const_name(node[2])}"
        else ""
        end
      end

      def first_line(node)
        return node[2][0] if node.is_a?(Array) && node[0].is_a?(Symbol) && node[0].to_s.start_with?("@")

        node.each { |c| l = first_line(c) if c.is_a?(Array); return l if l } if node.is_a?(Array)
        nil
      end
    end

    def self.call(source)
      source = source.to_s
      return { error: "Source too large" } if source.bytesize > MAX_BYTES

      parser = Collector.new(source)
      parser.parse
      return { error: "Syntax error" } if parser.error?

      lines = source.lines
      owners = parser.owners_found.sort_by { |o| [o[:start_line], -o[:end_line]] }
      methods = parser.methods_found.sort_by { |m| m[:start_line] }.map do |m|
        chain = owners.select { |o| o[:start_line] <= m[:start_line] && o[:end_line] >= m[:end_line] }
        m.merge(singleton: m[:singleton] || chain.any? { |o| o[:kind] == "sclass" },
                  owner: chain.reject { |o| o[:kind] == "sclass" }.map { |o| o[:name] }.join("::"), doc_start_line: doc_start(lines, m[:start_line]))
      end
      { methods: methods, owners: owners }
    rescue StandardError, SystemStackError => e
      { error: e.message }
    end

    def self.doc_start(lines, start_line)
      line = start_line
      line -= 1 while line > 1 && lines[line - 2].to_s.lstrip.start_with?("#")
      line
    end
  end
end
