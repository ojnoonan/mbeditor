require "mbeditor/rack/silence_ping_request"

module Mbeditor
  class Engine < ::Rails::Engine
    isolate_namespace Mbeditor

    initializer "mbeditor.silence_ping_request" do |app|
      app.middleware.insert_before Rails::Rack::Logger, Mbeditor::Rack::SilencePingRequest
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

    initializer "mbeditor.validate_configuration" do |_app|
      Mbeditor.configuration.validate_workspace_root!
    end
  end
end
