# frozen_string_literal: true

require "find"

module Mbeditor
  # Finds methods and functions whose name appears nowhere else in the workspace.
  #
  # A text heuristic, not a call graph: one pass reads every source and view
  # file, counts word tokens in a Hash, and calls a definition unused when its
  # name's total count equals its number of definitions. That makes symbol uses
  # (`before_action :foo`, `send(:foo)`) and string mentions count as uses for
  # free, and it errs toward "used" — dynamic dispatch can hide a use, and a
  # comment mentioning the name hides a dead method, but nothing live is
  # reported. Test files supply uses but never definitions.
  #
  # On demand only: no cache, no watcher.
  class UnusedMethodsService
    EXTENSIONS = %w[.rb .js .jsx .ts .tsx .erb .haml .slim].freeze
    JS_EXTENSIONS = %w[.js .jsx .ts .tsx].freeze
    SKIP_PATHS = %w[vendor node_modules tmp log public/monaco-editor].freeze
    MAX_REPORTED = 1000

    NEVER_REPORT = %w[
      initialize call perform to_s to_param as_json method_missing respond_to_missing? inspect
      setup teardown render constructor
      componentDidMount componentDidUpdate componentWillUnmount shouldComponentUpdate
      getDerivedStateFromProps getSnapshotBeforeUpdate componentDidCatch
    ].freeze
    JS_KEYWORDS = %w[if for while switch catch with function return else do].freeze

    TOKEN = /[A-Za-z_$][\w$]*[?!]?/
    RUBY_DEF = /\A\s*def\s+(?:self\.|[A-Z]\w*\.)?([A-Za-z_]\w*[?!=]?)/
    VISIBILITY = /\A\s*(?:private|protected)\s*\z/
    JS_FUNCTION = /\A\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+([A-Za-z_$][\w$]*)/
    JS_VARIABLE = /\A\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[\w$]+\s*=>)/
    JS_METHOD = /\A\s*(?:(?:static|async|get|set)\s+)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/
    TEST_PATH = %r{(?:\A|/)(?:test|spec)/}

    def self.call(workspace_root)
      new(workspace_root).call
    end

    def initialize(workspace_root)
      @root = workspace_root.to_s
      @matcher = ExclusionMatcher.new(Mbeditor.configuration.excluded_paths + SKIP_PATHS, root: @root)
    end

    def call
      counts = Hash.new(0)
      defs = []
      scanned = 0

      each_source_file do |rel, abs|
        text = File.read(abs, encoding: "UTF-8").scrub
        text.scan(TOKEN) { |token| counts[token] += 1 }
        scanned += 1
        defs.concat(definitions(rel, text)) unless rel.match?(TEST_PATH)
      rescue SystemCallError
        next
      end

      defs.reject! { |d| NEVER_REPORT.include?(d[:name]) || d[:name].start_with?("test_") }
      per_name = defs.group_by { |d| d[:name] }.transform_values(&:size)
      defs.each { |d| d[:unused] = !d[:routed] && counts[d[:name]] == per_name[d[:name]] }

      files = defs.group_by { |d| d[:file] }.select { |_, all| all.all? { |d| d[:unused] } }.keys.sort
      unused = defs.select { |d| d[:unused] }.sort_by { |d| [d[:file], d[:line]] }
      {
        methods: unused.first(MAX_REPORTED).map { |d| d.slice(:file, :line, :name, :kind) },
        files: files,
        scanned: scanned,
        truncated: unused.size > MAX_REPORTED
      }
    end

    private

    def each_source_file
      Find.find(@root) do |abs|
        rel = abs.delete_prefix(@root).delete_prefix("/")
        next if rel.empty?

        if @matcher.excluded?(rel)
          Find.prune
        elsif File.file?(abs) && EXTENSIONS.include?(File.extname(abs)) &&
              File.size(abs) <= FileOperationService::MAX_FILE_SIZE_BYTES
          yield rel, abs
        end
      end
    end

    def definitions(rel, text)
      ext = File.extname(rel)
      return ruby_definitions(rel, text) if ext == ".rb"
      return [] unless JS_EXTENSIONS.include?(ext)

      out = []
      text.each_line.with_index(1) do |line, number|
        if (m = line.match(JS_FUNCTION) || line.match(JS_VARIABLE))
          out << { file: rel, line: number, name: m[1], kind: "function" }
        elsif (m = line.match(JS_METHOD)) && !JS_KEYWORDS.include?(m[1])
          out << { file: rel, line: number, name: m[1], kind: "method" }
        end
      end
      out
    end

    # Public actions with a route are reached by the router, not by name.
    def ruby_definitions(rel, text)
      key = RouteService.controller_key(rel)
      routes = key ? RouteService.for_controller(key) : {}
      hidden = false
      out = []
      text.each_line.with_index(1) do |line, number|
        hidden ||= line.match?(VISIBILITY)
        next unless (m = line.match(RUBY_DEF))

        name = m[1].chomp("=")
        out << { file: rel, line: number, name: name, kind: "def", routed: !hidden && routes.key?(name) }
      end
      out
    end
  end
end
