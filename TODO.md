# TODO — mbeditor pre-release checklist

## Gem / packaging

- [x] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable

## CI / release workflow

- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly

## Nice to have (post-release)

- [x] Sanitize search results — indicate when results are capped at the 30-result limit
- [x] Apply `MAX_OPEN_FILE_SIZE_BYTES` on write too, not just read
- [x] Theme config option (currently hardcoded to `vs-dark`)
- [x] Monaco lazy-load — worker splitting: TypeScript/JavaScript routed to dedicated `ts_worker.js`
- [x] Memoize `rubocop_available?` and `haml_lint_available?` at the process level (currently spawn subprocesses on every `GET /workspace`)
- [x] `_latestContent` stored as property on the Monaco editor object (`EditorPanel.js`) — use a `useRef` instead
- [x] Add a settings page to allow users to configure editor preferences (tabs/spaces, font size, theme)
