# TODO — mbeditor

## CI / release workflow

- [ ] `test.yml` — add a Rails 8.x matrix entry; gemspec declares `< 9.0` but only Rails 7.1 and default (latest) are tested explicitly
- [ ] `test.yml` — add Ruby 3.1, 3.2, 3.3 matrix entries; gemspec declares `>= 3.0.0` but only Ruby 3.0 is tested

## Security

- [ ] `grep --exclude-dir` fallback (`editors_controller.rb` ~line 211) — `--exclude-dir=#{dir_name}` uses string interpolation; validate `dir_name` against `/\A[\w.\/-]+\z/` for defense-in-depth (admin-configured value, but good practice)
- [ ] Git diff/blame/history ref validation (`git_controller.rb` lines 29-30) — the allowed regex includes `@`, which permits reflog syntax like `@{-1}`; exclude `@` or add an explicit blocklist for reflog patterns

## Configuration

- [ ] `configuration.rb` — `workspace_root` is not validated at startup; a nil/blank value crashes on first file access with an unhelpful error; raise `ArgumentError` in an `after_initialize` hook instead
- [ ] `editors_controller.rb` line 18 — `RUBOCOP_TIMEOUT_SECONDS = 15` is hardcoded; move to `config.lint_timeout` so users with slow systems or extensive RuboCop rule sets can adjust it

## Missing tests

- [ ] `TestRunnerService` — no test file exists; at minimum cover `detect_framework`, `test_file?`, and `test_file_candidates` (pure/side-effect-free); also cover the `nil` framework fallback path (`detect_framework` falls through without returning when neither minitest nor rspec is detected)
- [ ] `raw` endpoint — no test for the 413 response when a file exceeds 5 MB; the `show` endpoint has this coverage but `raw` does not (`editors_controller.rb` lines 100-109)
- [ ] Search length boundary — the 500-character query cap is tested for the over-limit case but not at the boundary (499, 500, 501 chars)
- [ ] Symlink edge cases in write operations — `save`, `create_file`, and `rename` use `File.expand_path` (not `realpath`) for new paths; no tests verify that a parent directory which is a symlink pointing outside the workspace is rejected

## Quality / robustness

- [ ] `parse_porcelain_status` (`editors_controller.rb` ~line 738) — slices lines with `[3..]` without checking length first; malformed or empty git output lines will raise `NoMethodError`; add a length guard
- [ ] `redmine_service.rb` — Redmine configuration is only validated when `call` is first invoked, not at startup; misconfiguration goes undetected until a request is made; validate in an `after_initialize` block when `redmine_enabled` is true
- [ ] `git_blame_service.rb` lines 56-82 — blame parsing relies on implicit line ordering from `git blame --porcelain`; if the file ends mid-entry (e.g. file with no trailing newline plus edge case in git version), the final `current` block may be added with missing fields; add a completeness guard before appending

## Nice to have

- [ ] Markdown preview (`EditorPanel.js` line 468) — `dangerouslySetInnerHTML` with `marked.parse()` blocks raw HTML via custom renderer but does not sanitise `javascript:` scheme in links/images; low practical risk since only local files are rendered, but worth hardening with a `href` sanitiser pass
