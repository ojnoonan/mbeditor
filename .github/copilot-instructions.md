# Project Guidelines

Mbeditor is a mountable Rails engine gem that provides a browser-based editor UI for local development.

## Architecture

- Backend is a Rails engine under `app/controllers/mbeditor/` and `app/services/mbeditor/`.
- Frontend is plain JavaScript + React + Monaco under `app/assets/javascripts/mbeditor/`.
- There is no frontend build pipeline in normal development; edit committed JS assets directly.

## Build and Test

Run commands from the repository root unless noted:

- `bundle install`
- `bundle exec rake test`
- `bundle exec rake system_test`
- `bundle exec rake build_js`
- `cd test/dummy && rails server` (manual smoke testing at `/mbeditor`)

## Security-Critical Rules

- Treat path safety as non-negotiable: path-based operations must use `resolve_path` protections.
- Non-GET/HEAD write operations must enforce `X-Mbeditor-Client: 1` (`verify_mbeditor_client`).
- Validate git ref names against `SAFE_GIT_REF` before shell interpolation.

## Conventions

- Keep controllers thin and move git/business logic to services in `app/services/mbeditor/`.
- Follow existing service patterns (class services with `call`, or module functions in `GitService`).
- Preserve current API shapes and response formats unless a task explicitly requires changes.
- Prefer minimal, targeted diffs; avoid broad refactors in this codebase.

## Testing Gotchas

- `WebMock.disable_net_connect!` is globally active in tests; stub external HTTP requests.
- `editors_controller_test.rb` uses a temporary workspace (`Dir.mktmpdir`).
- `git_controller_test.rb` and service tests execute against the real project git repo.

## References

- Architecture, security invariants, CI notes: `CLAUDE.md`
- Installation/configuration/feature behavior: `README.md`
- Open engineering gaps and hardening tasks: `TODO.md`
