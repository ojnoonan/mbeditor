# TODO — mbeditor pre-release checklist

## Release blockers

- [ ] Add `LICENSE` file (gemspec declares MIT but no file exists)
- [ ] Add `CHANGELOG.md`
- [ ] Verify gemspec author name/email before publishing to RubyGems
- [ ] Add `.rubocop.yml` — rubocop is a dev dependency but no config file exists
- [ ] Add GitHub Actions CI workflow (`.github/workflows/ci.yml`) to run rubocop on push

## Security

- [x] **XSS in Markdown preview** — custom `marked` renderer now escapes raw HTML blocks instead of injecting them
- [x] Null-safety on `output.index("{")` in lint endpoint — replaced `rescue nil` with explicit nil check

## Testing

- [ ] Add controller tests for all endpoints (file read/write, git, search, lint, format, monaco asset serving)
- [ ] Add path traversal security test — confirm `resolve_path` blocks `../` escapes
- [ ] Add a basic smoke test that the engine mounts and renders in the dummy app

## Code quality

- [x] Remove or implement the empty `app/helpers/mbeditor/editors_helper.rb` — deleted
- [x] Replace magic `rescue nil` pattern (`json_str = output[output.index("{")..]`) with explicit nil check — done in security pass
- [x] Hardcoded `RUBOCOP_CACHE_ROOT=/tmp/rubocop` — replaced with `Dir.tmpdir` (cross-platform)
- [x] Fix `delete tab.gotoLine` mutation in `EditorPanel.js.jsx` — added `TabManager.clearGotoLine(paneId, path)`, exposed via TabManager public API, `paneId` prop added to EditorPanel

## Gem / packaging

- [ ] Confirm `spec.files` glob in gemspec includes `test/dummy/public/webfonts/` and `public/min-maps/` (both added during development)
- [ ] Decide on initial version strategy — current `0.1.0` is fine for a first release; bump to `1.0.0` when API is considered stable
- [ ] Verify `babel-transpiler` + `execjs` work in a clean install (ExecJS needs a JS runtime — document Node.js as a host requirement)

## Documentation

- [ ] README: document the JS runtime requirement (Node.js, for Babel/ExecJS during asset compilation)
- [ ] README: note that host apps need `public/webfonts/` fonts for FontAwesome (or document the correct setup)
- [ ] Add keyboard shortcut reference to README (`Ctrl+P` quick-open, `Ctrl+S` save)
- [ ] Document all `config` options with their defaults in README (already partially done — verify completeness)

## Nice to have (post-release)

- [ ] Sanitize search results count — indicate when results are capped at the 30-result limit
- [ ] Save file size limit should apply on write too, not just read (currently only `MAX_OPEN_FILE_SIZE_BYTES` on open)
- [ ] Add a UI help/shortcut dialog so keyboard shortcuts are discoverable
- [ ] Theme config option (currently hardcoded to `vs-dark`)
- [ ] Monaco lazy-load — the full editor bundle is large; investigate worker splitting to improve initial load
