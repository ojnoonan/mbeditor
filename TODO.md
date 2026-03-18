# TODO — mbeditor pre-release checklist

## Release blockers

- [x] Add `LICENSE` file (gemspec declares MIT but no file exists)
- [ ] Add `CHANGELOG.md`
- [ ] Verify gemspec author email before publishing — currently set to `s3660457@student.rmit.edu.au`

## Gem / packaging

- [ ] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable

## Documentation

- [ ] README: keyboard shortcut reference (`Ctrl+P` quick-open, `Ctrl+S` save)
- [ ] README: document all `config` options with their defaults (partially done — verify completeness)

## Nice to have (post-release)

- [ ] Sanitize search results — indicate when results are capped at the 30-result limit
- [ ] Apply `MAX_OPEN_FILE_SIZE_BYTES` on write too, not just read
- [ ] UI help/shortcut dialog so keyboard shortcuts are discoverable
- [ ] Theme config option (currently hardcoded to `vs-dark`)
- [ ] Monaco lazy-load — investigate worker splitting to improve initial load time
