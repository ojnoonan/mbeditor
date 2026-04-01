# CLAUDE.md

Mbeditor (Mini Browser Editor) is a **mountable Rails engine** gem providing a browser-based code editor UI for Rails apps. Development-time only.

## Key Commands

```bash
bundle install
bundle exec rake test          # 132 tests, 580 assertions
cd test/dummy && rails server  # http://localhost:3000/mbeditor
```

## Architecture

**Backend:** Rails engine. Core controller is `app/controllers/mbeditor/editors_controller.rb` (file I/O, git status, search, RuboCop). Git features in `git_controller.rb`. Service objects in `app/services/mbeditor/`.

**Frontend:** Plain JS + React + Monaco in `app/assets/javascripts/mbeditor/`. **No build step** — edit files directly. Vendored libs in `vendor/assets/`, Monaco in `public/monaco-editor/`.

## Security (non-negotiable)
- All file paths must go through `resolve_path()` — uses `File.realpath` to prevent symlink escape, caps at 5 MB
- All non-GET/HEAD requests require `X-Mbeditor-Client: 1` header (`verify_mbeditor_client`)
- Git ref names validated against `SAFE_GIT_REF = %r{\A[\w./-]+\z}` before interpolation

## Test Gotchas
- `WebMock.disable_net_connect!` is globally active — any HTTP test needs `stub_request`
- `editors_controller_test.rb` uses `Dir.mktmpdir` as workspace
- `git_controller_test.rb` and all service tests run against the real project repo
- Redmine: `RedmineService#call` is prepended with fixture data in the dummy initializer; HTTP tests call `fetch_issue` via `send` to bypass it

## CI
- `test.yml` — matrix: default `Gemfile` + `gemfiles/rails71.gemfile`
- `publish.yml` — builds gem + pushes to RubyGems on tag/manual dispatch

## Dependencies
Ruby >= 3.0, Rails 7.1–8.x, `sprockets-rails >= 3.4`. Dev: `minitest-reporters`, `webmock`. Host optional: `rubocop`, `rubocop-rails`, `haml_lint`.
