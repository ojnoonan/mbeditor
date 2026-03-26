# TODO — mbeditor pre-release checklist

## Gem / packaging

- [x] Decide on initial version strategy — current `0.1.0` is fine for first release; bump to `1.0.0` when API is stable

## CI / release workflow

- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly
- [ ] `test.yml` — add Ruby 3.1, 3.2, 3.3 matrix entries; gemspec declares `>= 3.0.0` but only Ruby 3.0 is tested

## Security

- [ ] `grep --exclude-dir` fallback (`editors_controller.rb` ~line 211) — `--exclude-dir=#{dir_name}` uses string interpolation; validate `dir_name` against `/\A[\w.\/-]+\z/` for defense-in-depth (admin-configured value, but good practice)

## Nice to have (post-release)

- [ ] Markdown preview — `dangerouslySetInnerHTML` with `marked.parse()` blocks raw HTML via custom renderer but does not block `javascript:` scheme in links/images (`EditorPanel.js` line 468); low practical risk since only local files are rendered, but worth hardening
- [ ] `Configuration` — validate `workspace_root` is not nil/blank at startup with a clear `ArgumentError` rather than crashing on first file access
