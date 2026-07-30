# frozen_string_literal: true

module Mbeditor
  # Save-time JS/JSX syntax check using the HOST app's own toolchain: runs
  # babel-standalone inside a MiniRacer (V8) context — the same transform that
  # sprockets/react-rails will apply — so code that would break the host's
  # asset pipeline is caught in the editor instead of at page load.
  #
  # Zero new dependencies (ADR-0001): active only when the host already has
  # mini_racer loaded AND a babel-standalone asset can be found. Degrades to a
  # no-op otherwise.
  class JsSyntaxCheckService
    EVAL_TIMEOUT_MS = 2_000
    # V8 heap grows across transforms; recreate the context periodically.
    MAX_CHECKS_PER_CONTEXT = 50
    BABEL_ASSET_CANDIDATES = %w[babel.min.js babel.js babel-standalone.js babel-standalone.min.js].freeze

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def available?
        return false if Mbeditor.configuration.js_syntax_check == false
        return false unless defined?(::MiniRacer)

        !babel_source_path.nil?
      end

      # Returns nil when the source parses cleanly (or the checker is
      # unavailable/broken), else { "message" =>, "line" =>, "column" => }.
      def check(source)
        return nil unless available?

        MUTEX.synchronize do
          begin
            ctx = context
            return nil unless ctx

            result = ctx.eval(<<~JS)
              (function () {
                try {
                  Babel.transform(#{source.to_json}, { presets: ["react"], code: false });
                  return null;
                } catch (e) {
                  return {
                    message: String((e && e.message) || e).split("\\n")[0],
                    line: (e && e.loc && e.loc.line) || null,
                    column: (e && e.loc && e.loc.column) || null
                  };
                }
              })()
            JS

            @checks_run = (@checks_run || 0) + 1
            reset_context! if @checks_run >= MAX_CHECKS_PER_CONTEXT
            result
          rescue StandardError
            # Timeout / V8 OOM / eval failure: recreate on next use, report clean.
            reset_context!
            nil
          end
        end
      end

      # Exposed for tests.
      def reset!
        MUTEX.synchronize do
          reset_context!
          @babel_path = :unresolved
        end
      end

      private

      def context
        @context ||= begin
          path = babel_source_path
          return nil unless path

          ctx = ::MiniRacer::Context.new(timeout: EVAL_TIMEOUT_MS)
          ctx.eval(File.read(path))
          ctx.eval("if (typeof Babel === 'undefined') { throw new Error('Babel global missing'); }")
          @checks_run = 0
          ctx
        rescue StandardError
          @context = nil
          nil
        end
      end

      def reset_context!
        @context = nil
        @checks_run = 0
      end

      def babel_source_path
        cached = @babel_path
        return (cached == :none ? nil : cached) if cached && cached != :unresolved

        @babel_path = resolve_babel_path || :none
        @babel_path == :none ? nil : @babel_path
      end

      def resolve_babel_path
        configured = Mbeditor.configuration.babel_standalone_path.to_s
        if configured != ""
          return configured if File.file?(configured)

          in_workspace = File.expand_path(configured, Rails.root.to_s)
          return in_workspace if File.file?(in_workspace)

          return nil
        end

        assets = Rails.application.try(:assets)
        return nil unless assets.respond_to?(:find_asset)

        BABEL_ASSET_CANDIDATES.each do |name|
          asset = begin
            assets.find_asset(name)
          rescue StandardError
            nil
          end
          filename = asset.respond_to?(:filename) ? asset.filename.to_s : nil
          return filename if filename && File.file?(filename)
        end
        nil
      end
    end
  end
end
