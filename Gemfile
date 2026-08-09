source 'https://rubygems.org'

gemspec

gem 'brakeman',           require: false
gem 'bundler-audit',      require: false
gem 'loofah',             '>= 2.25.1',  require: false  # CVE: GHSA-46fp-8f5p-pf2m
gem 'mcp',                '>= 0.9.2',   require: false  # CVE: CVE-2026-33946
gem 'capybara',           require: false
gem 'cuprite',            require: false
gem 'haml_lint',          require: false
gem 'minitest-reporters', require: false
gem 'puma'
gem 'rubocop',            require: false
gem 'rubocop-rails',      require: false
gem 'webmock',            require: false

# Host-provided in production; here only to exercise the optional integrations
# locally. Gated on Ruby >= 3.2 because mini_racer's native extension fails to
# build on the 3.0/3.1 CI legs — and neither gem is needed for the suite
# (JsSyntaxCheckService tests skip without MiniRacer, and the ruby-lsp client
# tests run against a fake stdio server).
if RUBY_VERSION >= '3.2'
  gem 'mini_racer',       require: false
  gem 'ruby-lsp',         require: false
  # Same reason: sqlite3 2.x's native extension fails to build on the 3.0/3.1
  # legs. The dummy app uses it for a real schema behind the model graph, and
  # boots without ActiveRecord entirely when it is absent — which is also a
  # case worth exercising, since plenty of host apps have no ActiveRecord.
  gem 'sqlite3',          '>= 2.0'
end
