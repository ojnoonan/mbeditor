# TODO — mbeditor pre-release checklist

## Release blockers

- [ ] Add `LICENSE` file (gemspec declares MIT but no file exists)
- [ ] Add `CHANGELOG.md`
- [ ] Verify gemspec author email before publishing — currently set to `s3660457@student.rmit.edu.au`
- [ ] Add `.rubocop.yml` — rubocop is a dev dependency but no config file exists
- [ ] Add RuboCop step to CI — neither `test.yml` nor `publish.yml` runs rubocop

## Security

- [x] **XSS in Markdown preview** — custom `marked` renderer escapes raw HTML blocks
- [x] Null-safety on `output.index("{")` in lint endpoint — replaced `rescue nil` with explicit nil check
- [x] Path traversal prevention — `resolve_path` tested across all file operation endpoints

## Testing

- [x] Controller tests for all file I/O endpoints (show, raw, save, create_file, create_dir, rename, destroy_path)
- [x] Path traversal security tests — `resolve_path` blocks `../` escapes across every mutating endpoint
- [x] Environment gating test — non-allowed environment returns 404
- [x] State round-trip test (save_state + state)
- [x] Search, reload, workspace, ping, files endpoints covered
- [x] Smoke test — GET `/mbeditor` asserts HTML response
- [x] Tests for git endpoints (`git_status`, `git_info`) — non-git workspace exercises error handling
- [x] Tests for lint and format endpoints — path traversal and response structure covered
- [x] Tests for Monaco asset serving (`monaco_asset`, `monaco_worker`) — serves existing files, 404 for missing/traversal

## Code quality

- [x] Remove empty `app/helpers/mbeditor/editors_helper.rb`
- [x] Replace magic `rescue nil` JSON parse pattern with explicit nil check
- [x] Hardcoded `/tmp/rubocop` replaced with `Dir.tmpdir` (cross-platform)
- [x] Fix `delete tab.gotoLine` mutation in `EditorPanel.js.jsx`
- [x] Add `require "open3"` to controller (was implicit; caught by test suite)

## Gem / packaging

- [x] `spec.files` glob covers `public/**/*` (includes `public/min-maps/`) and `vendor/**/*` (includes webfonts)
- [x] `babel-transpiler` removed as a runtime dependency — JSX is pre-compiled to `mbeditor_components.js`
- [x] `build_js` Rake task skips gracefully when `build_js.js` is absent (CI-safe)
- [ ] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable

## CI / workflows

- [x] `test.yml` — runs `bundle exec rake test` on push/PR to main
- [x] `publish.yml` — runs tests, builds gem, creates GitHub Release on tag or manual dispatch
- [x] Actions pinned to Node.js 24-compatible versions (`actions/checkout@v6.0.2`, `ruby/setup-ruby@v1.292.0`)
- [ ] Add RuboCop step to `test.yml`

## Documentation

- [x] README: Node.js >= 18 documented as a development requirement
- [x] README: testing instructions (`bundle exec rake test`, single file, single test)
- [x] README: syntax highlighting language list
- [ ] README: keyboard shortcut reference (`Ctrl+P` quick-open, `Ctrl+S` save)
- [ ] README: document all `config` options with their defaults (partially done — verify completeness)

## Nice to have (post-release)

- [ ] Sanitize search results — indicate when results are capped at the 30-result limit
- [ ] Apply `MAX_OPEN_FILE_SIZE_BYTES` on write too, not just read
- [ ] UI help/shortcut dialog so keyboard shortcuts are discoverable
- [ ] Theme config option (currently hardcoded to `vs-dark`)
- [ ] Monaco lazy-load — investigate worker splitting to improve initial load time
