# TODO — mbeditor

## CI / release workflow

- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly

## Security

- [ ] CSRF protection relies solely on `X-Mbeditor-Client: 1` header (`editors_controller.rb` line 10) — `skip_before_action :verify_authenticity_token` disables Rails CSRF entirely; a forged cross-origin request from an attacker-controlled page running in the same browser could include this header via a custom fetch; consider keeping CSRF token validation or at least verifying `Origin`/`Referer` against the host

## Configuration

- [ ] `editors_controller.rb` line 18 — `RUBOCOP_TIMEOUT_SECONDS = 15` is hardcoded; move to `config.lint_timeout` so users with slow systems or extensive RuboCop rule sets can adjust it
- [ ] `git_controller.rb` line ~208 — base branch candidates (`origin/develop`, `origin/main`, etc.) are hardcoded; teams with non-standard conventions get wrong results; expose as `config.base_branch_candidates`

## Quality / robustness

- [ ] `redmine_service.rb` — Redmine configuration is only validated when `call` is first invoked, not at startup; misconfiguration goes undetected until a request is made; validate in an `after_initialize` block when `redmine_enabled` is true
- [ ] `git_controller.rb` `combined_diff` (lines 141-147) — when `scope=branch` and the branch has no upstream configured, the endpoint returns `{diff: ""}` identically to an empty diff; the frontend cannot distinguish "no changes" from "no upstream set"; return a distinct key (e.g. `no_upstream: true`) so the UI can surface a helpful message
- [ ] `editors_controller.rb` ~lines 508, 572 — tmpfile path for RuboCop/HAML fix operations is constructed manually with `SecureRandom.hex`; use `Tempfile.create` instead to avoid the unlikely but possible collision and to ensure cleanup on unexpected exits
- [ ] `editors_controller.rb` workspace state file (`tmp/mbeditor_workspace.json`) — written without file locking; concurrent requests from multiple browser tabs can produce interleaved writes and corrupt JSON; use an advisory lock (`File.flock`) around read-modify-write
- [ ] `editors_controller.rb` `state` action (line 56) — a corrupted `mbeditor_workspace.json` returns a 422 error response instead of falling back to `{}`; add an explicit `rescue JSON::ParserError` before the outer `rescue StandardError` and return `render json: {}` to match the missing-file behaviour
- [ ] `git_service.rb` — `parse_git_log` and `parse_git_log_with_parents` share nearly identical structure but are maintained separately; extract a shared private method parameterised by whether parents are included
- [ ] `ruby_definition_service.rb` (line 41) — `Find.find(@workspace_root)` traverses the entire workspace with no file-count or byte-size cap; on a very large monorepo this blocks the Puma thread for several seconds and may exhaust memory; add an early-exit guard (e.g. bail after scanning N files) or run in a background thread with a timeout

## Frontend

- [ ] `file_service.js` and `git_service.js` both define an identical `basePath()` helper (lines 6-8 in each); if `MBEDITOR_BASE_PATH` changes the path logic must be updated in two places; extract to a shared module or inline constant
- [ ] `editor_store.js` `subscribeToSlice` — uses `===` to detect state changes; object slices are compared by reference, so in-place mutations to nested state will not trigger subscriber callbacks; document (or enforce) that all state updates must produce a new object reference
- [ ] `GitPanel.js` line ~18 — `expandedCommits` is component-local state and resets on every page load; for large repos users repeatedly expand the same commits; persist to `localStorage` keyed by repo path

## Nice to have

- [ ] Markdown preview (`EditorPanel.js` line 468) — `dangerouslySetInnerHTML` with `marked.parse()` blocks raw HTML via custom renderer but does not sanitise `javascript:` scheme in links/images; low practical risk since only local files are rendered, but worth hardening with a `href` sanitiser pass
