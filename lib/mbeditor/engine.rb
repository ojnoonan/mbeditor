module Mbeditor
  class Engine < ::Rails::Engine
    isolate_namespace Mbeditor

    initializer 'mbeditor.assets.jsx', before: 'sprockets.environment' do |app|
      app.config.assets.configure do |env|
        require 'babel/transpiler'
        env.register_mime_type('text/jsx', extensions: ['.jsx', '.js.jsx'])
        jsx_processor = proc do |input|
          result = Babel::Transpiler.transform(input[:data], 'stage' => 0)
          { data: result['code'] }
        end
        env.register_transformer('text/jsx', 'application/javascript', jsx_processor)
      end
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
        fa-brands-400.woff2
        fa-regular-400.woff2
        fa-solid-900.woff2
      ]
    end
  end
end
