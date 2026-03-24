# TODO — mbeditor pre-release checklist

## Release blockers

- [x] Add `LICENSE` file (gemspec declares MIT but no file exists)
- [x] Add `CHANGELOG.md`
- [x] `ensure_allowed_environment!` — reviewed; `render` in a `before_action` already halts the chain in Rails (checked via `performed?`), no fix needed
- [x] CSRF guard — added `before_action :verify_mbeditor_client` on all non-GET/HEAD requests; sets `X-Mbeditor-Client: 1` as a global Axios default in `file_service.js`

## Gem / packaging

- [ ] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable
- [x] Check gem size before publishing — `public/monaco-editor/` is included in `spec.files`; Monaco is 20–40 MB. Run `bundle exec rake build && ls -lh pkg/` and verify it is under RubyGems.org's 250 MB limit (confirmed: 3.7 MB)

## Code quality

- [x] Dotfiles silently excluded from file tree — `build_tree` rejects all entries starting with `.`, hiding `.env`, `.rubocop.yml`, `.github/`, etc. Only `.git` is in `excluded_paths` by default; the blanket dotfile rejection is unintentional. Fix `editors_controller.rb:430`
- [x] Remove dead code — `ALLOWED_EXTENSIONS` constant (defined but never used) and `rename_path`/`delete_path` methods (defined but never routed)
- [x] `application.js` Sprockets load order — services are listed after components; should be before (works today only because all cross-references are inside function bodies, not at parse time)
- [x] `showGitPanel` in main `useEffect` dependency array (`MbeditorApp.js`) — causes the full setup effect (EditorStore subscription, workspace/tree fetch, state load, event listeners) to re-run every time the Git panel is toggled. Read `showGitPanel` via a ref inside the resize handler instead

## CI / release workflow

- [x] `publish.yml` — run `bundle exec rake system_test` before publishing so UI regressions don't ship
- [x] `publish.yml` — add a `gem push` step with `GEM_HOST_API_KEY` if distributing via RubyGems.org (currently only creates a GitHub Release)
- [x] `publish.yml` — `workflow_dispatch` trigger creates spurious releases without a version tag; add a `tag_name` input to the manual trigger
- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly

## Documentation

- [ ] README: keyboard shortcut reference (`Ctrl+P` quick-open, `Ctrl+S` save)
- [ ] README: document all `config` options with their defaults (partially done — verify completeness)
- [ ] README: document that host apps using Propshaft are not supported (engine requires Sprockets)
- [ ] README: document that the host app must mount `ActionCable.server => "/cable"` and add a `config/cable.yml` for collaborative editing to work
- [ ] README: document `excluded_paths` pattern semantics (simple names vs path prefixes)

## Nice to have (post-release)

- [ ] Sanitize search results — indicate when results are capped at the 30-result limit
- [ ] Apply `MAX_OPEN_FILE_SIZE_BYTES` on write too, not just read
- [ ] Theme config option (currently hardcoded to `vs-dark`)
- [ ] Monaco lazy-load — investigate worker splitting to improve initial load time
- [ ] Memoize `rubocop_available?` and `haml_lint_available?` at the process level (currently spawn subprocesses on every `GET /workspace`)
- [ ] `_latestContent` stored as property on the Monaco editor object (`EditorPanel.js`) — use a `useRef` instead
- [ ] Add a settings page to allow users to configuring their editor settings to how they like. Including things like tabs/spaces, font size, font, theme
