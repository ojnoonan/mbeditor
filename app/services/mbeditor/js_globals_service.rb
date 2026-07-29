# frozen_string_literal: true

module Mbeditor
  # Enumerates every top-level JavaScript declaration in the workspace so the
  # editor can declare them as ambient globals in one shot. This models the
  # Sprockets concatenation world: files share one global script scope, so an
  # unindented `var`/`function`/`class` (or a `window.X =` assignment) in any
  # JS-family file is visible everywhere with no import statement.
  #
  # Backed by CodeSearchService (rg > git grep > grep over JS_GLOBS, which
  # includes *.js.jsx / *.js.erb), with a short cache invalidated whenever
  # mbeditor mutates a file.
  class JsGlobalsService
    MAX_SYMBOLS = 3000
    CACHE_TTL = 30 # seconds

    # Column-0 anchored so only true top-level declarations match (Sprockets
    # globals are by definition unindented); window assignments may be
    # indented (IIFE bodies). BSD-grep-safe ERE: no \s, no non-greedy ops.
    PATTERN = '^((var|let|const|function|class|async[ \t]+function)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*' \
              '|[ \t]*window\.[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=)'

    IDENTIFIER = /[A-Za-z_$][A-Za-z0-9_$]*/

    # Minified bundles are the reason for both guards below.
    #
    # A minified file is one enormous line, and it usually opens with a
    # multi-declarator `var a,b,c,d,…` running to thousands of names. Split on
    # commas, that ONE line yields thousands of one-letter symbols — enough to
    # exhaust MAX_SYMBOLS on its own, so the workspace's actual components are
    # never reached and every reference to them shows "Cannot find name".
    # Worse, declaring `a`/`n`/`t` as ambient `any` silences genuine
    # diagnostics for those names everywhere.
    #
    # The name check catches the conventional cases; the line-length check
    # catches bundles that don't say "min" in the filename. Neither is a
    # judgement about vendored code in general — a normally-formatted
    # vendor/assets library still contributes its globals, which is correct
    # under Sprockets.
    MINIFIED_NAME = /[.\-]min\.(js|jsx|ts|tsx)\z/i
    MAX_LINE_LENGTH = 2_000

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def call(workspace_root)
        root = workspace_root.to_s
        now = monotonic
        MUTEX.synchronize do
          entry = (@cache ||= {})[root]
          return entry[:data] if entry && (now - entry[:ts]) < CACHE_TTL
        end

        data = compute(root)
        MUTEX.synchronize { (@cache ||= {})[root] = { ts: monotonic, data: data } }
        data
      end

      def invalidate(workspace_root)
        MUTEX.synchronize { (@cache ||= {}).delete(workspace_root.to_s) }
      end

      private

      def compute(root)
        symbols = {}
        truncated = false

        CodeSearchService.call(PATTERN, root).each do |raw|
          if symbols.length >= MAX_SYMBOLS
            truncated = true
            break
          end

          m = raw.chomp.match(/\A(.+?):(\d+):(.*)\z/m)
          next unless m

          abs_path = m[1]
          next unless abs_path.start_with?(root)
          next if abs_path.match?(MINIFIED_NAME)

          snippet = m[3].strip
          next if snippet.length > MAX_LINE_LENGTH

          rel = abs_path.delete_prefix(root).delete_prefix("/")
          line = m[2].to_i
          extract_identifiers(snippet).each do |name, kind|
            symbols[name] ||= { name: name, file: rel, line: line, kind: kind }
          end
        end

        configured_identifiers.each do |name|
          symbols[name] ||= { name: name, file: nil, line: nil, kind: "configured" }
        end

        {
          ok: true,
          generatedAt: Time.now.to_i,
          # Surfaced so a workspace that outgrows the cap is diagnosable from
          # the endpoint instead of silently missing globals.
          truncated: truncated,
          symbols: symbols.values.first(MAX_SYMBOLS).sort_by { |s| s[:name] }
        }
      end

      # Returns [[name, kind], ...] for the declaration(s) on one matched line.
      def extract_identifiers(snippet)
        if (m = snippet.match(/\Awindow\.(#{IDENTIFIER})[ \t]*=/o))
          return [[m[1], "window"]]
        end

        if (m = snippet.match(/\A(?:async[ \t]+)?(function|class)[ \t]+(#{IDENTIFIER})/o))
          return [[m[2], m[1]]]
        end

        if (m = snippet.match(/\A(var|let|const)[ \t]+(.*)/))
          kind = m[1]
          # Multi-declarator lines (`var A = 1, B = 2`): take the leading
          # identifier of each comma segment. Commas inside initializers can
          # produce segments that don't start with an identifier — those are
          # simply skipped.
          return m[2].split(",").filter_map { |seg|
            id = seg.strip[/\A#{IDENTIFIER}/o]
            [id, kind] if id
          }
        end

        []
      end

      def configured_identifiers
        Array(Mbeditor.configuration.js_global_identifiers)
          .map(&:to_s)
          .select { |n| n.match?(/\A#{IDENTIFIER}\z/o) }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
