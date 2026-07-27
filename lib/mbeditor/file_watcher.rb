# frozen_string_literal: true

module Mbeditor
  # Watches the workspace for changes made outside the editor — a terminal
  # `git checkout`, a rebase, another editor, a generator — and broadcasts the
  # same `files_changed` payload the mutation endpoints send. Clients refresh
  # the file tree, git line-number tinting and cached globals from it.
  #
  # The `listen` gem is an optional host dependency. Without it the editor
  # behaves exactly as before: only changes made *through* mbeditor announce
  # themselves. Nothing warns loudly about the missing gem — it is opt-in.
  #
  # Only one watcher runs per process. It is deliberately not started in test
  # or in non-server processes (rake, console, the Rails runner), where a
  # background listener thread is pure overhead.
  module FileWatcher
    # Coalesce bursts: a branch switch touches hundreds of files, and each one
    # would otherwise be its own broadcast.
    DEBOUNCE_SECONDS = 0.3

    class << self
      def available?
        return @available if defined?(@available)

        @available = begin
          require "listen"
          true
        rescue LoadError
          false
        end
      end

      def running?
        !@listener.nil?
      end

      # Boot entry point. Confined to the environments the editor is allowed in
      # and to processes that actually serve requests — a rake task or console
      # has no client to broadcast to, and a listener thread there would only
      # burn file handles. MBEDITOR_FORCE_WATCH overrides the process check for
      # unusual servers and for tests.
      def start_if_enabled
        cfg = Mbeditor.configuration
        return false if cfg.watch_files == false
        return false unless cfg.allowed_environments.map(&:to_s).include?(Rails.env.to_s)
        return false unless serving_requests?

        start(cfg.workspace_root.presence || Rails.root.to_s)
      end

      # Returns true when a watcher was started, false for every reason not to
      # (gem absent, already running, no workspace, disabled by config).
      def start(root)
        return false unless available?
        return false if running?

        root = root.to_s
        return false if root.empty? || !File.directory?(root)

        ignores = ignore_patterns(root)
        @listener = ::Listen.to(root, ignore: ignores, latency: DEBOUNCE_SECONDS) do |modified, added, removed|
          broadcast(root, modified + added + removed)
        end
        @listener.start
        Rails.logger.info("[mbeditor] watching #{root} for external changes")
        true
      rescue StandardError => e
        # A watcher that cannot start must never take the host app down with it:
        # inotify limits on Linux, permission issues, an unreadable root.
        Rails.logger.warn("[mbeditor] file watcher failed to start: #{e.class}: #{e.message}")
        @listener = nil
        false
      end

      def stop
        @listener&.stop
      rescue StandardError
        nil
      ensure
        @listener = nil
      end

      private

      def serving_requests?
        return true if ENV["MBEDITOR_FORCE_WATCH"]

        defined?(Rails::Server) || defined?(Puma::Server) || defined?(Unicorn) || defined?(Passenger)
      end

      # `listen` matches ignores against paths relative to the watched root, so
      # the configured exclusions become anchored regexps. Escaping matters:
      # entries like "vendor/bundle" and "public/assets" contain separators, and
      # a stray metacharacter in host config should not build a bogus pattern.
      def ignore_patterns(root)
        Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:empty?).map do |path|
          %r{\A#{Regexp.escape(path.delete_prefix("/").delete_suffix("/"))}(/|\z)}
        end
      end

      # Paths arrive absolute. Anything that does not sit under the workspace
      # is dropped rather than sent raw: the client keys everything by
      # workspace-relative path, and an absolute one would leak host layout.
      def relative_paths(root, paths)
        paths.filter_map do |path|
          rel = path.to_s.delete_prefix("#{root}/")
          rel unless rel.empty? || rel == path.to_s
        end
      end

      def broadcast(root, paths)
        relative = relative_paths(root, paths)

        invalidate_caches(root)
        return unless defined?(ActionCable.server)

        payload = { type: "files_changed" }
        payload[:paths] = relative.first(200) if relative.any?
        ActionCable.server.broadcast("mbeditor_editor", payload)
      rescue StandardError => e
        Rails.logger.warn("[mbeditor] file watcher broadcast failed: #{e.class}: #{e.message}")
      end

      # Mirrors EditorsController#broadcast_files_changed: a change the editor
      # did not make invalidates exactly the same caches as one it did.
      def invalidate_caches(root)
        FileTreeService.invalidate(root)
        SearchReplaceService.invalidate_cache(root)
        JsGlobalsService.invalidate(root)
        GitInfoService.invalidate(root)
      rescue StandardError => e
        Rails.logger.warn("[mbeditor] file watcher cache invalidation failed: #{e.class}: #{e.message}")
      end
    end
  end
end
