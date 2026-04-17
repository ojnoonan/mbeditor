# TODO — mbeditor

## CI / release workflow

- [x] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly
- [x] `test.yml` — add Ruby 3.1, 3.2, 3.3 matrix entries; gemspec declares `>= 3.0.0` but only Ruby 3.0 is tested
- [x] Add security scanning to CI — no Brakeman or `bundler-audit` step in `test.yml`; static analysis would catch several of the issues below automatically

## Security

- [x] `grep --exclude-dir` fallback (`editors_controller.rb` ~line 211) — `--exclude-dir=#{dir_name}` uses string interpolation; validate `dir_name` against `/\A[\w.\/-]+\z/` for defense-in-depth (admin-configured value, but good practice)
- [x] Git diff/blame/history ref validation (`git_controller.rb` lines 29-30) — the allowed regex includes `@`, which permits reflog syntax like `@{-1}`; exclude `@` or add an explicit blocklist for reflog patterns
- [x] Class-level binary probe caches (`editors_controller.rb` lines 696-732) — `rubocop_available?`, `haml_lint_available?`, and `git_available?` use a `get || set` pattern on class instance variables that is not atomic; under concurrent Puma workers, multiple threads can bypass the `cache.key?(key)` guard simultaneously and spawn duplicate `--version` subprocesses; wrap with a `Mutex` or use `||=` inside `Mutex#synchronize`
- [x] Redmine SSL verification (`redmine_service.rb` line ~59) — `Net::HTTP` HTTPS connection does not set `http.verify_mode = OpenSSL::SSL::VERIFY_PEER`; in some Ruby configurations peer certificates are not verified, exposing the API key to MITM interception
- [x] Redmine URL scheme not validated (`redmine_service.rb` lines 42-54) — `redmine_url` is only checked for blankness; a non-HTTP/S value (e.g. `file:///etc/passwd`) makes `uri.host` return `nil`, crashing with `NoMethodError`; validate that the scheme is `http` or `https` in the config validator
- [ ] CSRF protection relies solely on `X-Mbeditor-Client: 1` header (`editors_controller.rb` line 10) — `skip_before_action :verify_authenticity_token` disables Rails CSRF entirely; a forged cross-origin request from an attacker-controlled page running in the same browser could include this header via a custom fetch; consider keeping CSRF token validation or at least verifying `Origin`/`Referer` against the host
- [x] `save_state` unconstrained payload size (`editors_controller.rb` line 69) — `params[:state].to_json` is written to disk with no size check; a runaway frontend or malicious request could fill available disk space; add a cap (e.g. 1 MB) and return 413 if exceeded

## Configuration

- [x] `configuration.rb` — `workspace_root` is not validated at startup; a nil/blank value crashes on first file access with an unhelpful error; raise `ArgumentError` in an `after_initialize` hook instead
- [x] `editors_controller.rb` line 18 — `RUBOCOP_TIMEOUT_SECONDS = 15` is hardcoded; move to `config.lint_timeout` so users with slow systems or extensive RuboCop rule sets can adjust it
- [x] `git_controller.rb` line ~208 — base branch candidates (`origin/develop`, `origin/main`, etc.) are hardcoded; teams with non-standard conventions get wrong results; expose as `config.base_branch_candidates`
- [x] `git_service.rb` — git subprocess calls via `Open3.capture3` have no timeout; a hung git process (waiting for credentials, slow network remote) blocks the Puma thread indefinitely; add a configurable `config.git_timeout` and wrap `run_git` with `Timeout.timeout`

## Missing tests

- [x] `TestRunnerService` — no test file exists; at minimum cover `detect_framework`, `test_file?`, and `test_file_candidates` (pure/side-effect-free); also cover the `nil` framework fallback path (`detect_framework` falls through without returning when neither minitest nor rspec is detected)
- [x] `raw` endpoint — no test for the 413 response when a file exceeds 5 MB; the `show` endpoint has this coverage but `raw` does not (`editors_controller.rb` lines 100-109)
- [x] Search length boundary — the 500-character query cap is tested for the over-limit case but not at the boundary (499, 500, 501 chars)
- [x] Symlink edge cases in write operations — `save`, `create_file`, and `rename` use `File.expand_path` (not `realpath`) for new paths; no tests verify that a parent directory which is a symlink pointing outside the workspace is rejected
- [x] Path traversal coverage gaps — only a few endpoints (`show`, `raw`, `diff`, `blame`) have explicit traversal tests; `save`, `create_file`, `create_dir`, `rename` (both old and new paths), `delete`, `lint`, and `format` are untested for `../../` style inputs
- [x] `git_blame_service_test.rb` does not exist — cover porcelain output parsing, the final-block completeness guard, and behavior on a file with no trailing newline
- [x] `git_file_history_service_test.rb` does not exist — cover `--follow` rename tracking and empty history (new file with no commits)
- [x] `git_commit_graph_service_test.rb` does not exist — cover `isLocal` flag logic, merge commits (multiple parents), and the 150-commit cap
- [x] No tests exercise git service behavior when the `git` binary is absent or the repo is in a broken state (detached HEAD, shallow clone, missing objects)
- [x] `ruby_definition_service_test.rb` — no test for the `excluded_paths` parameter; the service accepts both `excluded_dirnames` and `excluded_paths` but only the former is exercised in tests; add cases for path-prefix exclusion and basename exclusion via `excluded_paths`
- [x] `editors_controller_test.rb` `save_state` — no test for an oversized payload; once a size cap is added (see Security section) a 413 test should accompany it
- [x] `monaco_asset` and `monaco_worker` endpoints (`editors_controller.rb` lines 412-427) — no test coverage for traversal attempts (`..%2F..%2F`), missing-asset 404 fallback, or the Rails.root override path; these are user-reachable and deserve at least a happy-path + traversal test

## Quality / robustness

- [x] `parse_porcelain_status` (`editors_controller.rb` ~line 738) — slices lines with `[3..]` without checking length first; malformed or empty git output lines will raise `NoMethodError`; add a length guard; also switch from `.map` to `.filter_map` (with a `next if path.blank?` guard) to match the defensive pattern used in `parse_name_status`
- [x] `git_status` action (`editors_controller.rb` line 296) — inline mapping uses `line[3..].strip` without `.to_s`; unlike `parse_porcelain_status` (line 876) which guards with `.to_s.strip`, this will raise `NoMethodError` on any line shorter than 3 characters; use the existing `parse_porcelain_status` helper instead of duplicating the logic
- [x] `redmine_service.rb` — Redmine configuration is only validated when `call` is first invoked, not at startup; misconfiguration goes undetected until a request is made; validate in an `after_initialize` block when `redmine_enabled` is true
- [x] `git_blame_service.rb` lines 56-82 — blame parsing relies on implicit line ordering from `git blame --porcelain`; if the file ends mid-entry (e.g. file with no trailing newline plus edge case in git version), the final `current` block may be added with missing fields; add a completeness guard before appending
- [x] `git_controller.rb` `combined_diff` (lines 141-147) — when `scope=branch` and the branch has no upstream configured, the endpoint returns `{diff: ""}` identically to an empty diff; the frontend cannot distinguish "no changes" from "no upstream set"; return a distinct key (e.g. `no_upstream: true`) so the UI can surface a helpful message
- [x] `editors_controller.rb` ~lines 508, 572 — tmpfile path for RuboCop/HAML fix operations is constructed manually with `SecureRandom.hex`; use `Tempfile.create` instead to avoid the unlikely but possible collision and to ensure cleanup on unexpected exits
- [x] `editors_controller.rb` workspace state file (`tmp/mbeditor_workspace.json`) — written without file locking; concurrent requests from multiple browser tabs can produce interleaved writes and corrupt JSON; use an advisory lock (`File.flock`) around read-modify-write
- [x] `editors_controller.rb` ~line 226 — `JSON.parse(line) rescue next` in the search results loop silently discards malformed lines with no logging; add a `Rails.logger.warn` so encoding or format regressions are observable
- [x] `editors_controller.rb` `state` action (line 56) — a corrupted `mbeditor_workspace.json` returns a 422 error response instead of falling back to `{}`; add an explicit `rescue JSON::ParserError` before the outer `rescue StandardError` and return `render json: {}` to match the missing-file behaviour
- [x] `git_service.rb` — `parse_git_log` and `parse_git_log_with_parents` share nearly identical structure but are maintained separately; extract a shared private method parameterised by whether parents are included
- [x] `ruby_definition_service.rb` (line 41) — `Find.find(@workspace_root)` traverses the entire workspace with no file-count or byte-size cap; on a very large monorepo this blocks the Puma thread for several seconds and may exhaust memory; add an early-exit guard (e.g. bail after scanning N files) or run in a background thread with a timeout
- [x] `find_branch_base` duplicated between `editors_controller.rb` (lines 1008-1033) and `git_controller.rb` (lines 207-232) — nearly identical implementations drifted copies; extract to `GitService.find_branch_base(repo, current_branch)` and call from both locations so candidate-ref logic is maintained in one place
- [x] `parse_numstat` duplication — `editors_controller.rb` defines `parse_numstat` (lines 973-980) while `git_controller.rb` `commit_detail` re-implements the same parser inline (lines 91-98); move to `GitService.parse_numstat` and consume from both controllers
- [x] `parse_git_log` duplicated between `GitService.parse_git_log` (git_service.rb lines 72-84) and `EditorsController#parse_git_log` (editors_controller.rb lines 982-994); the service version returns string keys while the controller version returns symbol keys, so output shape diverges depending on which path is used; unify on one implementation (pick symbol or string keys repo-wide) and delete the other
- [x] `git_commit_graph_service.rb` references `Set` (lines 50, 53, 55, 57) without `require "set"` — works on Ruby 3.2+ where Set is autoloaded, but fails on Ruby 3.0/3.1 (both supported by the gemspec's `>= 3.0.0`); add `require "set"` at the top of the file
- [x] `RubyDefinitionService` file cache is unbounded (`ruby_definition_service.rb` class ivar `@file_cache`) — grows with every unique `.rb` file visited and is persisted to disk via `persist_cache`; on a long-lived large workspace the JSON file and in-memory hash grow without eviction; add a max-entry cap and/or LRU eviction, or clear entries whose files have been deleted during load
- [x] `prune_branch_states` (`editors_controller.rb` lines 107-123) — read-modify-write on `tmp/mbeditor_branch_states.json` with no `File.flock`; same concurrent-write corruption risk as the workspace state file already flagged under Quality

## Frontend

- [x] `MBEDITOR_BASE_PATH` basePath helper is inlined in seven places (`file_service.js:32`, `git_service.js:3`, `search_service.js:5`, `tab_manager.js:260`, `components/GitPanel.js:58`, `components/EditorPanel.js:1195`, `components/CodeReviewPanel.js:30`) — some use `.replace(/\/$/, '')`, `CodeReviewPanel.js` skips the trim, so behaviour drifts; extract to a single shared helper (e.g. `window.mbeditorBasePath()`) and replace all inline copies
- [x] `EditorStore.setStatus` (`editor_store.js` lines 57-68) schedules a 4 s `setTimeout` for every non-error message but never clears prior timers; rapid status updates leave many pending timeouts queued, each rechecking `_state.statusMessage.text` — low leak but wasteful; store the last timer id on module scope and `clearTimeout` before scheduling a new one
- [x] `editor_store.js` `subscribeToSlice` — uses `===` to detect state changes; object slices are compared by reference, so in-place mutations to nested state will not trigger subscriber callbacks; document (or enforce) that all state updates must produce a new object reference
- [x] `GitPanel.js` line ~18 — `expandedCommits` is component-local state and resets on every page load; for large repos users repeatedly expand the same commits; persist to `localStorage` keyed by repo path

## Nice to have

- [x] Markdown preview (`EditorPanel.js` line 468) — `dangerouslySetInnerHTML` with `marked.parse()` blocks raw HTML via custom renderer but does not sanitise `javascript:` scheme in links/images; low practical risk since only local files are rendered, but worth hardening with a `href` sanitiser pass
- [x] No global axios timeout configured (`file_service.js`, `git_service.js`, `search_service.js`) — only `ping` has a per-request timeout (4 s); all other API calls can hang indefinitely if the Rails server is unresponsive; set `axios.defaults.timeout` once in `file_service.js` (where axios is already globally configured) to cap all requests
