require "mbeditor/rack/silence_ping_request"
require "mbeditor/rack/handle_pending_migrations"

module Mbeditor
  class Engine < ::Rails::Engine
    isolate_namespace Mbeditor

    initializer "mbeditor.silence_ping_request" do |app|
      app.middleware.insert_before Rails::Rack::Logger, Mbeditor::Rack::SilencePingRequest
    end

    initializer "mbeditor.handle_pending_migrations" do |app|
      # Insert before CheckPending so our middleware wraps it and can rescue
      # the error it raises. Falls back silently if CheckPending is absent
      # (e.g. host app does not use ActiveRecord).
      check_pending = defined?(ActiveRecord::Migration::CheckPending) &&
                      app.middleware.middlewares.find { |m| m.name == "ActiveRecord::Migration::CheckPending" }
      if check_pending
        app.middleware.insert_before ActiveRecord::Migration::CheckPending,
                                     Mbeditor::Rack::HandlePendingMigrations
      end
    end

    config.after_initialize do
      Mbeditor::RubyDefinitionService.cache_path =
        Rails.root.join("tmp", "mbeditor_ruby_defs.json").to_s
    end

    initializer "mbeditor.assets.precompile" do |app|
      app.config.assets.precompile += %w[
        mbeditor/application.css
        mbeditor/application.js
        fontawesome.min.css
        react.min.js
        react-dom.min.js
        axios.min.js
        lodash.min.js
        minisearch.min.js
        marked.min.js
        prettier-standalone.js
        prettier-plugin-babel.js
        prettier-plugin-estree.js
        prettier-plugin-html.js
        prettier-plugin-postcss.js
        prettier-plugin-markdown.js
        monaco-vim.js
        emmet.js
        monaco-themes-bundle.js
        fa-brands-400.woff2
        fa-regular-400.woff2
        fa-solid-900.woff2
      ]
    end
  end
end
