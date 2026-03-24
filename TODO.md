# TODO — mbeditor pre-release checklist

## Release blockers

- [x] Add `LICENSE` file (gemspec declares MIT but no file exists)
- [x] Add `CHANGELOG.md`
- [x] `ensure_allowed_environment!` — reviewed; `render` in a `before_action` already halts the chain in Rails (checked via `performed?`), no fix needed
- [x] CSRF guard — added `before_action :verify_mbeditor_client` on all non-GET/HEAD requests; sets `X-Mbeditor-Client: 1` as a global Axios default in `file_service.js`

## Security

- [x] **Symlink path traversal in `resolve_path`** — `File.expand_path` normalises `..` segments but does **not** resolve symlinks. A symlink inside the workspace pointing outside it (e.g. `workspace/evil -> /etc/passwd`) would pass the `start_with?(root)` check and expose or overwrite the target. Fix: use `File.realpath` for the existence check (rescue `Errno::ENOENT`/`Errno::EACCES` when the path doesn't yet exist, i.e. on create). `editors_controller.rb:419`
- [x] **Upstream branch name interpolated into git revision range strings** — `upstream_branch` / `upstream` (obtained from `git rev-parse @{u}`) is string-interpolated into arguments like `"HEAD...#{upstream_branch}"` before being passed to `Open3.capture2`. No shell injection is possible because the array form is used, but a pathological branch name (e.g. containing `..`, spaces, or git reflog syntax) could cause git to misinterpret the range or error unexpectedly. Validate that the value matches a safe pattern (`\A[\w./-]+\z`) before use. `editors_controller.rb:275`, `git_controller.rb:132`
- [x] **`base_sha`/`head_sha` params in `GET /git/diff` are not validated** — `commit_detail` validates its SHA param with `/\A[0-9a-fA-F]{1,40}\z/` before use; the diff endpoint passes `params[:base]`/`params[:head]` directly to `GitDiffService`, which interpolates them into `"#{ref}:#{file_path}"` passed to `git show`. A crafted ref (e.g. containing `:`) could produce unexpected git output or trigger unintended ref lookups. Apply the same hex validation. `git_controller.rb:26-27`, `git_diff_service.rb:46-47`
- [x] **Redmine `issue_id` not validated as integer before URL interpolation** — `params[:id]` is taken as-is and interpolated into the Redmine URL as `/issues/#{issue_id}.json`. A non-numeric value (e.g. `../projects`) could manipulate the path within the configured Redmine base URL. Validate with `/\A\d+\z/` before calling the service. `redmine_service.rb:51`

## Gem / packaging

- [ ] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable
- [x] Check gem size before publishing — `public/monaco-editor/` is included in `spec.files`; Monaco is 20–40 MB. Run `bundle exec rake build && ls -lh pkg/` and verify it is under RubyGems.org's 250 MB limit (confirmed: 3.7 MB)

## Reliability

- [x] **`run_with_timeout` only kills the RuboCop parent process** — the timeout thread calls `Process.kill('KILL', wait_thr.pid)` which kills the direct child but not any grandchildren (e.g. processes spawned by Bundler or RuboCop plugins). On a slow CI box these become orphans and can accumulate. Fix: use a process group kill (`Process.kill('-KILL', ...)`) after setting a new process group via `pgroup: true` in `popen3`. `editors_controller.rb:475`
- [x] **`state` endpoint silently swallows all errors** — the `rescue StandardError` at line 63 returns `{}` for both "no file yet" (expected) and real errors like `Errno::EACCES` or `JSON::ParserError` (unexpected). Split the rescue: only return `{}` for `Errno::ENOENT`; re-raise or log everything else. `editors_controller.rb:56`

## Code quality

- [x] Dotfiles silently excluded from file tree — `build_tree` rejects all entries starting with `.`, hiding `.env`, `.rubocop.yml`, `.github/`, etc. Only `.git` is in `excluded_paths` by default; the blanket dotfile rejection is unintentional. Fix `editors_controller.rb:430`
- [x] Remove dead code — `ALLOWED_EXTENSIONS` constant (defined but never used) and `rename_path`/`delete_path` methods (defined but never routed)
- [x] `application.js` Sprockets load order — services are listed after components; should be before (works today only because all cross-references are inside function bodies, not at parse time)
- [x] `showGitPanel` in main `useEffect` dependency array (`MbeditorApp.js`) — causes the full setup effect (EditorStore subscription, workspace/tree fetch, state load, event listeners) to re-run every time the Git panel is toggled. Read `showGitPanel` via a ref inside the resize handler instead
- [x] **`focusedPane.id` accessed in useEffect dependency array without empty-panes guard** — `focusedPane` falls back to `state.panes[0]`, which is `undefined` if the panes array is transiently empty (e.g. during a full store reset). Accessing `.id` on `undefined` throws before the effect body runs, bypassing the `activeTab` guard inside the effect. Add `focusedPane ? focusedPane.id : null` in the dep array. `MbeditorApp.js:834`

## CI / release workflow

- [x] `publish.yml` — run `bundle exec rake system_test` before publishing so UI regressions don't ship
- [x] `publish.yml` — add a `gem push` step with `GEM_HOST_API_KEY` if distributing via RubyGems.org (currently only creates a GitHub Release)
- [x] `publish.yml` — `workflow_dispatch` trigger creates spurious releases without a version tag; add a `tag_name` input to the manual trigger
- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly

## Test gaps

- [x] **`GET /mbeditor/git/combined_diff` has zero tests** — the `combined_diff` action (both `scope=local` and `scope=branch` paths, and the missing-upstream fallback) is completely untested. `test/controllers/mbeditor/git_controller_test.rb`
- [x] **`resolve_path` symlink behaviour is untested** — once the symlink traversal fix is applied, add a test that creates a symlink pointing outside the workspace and asserts the endpoint returns 403.
- [x] **RuboCop timeout path is untested** — no test exercises the 15-second timeout branch in `run_with_timeout`; a slow/hanging command should return a timeout error, not hang the test suite.

## Documentation

- [x] README: keyboard shortcut reference (`Ctrl+P` quick-open, `Ctrl+S` save)
- [x] README: document all `config` options with their defaults (verified complete)
- [x] README: document that host apps using Propshaft are not supported (engine requires Sprockets)
- [x] README: ActionCable note removed — no ActionCable usage exists in the engine
- [x] README: document `excluded_paths` pattern semantics (simple names vs path prefixes)

## Nice to have (post-release)

- [ ] Sanitize search results — indicate when results are capped at the 30-result limit
- [ ] Apply `MAX_OPEN_FILE_SIZE_BYTES` on write too, not just read
- [ ] Theme config option (currently hardcoded to `vs-dark`)
- [ ] Monaco lazy-load — investigate worker splitting to improve initial load time
- [ ] Memoize `rubocop_available?` and `haml_lint_available?` at the process level (currently spawn subprocesses on every `GET /workspace`)
- [ ] `_latestContent` stored as property on the Monaco editor object (`EditorPanel.js`) — use a `useRef` instead
- [ ] Add a settings page to allow users to configuring their editor settings to how they like. Including things like tabs/spaces, font size, font, theme
