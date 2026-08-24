# frozen_string_literal: true

require "mbeditor/pending_migrations"

module Mbeditor
  module Rack
    # Wraps ActiveRecord::Migration::CheckPending so a pending migration cannot
    # lock the developer out of the one tool they need to fix it.
    #
    # Rails inserts CheckPending after ActionDispatch::Callbacks whenever
    # config.active_record.migration_error is :page_load — the default a real
    # `rails new` app carries in development. From then until the migration is
    # run, EVERY request raises PendingMigrationError, and that included all of
    # mbeditor's: the file tree, opening a file, and saving one. The editor was
    # unusable in precisely the situation it exists to get you out of, and the
    # migration could not be edited to fix it.
    #
    # An earlier attempt rescued the error above CheckPending and answered
    # mbeditor's own paths with a fallback shell and a 503 for every XHR. That
    # left the shell without its stylesheets or JavaScript — those live under
    # /assets, which is not an mbeditor path, so they still 500'd — and even
    # once loaded every API call was a 503. Rescuing after the fact was the
    # wrong shape; the check simply must not apply to this traffic.
    #
    # So the check still runs (it is file-watcher backed and cheap after the
    # first call, and non-editor traffic must keep Rails' behaviour exactly),
    # but for editor traffic the error is recorded and swallowed rather than
    # raised, and the request proceeds. CheckPending raises before it calls
    # anything downstream, so dispatching afterwards runs the request once, not
    # twice.
    #
    # The recorded message is what surfaces the warning banner, so the developer
    # is still told to migrate — they are just no longer prevented from working.
    class PendingMigrationBypass
      DEFAULT_ASSET_PREFIX = "/assets"

      def initialize(app, file_watcher: nil)
        @app = app
        @checked =
          if file_watcher
            ActiveRecord::Migration::CheckPending.new(app, file_watcher: file_watcher)
          else
            ActiveRecord::Migration::CheckPending.new(app)
          end
      end

      # Announced on every bypassed response so the editor can warn about a
      # migration created mid-session, not only one that existed at page load.
      PENDING_HEADER = "X-Mbeditor-Pending-Migration"

      def call(env)
        return @checked.call(env) unless editor_traffic?(env)

        begin
          result = @checked.call(env)
          # The check passed, so anything recorded earlier is stale.
          Mbeditor::PendingMigrations.clear
          result
        rescue StandardError => e
          raise unless pending_migration_error?(e)

          Mbeditor::PendingMigrations.note(e.message)
          status, headers, body = @app.call(env)
          headers[PENDING_HEADER] = header_safe(e.message)
          [status, headers, body]
        end
      end

      private

      # A header cannot carry the newlines the error message has, and it does
      # not need the whole thing — the banner supplies the instructions.
      def header_safe(message)
        message.to_s.gsub(/\s+/, " ").strip[0, 200]
      end

      def pending_migration_error?(error)
        defined?(ActiveRecord::PendingMigrationError) &&
          error.is_a?(ActiveRecord::PendingMigrationError)
      end

      # Everything the editor needs in order to load and function: its own mount
      # and the assets its page pulls in. Asset requests are included because
      # the shell is inert without them — and because serving a stylesheet has
      # never depended on the schema being current.
      def editor_traffic?(env)
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        prefix = Mbeditor::MountPath.resolve
        return true if path == prefix || path.start_with?("#{prefix}/")

        path.start_with?("#{asset_prefix}/")
      end

      def asset_prefix
        @asset_prefix ||= begin
          configured = Rails.application.config.assets.prefix if Rails.application.config.respond_to?(:assets)
          (configured.presence || DEFAULT_ASSET_PREFIX).to_s.chomp("/")
        rescue StandardError
          DEFAULT_ASSET_PREFIX
        end
      end
    end
  end
end
