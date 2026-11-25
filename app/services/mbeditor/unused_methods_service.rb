# frozen_string_literal: true

require "find"
require "set"

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
  # The same pass also collects `render` references so it can report view
  # templates that nothing renders (see #unused_views). Methods are never
  # reported for erb/haml/slim: those files only supply uses.
  #
  # On demand only: no cache, no watcher.
  class UnusedMethodsService
    EXTENSIONS = %w[.rb .js .jsx .ts .tsx .erb .haml .slim .jbuilder].freeze
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

    VIEW_FILE = %r{\Aapp/views/(.+)\.(?:erb|haml|slim|jbuilder)\z}
    OWNER_FILE = %r{\Aapp/(?:controllers|mailers)/(.+?)(?:_controller)?\.rb\z}
    REF_EXTENSIONS = %w[.rb .erb .haml .slim .jbuilder].freeze
    QUOTED_PATH = %r{["'](\w+(?:/\w+)+)["']}
    DYNAMIC_PATH = %r{["']([\w/]+)\#\{}
    RENDER_CALL = /\brender\b([^\n]*)/
    LAYOUT_CALL = %r{\blayout:?\s*\(?\s*:?["']?(\w[\w/]*)}
    BARE_NAME = /["'](\w+)["']|:(\w+)/
    MODEL_ARG = /\A\s*\(?\s*(?:(?:collection|object):\s*)?(@?[\w.]+)/

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
      refs = { quoted: Set.new, prefixes: [], bare: Set.new, loose: Set.new, models: Set.new,
               layouts: Set.new, owners: Set.new, views: [] }

      each_source_file do |rel, abs|
        text = File.read(abs, encoding: "UTF-8").scrub
        text.scan(TOKEN) { |token| counts[token] += 1 }
        scanned += 1
        defs.concat(definitions(rel, text)) unless rel.match?(TEST_PATH)
        collect_refs(rel, text, refs)
      rescue SystemCallError
        next
      end

      views = unused_views(refs, defs)
      defs.reject! { |d| NEVER_REPORT.include?(d[:name]) || d[:name].start_with?("test_") }
      per_name = defs.group_by { |d| d[:name] }.transform_values(&:size)
      defs.each { |d| d[:unused] = !d[:routed] && counts[d[:name]] == per_name[d[:name]] }

      files = defs.group_by { |d| d[:file] }.select { |_, all| all.all? { |d| d[:unused] } }.keys.sort
      unused = defs.select { |d| d[:unused] }.sort_by { |d| [d[:file], d[:line]] }
      {
        methods: unused.first(MAX_REPORTED).map { |d| d.slice(:file, :line, :name, :kind) },
        files: files,
        views: views,
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

    # Per-file render evidence for #unused_views. Every form errs toward "used".
    def collect_refs(rel, text, refs)
      refs[:views] << rel if rel.match?(VIEW_FILE)
      return unless REF_EXTENSIONS.include?(File.extname(rel))

      dir = rel[VIEW_FILE, 1]&.then { |logical| File.dirname(logical) } || rel[OWNER_FILE, 1]
      refs[:owners] << dir if dir && !rel.start_with?("app/views/")
      text.scan(QUOTED_PATH) { |(path)| refs[:quoted] << path }
      text.scan(DYNAMIC_PATH) { |(prefix)| refs[:prefixes] << prefix }
      text.scan(LAYOUT_CALL) { |(name)| refs[:layouts] << name }
      text.scan(RENDER_CALL) do |(args)|
        args.scan(BARE_NAME) do |quoted, symbol|
          name = quoted || symbol
          dir ? refs[:bare] << "#{dir}/#{name}" : refs[:loose] << name
        end
        # `render @users`, `render user`, `render collection: @user.posts`
        args[MODEL_ARG, 1]&.split(/[.@]/)&.each { |seg| refs[:models] << seg.singularize unless seg.empty? }
      end
    end

    # View templates under app/views that no collected reference reaches.
    # A partial is used by a "dir/name" string, a relative `render "name"` from
    # its own directory (or the controller that owns it), or a model render that
    # resolves to it. An action template is used by a route, a `def`, or a
    # reference. ponytail: `render "#{x}/form"` (empty static prefix) is not
    # tracked; add a reference-free fallback if that pattern shows up.
    def unused_views(refs, defs)
      routed = RouteService.all(@root).to_set { |r| "#{r[:controller]}/#{r[:action]}" }
      actions = defs.filter_map { |d| (key = d[:file][OWNER_FILE, 1]) && "#{key}/#{d[:name]}" }.to_set
      refs[:views].reject { |rel| view_used?(rel, refs, routed, actions) }.sort
    end

    def view_used?(rel, refs, routed, actions)
      dir, base = File.split(rel[VIEW_FILE, 1])
      name = base.split(".").first
      partial = name.delete_prefix!("_")
      path = dir == "." ? name : "#{dir}/#{name}"
      return true if dir == "layouts" && name == "application"
      return true if refs[:quoted].include?(path) || refs[:prefixes].any? { |p| path.start_with?(p) }

      if partial
        refs[:bare].include?(path) || refs[:loose].include?(name) ||
          (refs[:models].include?(name) && dir.split("/").last == name.pluralize)
      elsif dir.start_with?("layouts")
        layout = path.delete_prefix("layouts/")
        refs[:layouts].include?(layout) || layout == "mailer" || refs[:owners].include?(layout)
      else
        refs[:bare].include?(path) || actions.include?(path) || routed.include?(path)
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
