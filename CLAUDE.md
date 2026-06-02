# CLAUDE.md

Mbeditor (Mini Browser Editor) is a **mountable Rails engine** gem providing a browser-based code editor UI for Rails apps. Development-time only.

## Key Commands

```bash
bundle install
bundle exec rake test          # 495 tests, 1681 assertions
cd test/dummy && rails server  # http://localhost:3000/mbeditor
```

## Architecture

**Backend:** Rails engine. Controllers are thin renderers; business logic lives in `app/services/mbeditor/`. Key services:
- `GitInfoService` — concurrent git metadata fetch (wave orchestration, 5 s TTL cache)
- `SearchReplaceService` — rg/grep subprocess execution, ReDoS guards, replace-in-files (supersedes `CodeSearchService`)
- `EditorStateService` — JSON state persistence with file locking; used by both `EditorsController` and `EditorChannel`
- `ExclusionMatcher` — unified path exclusion predicate
- `FileOperationService` — all file mutations (save, create, rename, delete) with path-safety invariants
- `ProcessRunner` — subprocess-with-timeout (used by `GitService`, `TestRunnerService`, lint path)
- `AvailabilityProbe` — checks tool availability (rg, rubocop, haml_lint, etc.)
- `FileTreeService` — builds the directory tree response
- `RubyDefinitionService` — AST-based definition search with self-warming disk cache

Git features in `git_controller.rb`. Git primitive wrappers in `GitService`. Dedicated services for each git operation (`GitDiffService`, `GitBlameService`, `GitFileHistoryService`, `GitCommitGraphService`, `GitCommitDetailService`, `GitCombinedDiffService`).

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

## Agent skills

### Issue tracker

Issues live in GitHub Issues on ojnoonan/mbeditor. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
