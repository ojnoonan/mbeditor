# Ruby Test Syntax and Outline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Rails/Minitest and RSpec files meaningful Ruby test-DSL highlighting and include suites and runnable tests in the existing Jump to Method panel.

**Architecture:** Keep Monaco models on the `ruby` language ID. Build a pure ES5 `RubyOutline` parser that consumes current Monaco lines and returns `{ entries, truncated }`, extend the existing Ruby Monarch grammar with standard test-DSL token families, then adapt `EditorPanel` to render the outline without backend requests or test execution.

**Tech Stack:** Ruby 3+, Rails 7.1–8.x, Minitest, MiniRacer, plain ES5 JavaScript, React without JSX, Monaco, Sprockets, Cuprite.

## Global Constraints

- Application JavaScript has no build step and must remain ES5-compatible: no `let`, `const`, arrow functions, optional chaining, nullish coalescing, modules, or JSX.
- Test/spec Monaco models must retain language ID `ruby`.
- `RubyOutline.parse(lines, { path })` returns `{ entries: Entry[], truncated: boolean }`.
- Every entry contains `line`, `name`, `kind`, `depth`, and `visibility`.
- `kind` is exactly `method`, `suite`, or `test`.
- `visibility` is exactly `public`, `protected`, `private`, or `null`.
- Test-specific outline entries are path-gated using the same `_test.rb` and `_spec.rb` conventions as `TestRunnerService.test_file?`.
- The parser must not evaluate Ruby or make backend requests.
- The parser must ignore comments, strings, regexes, percent literals, and heredocs as structural source.
- The parser emits at most 5,000 entries and reports truncation.
- The existing Claude Ruby-outline visibility behavior must be preserved.
- Do not merge or copy unrelated drag-and-drop worktree changes.
- Follow TDD for every task: add a failing test, run it and confirm the expected failure, then write production code.
- Do not edit generated files under `public/monaco-editor/`.
- Existing SafePath and other unrelated working-tree changes must remain untouched.

---

### Task 1: Shared Ruby outline parser

**Files:**
- Create: `app/assets/javascripts/mbeditor/ruby_outline.js`
- Create: `test/lib/mbeditor/ruby_outline_test.rb`
- Modify: `app/assets/javascripts/mbeditor/application.js:13-24`

**Interfaces:**
- Consumes: `lines: string[]`, `options.path: string`
- Produces: `window.RubyOutline.parse(lines, options) -> { entries: Entry[], truncated: boolean }`
- Produces: `window.RubyOutline.isTestPath(path) -> boolean`
- `Entry -> { line: number, name: string, kind: "method"|"suite"|"test", depth: number, visibility: "public"|"protected"|"private"|null }`

- [ ] **Step 1: Create the MiniRacer harness and first failing API test**

Create `test/lib/mbeditor/ruby_outline_test.rb` with a `MiniRacer::Context`, `var window = this`, and evaluation of `app/assets/javascripts/mbeditor/ruby_outline.js`. Add a test that parses:

```ruby
class UserTest
  private
  def helper
  end

  test "is valid" do
  end
end
```

Assert the exact result:

```ruby
{
  "entries" => [
    { "line" => 3, "name" => "helper", "kind" => "method",
      "depth" => 0, "visibility" => "private" },
    { "line" => 6, "name" => "is valid", "kind" => "test",
      "depth" => 0, "visibility" => nil }
  ],
  "truncated" => false
}
```

- [ ] **Step 2: Run the parser test and verify RED**

Run:

```bash
bundle exec rake test TEST=test/lib/mbeditor/ruby_outline_test.rb
```

Expected: error or failure because `ruby_outline.js` or `RubyOutline.parse` does not exist. A load failure for MiniRacer itself is not the expected RED; install/use the existing bundle and rerun.

- [ ] **Step 3: Add complete failing parser coverage**

Before production code, add focused tests for:

- public/protected/private transitions and nested class/module scopes;
- `def self.name` and `class << self`;
- `def test_name`;
- Rails `test` with single quotes, double quotes, parentheses, braces, and an eight-line-bounded multiline header;
- `describe`, `context`, `feature`, `RSpec.describe`, `it`, `specify`, `example`, and `scenario`;
- nested suite depth;
- dynamic/interpolated/symbol descriptions using `test at line N` or `suite at line N`;
- false matches in comments, strings, slash regexes, percent literals, block comments, and heredocs;
- non-test paths containing `test`, `context`, and `it` calls;
- malformed declarations skipped while later `def` entries survive;
- source ordering; and
- 5,001 definitions producing 5,000 entries and `truncated: true`.

Use a `parse(source, path: "test/models/user_test.rb")` helper. Run the file again and confirm the behavior tests fail because the implementation is absent.

- [ ] **Step 4: Implement `RubyOutline` minimally**

After RED is confirmed, implement a global ES5 module:

```javascript
var RubyOutline = (function () {
  var MAX_ENTRIES = 5000;

  function parse(lines, options) {
    // Return the exact result contract; scan source once; never evaluate Ruby.
    return { entries: [], truncated: false };
  }

  function isTestPath(path) {
    return false;
  }

  return { parse: parse, isTestPath: isTestPath };
})();

window.RubyOutline = RubyOutline;
```

Replace the empty body with the smallest lexer/parser that passes the tests. Reuse the algorithms from the Claude worktree's `ruby_outline.js` only after the RED run:

`/Users/olivernoonan/CopilotProjects/web-editor/.claude/worktrees/drag-drop-file-import-956885/app/assets/javascripts/mbeditor/ruby_outline.js`

Port its literal/comment/heredoc masking and visibility scope rules. Change its grouped output to the required flat entries. Add a test-file predicate equivalent to:

```javascript
/(^|\/)test\/.*_test\.rb$/.test(path) ||
/(^|\/)spec\/.*_spec\.rb$/.test(path) ||
/_test\.rb$/.test(path) ||
/_spec\.rb$/.test(path)
```

Track suite indentation in a stack. A declaration header may remain pending for at most eight lines. Stop emitting after 5,000 entries and return `truncated: true`.

- [ ] **Step 5: Register the asset**

In `app/assets/javascripts/mbeditor/application.js`, add:

```javascript
//= require mbeditor/ruby_outline
```

after `editor_plugins` and before `components/EditorPanel`.

- [ ] **Step 6: Verify GREEN and syntax**

Run:

```bash
bundle exec rake test TEST=test/lib/mbeditor/ruby_outline_test.rb
node --check app/assets/javascripts/mbeditor/ruby_outline.js
```

Expected: parser tests pass with zero failures/errors; Node syntax check exits 0.

- [ ] **Step 7: Self-review and commit**

Review only Task 1 files for accidental ES6 syntax, unrelated worktree content, incorrect path gating, and duplicated parsing paths. Then run:

```bash
git add app/assets/javascripts/mbeditor/ruby_outline.js \
  app/assets/javascripts/mbeditor/application.js \
  test/lib/mbeditor/ruby_outline_test.rb
git commit -m "feat: parse Ruby test outlines"
```

If Git metadata remains read-only, report the exact failure and leave the reviewed files unstaged.

---

### Task 2: Ruby test DSL tokenization

**Files:**
- Modify: `app/assets/javascripts/mbeditor/editor_plugins.js:994-1090`
- Modify: `test/system/mbeditor/editor_test.rb`

**Interfaces:**
- Consumes: Monaco Ruby Monarch tokenizer
- Produces: non-generic tokens for runnable test, suite, and hook/helper DSL calls while retaining language ID `ruby`

- [ ] **Step 1: Write the failing browser token test**

In `EditorSystemTest`, add a test named `ruby test DSL receives structural Monaco tokens`. Visit the editor, wait for Monaco, and evaluate:

```javascript
window.monaco.editor.tokenize(
  'test "works" do\nRSpec.describe User do\nit "passes" do\nbefore do\nlet(:user) { User.new }',
  'ruby'
)
```

Flatten the returned tokens to `{ text, type }` records using each token's
`offset` and the next token offset. Assert:

- model/tokenizer language remains `ruby`;
- `test`, `describe`, and `it` do not have an empty or `identifier.ruby` token;
- `before` and `let` do not have an empty or `identifier.ruby` token; and
- a normal local identifier still receives the existing generic identifier token.

- [ ] **Step 2: Run the system test and verify RED**

Run:

```bash
bundle exec rake system_test \
  TEST=test/system/mbeditor/editor_test.rb \
  TESTOPTS='-n /ruby_test_DSL_receives_structural_Monaco_tokens/'
```

Expected: failure because the DSL words currently receive the generic Ruby identifier token.

- [ ] **Step 3: Add ordered Monarch rules**

In the Ruby tokenizer root, after class/module handling and before language literals/generic identifiers, add bounded word rules:

```javascript
[/\b(describe|context|feature)\b/, 'keyword.control.test'],
[/\b(test|it|specify|example|scenario)\b/, 'entity.name.function.test'],
[/\b(setup|teardown|before|after|around|subject)\b/, 'support.function.test'],
[/\blet!?(?=\s|\()/, 'support.function.test'],
```

Keep existing string handling unchanged. Do not register a `ruby-test` language or modify generated Monaco files.

- [ ] **Step 4: Verify GREEN and regression**

Run:

```bash
bundle exec rake system_test \
  TEST=test/system/mbeditor/editor_test.rb \
  TESTOPTS='-n /ruby_test_DSL_receives_structural_Monaco_tokens/'
node --check app/assets/javascripts/mbeditor/editor_plugins.js
```

Expected: targeted browser test passes; syntax check exits 0.

- [ ] **Step 5: Self-review and commit**

Confirm the new rules precede the generic identifier rule, use standard token prefixes, and do not change diagnostics configuration. Then run:

```bash
git add app/assets/javascripts/mbeditor/editor_plugins.js \
  test/system/mbeditor/editor_test.rb
git commit -m "feat: highlight Ruby test DSL"
```

If Git metadata remains read-only, report the exact failure and leave the reviewed files unstaged.

---

### Task 3: Test-aware Outline panel

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/EditorPanel.js:1630-1690,1820-1860,2020-2065`
- Modify: `app/assets/stylesheets/mbeditor/editor.css`
- Modify: `test/system/mbeditor/editor_test.rb`

**Interfaces:**
- Consumes: `RubyOutline.parse(lines, { path }) -> { entries, truncated }`
- Produces: ordinary `Methods` panel for Ruby files and test-aware `Outline` panel for `_test.rb`/`_spec.rb`

- [ ] **Step 1: Add failing Minitest and RSpec system fixtures**

In `EditorSystemTest#setup`, create:

```ruby
FileUtils.mkdir_p(File.join(@workspace, "test", "models"))
FileUtils.mkdir_p(File.join(@workspace, "spec", "models"))
File.write(File.join(@workspace, "test", "models", "user_test.rb"), <<~RUBY)
  class UserTest
    private
    def helper
    end

    test "is valid" do
    end
  end
RUBY
File.write(File.join(@workspace, "spec", "models", "user_spec.rb"), <<~RUBY)
  RSpec.describe User do
    context "when active" do
      it "is valid" do
      end
    end
  end
RUBY
```

Add one system test asserting:

- ordinary `nested_example.rb` shows the current `Methods` label;
- `user_test.rb` shows `Outline`, `helper`, and `is valid`;
- the private visibility header remains present;
- `user_spec.rb` shows `User`, `when active`, and `is valid`;
- nested rows have increasing depth classes/data attributes;
- selecting `is valid` sets the Monaco cursor to its declaration line; and
- adding an unsaved `test "new case" do` block through Monaco causes it to appear after closing and reopening Outline.

- [ ] **Step 2: Run the system test and verify RED**

Run:

```bash
bundle exec rake system_test \
  TEST=test/system/mbeditor/editor_test.rb \
  TESTOPTS='-n /test_aware_Outline_panel/'
```

Expected: failure because the toolbar still says Methods and `EditorPanel` still uses its local `def` regex.

- [ ] **Step 3: Replace the local method parser**

Change `parseRubyMethods(model)` to collect Monaco lines and call:

```javascript
function parseRubyOutline(model, path) {
  var lines = [];
  var lineCount = model.getLineCount();
  for (var i = 1; i <= lineCount; i++) {
    lines.push(model.getLineContent(i));
  }
  return window.RubyOutline.parse(lines, { path: path });
}
```

Compute whether the active path is a test/spec file using
`RubyOutline.isTestPath(tab.path)`. When the button opens, store
`result.entries` and `result.truncated`.

- [ ] **Step 4: Render typed entries**

Keep source order. Render:

- method entries with the existing method icon/row and visibility headers;
- suite entries with a group icon and `data-outline-depth`;
- test entries with a flask icon and `data-outline-depth`; and
- a non-selectable `Results truncated at 5,000 entries` row when required.

Use `Outline` as the visible label and `Jump to Outline` as the tooltip only for recognized test/spec paths. Ordinary Ruby files retain `Methods` and `Jump to Method`.

Every selectable row must preserve the existing navigation behavior:

```javascript
monacoRef.current.revealLineInCenter(entry.line);
monacoRef.current.setPosition({ lineNumber: entry.line, column: 1 });
monacoRef.current.focus();
```

Catch an unexpected parser exception and render `Outline unavailable` without unmounting the editor.

- [ ] **Step 5: Add focused styles**

Add only outline-specific classes:

- row kind/icon styling;
- indentation driven by `data-outline-depth` or an inline `paddingLeft`;
- existing sticky private/protected headers preserved; and
- a muted non-selectable truncation/error row.

Do not alter global Pico resets or unrelated editor layout.

- [ ] **Step 6: Verify GREEN**

Run:

```bash
bundle exec rake test TEST=test/lib/mbeditor/ruby_outline_test.rb
bundle exec rake system_test \
  TEST=test/system/mbeditor/editor_test.rb \
  TESTOPTS='-n /(ruby_test_DSL_receives_structural_Monaco_tokens|test_aware_Outline_panel)/'
node --check app/assets/javascripts/mbeditor/components/EditorPanel.js
```

Expected: parser and both focused browser tests pass; syntax check exits 0.

- [ ] **Step 7: Run broader regression**

Run:

```bash
bundle exec rake test
bundle exec rake system_test
```

Expected: zero failures/errors. If an unrelated baseline failure remains, identify it separately and prove the targeted feature tests still pass.

- [ ] **Step 8: Self-review and commit**

Review the complete feature against the design spec, confirm no Ruby language-ID changes or test-run buttons were added, and run:

```bash
git add app/assets/javascripts/mbeditor/components/EditorPanel.js \
  app/assets/stylesheets/mbeditor/editor.css \
  test/system/mbeditor/editor_test.rb
git commit -m "feat: show Ruby tests in editor outline"
```

If Git metadata remains read-only, report the exact failure and leave the reviewed files unstaged.
