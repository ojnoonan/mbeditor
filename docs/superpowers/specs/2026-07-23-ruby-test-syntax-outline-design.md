# Ruby Test Syntax and Outline — Design

**Date:** 2026-07-23
**Status:** Design approved, pending written-spec review

## Problem

Mbeditor assigns `_test.rb` and `_spec.rb` files the correct Monaco `ruby`
language ID, but its Ruby tokenizer does not distinguish common testing DSL
calls from ordinary identifiers. Rails/Minitest `test` declarations and RSpec
suite/example declarations therefore lack useful structural highlighting.

The Jump to Method panel has a separate gap. Its current parser recognizes only
lines beginning with `def`, so macro-defined tests are absent. In
`test/system/mbeditor/editor_test.rb`, for example, the parser finds nine
ordinary methods and misses all 26 `test "..." do` definitions.

A Claude worktree already contains an uncommitted extraction of the method
parser into a tested `RubyOutline` module, including visibility grouping. That
work is useful foundation, but it still recognizes only `def` and shares a
worktree with unrelated drag-and-drop changes.

## Goals

- Give Rails/Minitest and RSpec DSL calls meaningful Ruby syntax highlighting.
- Include test suites and runnable test definitions in the Ruby jump panel.
- Parse the current unsaved Monaco buffer without a backend request.
- Preserve the existing Ruby language ID and all Ruby LSP, formatting,
  completion, and diagnostic integrations.
- Preserve ordinary method navigation and the Claude worktree's
  private/protected visibility behavior.
- Produce a reusable, testable outline model that the later Test Workbench may
  consume without coupling this feature to test execution.

## Non-goals

- Test discovery across the workspace.
- Running tests from the outline.
- Displaying pass/fail state, duration, or coverage.
- Replacing Ruby LSP document symbols.
- Introducing a separate `ruby-test` Monaco language.
- Parsing arbitrary metaprogramming or evaluating Ruby code.
- Perfect Ruby AST reconstruction in the browser.
- Merging the unrelated drag-and-drop worktree changes.

## Chosen approach

Extend the shared `RubyOutline` parser and the existing Ruby Monarch tokenizer.

This was selected over:

1. **A separate `ruby-test` Monaco language.** That would duplicate the Ruby
   grammar and risk detaching Ruby LSP providers, formatting, completion, and
   diagnostics that register against `ruby`.
2. **Ruby LSP or backend symbols as the source of truth.** Ruby LSP is optional
   and macro-defined test symbols are not guaranteed to be exposed consistently.
   A backend request would also make an otherwise immediate local panel
   dependent on process availability.

## Test-file recognition

Test-specific outline parsing is enabled only when the workspace-relative path
matches the same conventions as `TestRunnerService.test_file?`:

- a `_test.rb` file under any `test/` directory;
- a `_spec.rb` file under any `spec/` directory;
- any path ending in `_test.rb`; or
- any path ending in `_spec.rb`.

The frontend matcher receives contract tests using the same examples as
`TestRunnerService`. It does not replace the backend matcher; it keeps the
browser's display behavior aligned with the runner's existing public
conventions.

## Architecture

### Ruby language identity

Test and spec files continue to create Monaco models with language ID `ruby`.
No filename-to-language changes are required. The feature changes only:

- the Ruby tokenizer rules registered for `ruby`; and
- the entries returned by `RubyOutline` for recognized test paths.

### Ruby tokenizer

The existing Ruby Monarch grammar gains ordered rules before the generic
identifier rule.

Runnable test declarations:

- `test`
- `it`
- `specify`
- `example`
- `scenario`

Test suites:

- `describe`
- `context`
- `feature`

Hooks and helpers:

- `setup`
- `teardown`
- `before`
- `after`
- `around`
- `let`
- `let!`
- `subject`

Rules use standard token families already understood by the bundled themes,
such as `entity.name.function`, `keyword.control`, and `support.function`.
Descriptions remain ordinary Ruby strings. `RSpec` remains an ordinary Ruby
constant.

Tokenizer highlighting applies to Ruby generally. These words are valid method
calls outside test files, and highlighting them does not change parsing,
execution, language identity, or diagnostics. Only outline extraction is
test-path-gated.

### `RubyOutline`

The Claude worktree's lexer and visibility tracking become the foundation. The
lexer continues to mask comments, strings, regular expressions, percent
literals, and heredocs before interpreting structural source.

`RubyOutline.parse(lines, { path })` returns:

```text
entries     flat source-ordered array
truncated   true when the 5,000-entry cap was reached
```

Each entry contains:

```text
line        1-based declaration line
name        display label
kind        method | suite | test
depth       enclosing test-suite depth, starting at 0
visibility  public | protected | private | null
```

Ordinary method entries:

- match regular `def` and `def self.name` declarations;
- retain visibility from the Claude parser;
- use `kind: "method"`; and
- use the current suite depth when a helper method is declared inside a suite.

Minitest entries:

- `def test_*` remains a method entry because it is a real Ruby method;
- `test "description" do` and its brace form produce `kind: "test"`; and
- macro-defined tests use `visibility: null`.

RSpec entries:

- `describe`, `context`, and `feature`, optionally prefixed by `RSpec.`, produce
  `kind: "suite"`;
- `it`, `specify`, `example`, and `scenario` produce `kind: "test"`; and
- indentation and the active suite stack determine `depth`.

Suite nesting is structural navigation, not Ruby semantic analysis. It follows
conventional indentation and block forms; malformed or deliberately unusual
indentation may flatten an item but must not create a wrong line target.

### Description extraction

Single-line single- or double-quoted descriptions are displayed without their
quotes. Escaped quote characters remain part of the display label.

When a recognized declaration has a dynamic, symbol, interpolated, or multiline
description that cannot be represented reliably, the entry receives a stable
fallback:

```text
test at line 42
suite at line 18
```

The parser does not execute expressions or interpolate source.

A declaration header may span at most eight lines. The entry points to the line
containing the DSL method and uses the fallback label. If no block opener is
found within that bound, the candidate is ignored.

### `EditorPanel`

Opening the current method dropdown:

1. reads every line from the current Monaco model;
2. calls `RubyOutline.parse(lines, { path: tab.path })`;
3. renders `result.entries` in source order and a truncation row when
   `result.truncated` is true; and
4. navigates to the selected entry's exact line.

For ordinary Ruby files, the control keeps its current `Methods` label and
method-only appearance. For recognized test/spec files, it uses the `Outline`
label and includes methods, suites, and tests.

Rows use existing icon infrastructure:

- method icon for `method`;
- suite/group icon for `suite`; and
- flask/test icon for `test`.

Suite depth adds visual indentation. Suites, tests, and methods are all
selectable. Selecting an entry closes the panel, reveals the line in the
center, places the cursor at column 1, and focuses the editor.

The existing private/protected sticky headers are preserved for method entries.
Test and suite entries do not inherit Ruby method visibility.

No run button or test result state is added to this panel.

## Supported declaration forms

The first version recognizes conventional block declarations whose opening is
on one line:

```ruby
test "validates the form" do
end

describe User do
  context "when inactive" do
    it "rejects login" do
    end
  end
end

RSpec.describe User do
  specify("has a name") { expect(subject.name).to be_present }
end
```

Parenthesized descriptions, single-line brace blocks, and declaration headers
spanning up to eight lines are supported. A block constructed indirectly
through variables or `send` is outside scope.

## Failure behavior and limits

- Unrecognized Ruby remains ordinary source and creates no outline entry.
- Matches inside comments, strings, regular expressions, percent literals, and
  heredocs are ignored.
- A call named `test`, `context`, or similar in a non-test Ruby file does not
  create a test-outline entry.
- A malformed declaration is skipped or receives a line-based fallback; it
  never prevents ordinary `def` entries from being returned.
- Parser work is linear in file length and runs only when the panel opens.
- At most 5,000 outline entries are emitted. The panel adds a visible
  truncation row when the cap is reached.
- An unexpected parser exception is caught at the component boundary. The
  editor remains usable and the panel shows `Outline unavailable` rather than
  unmounting the editor.
- Tokenizer rules are declarative and cannot block file loading if no rule
  matches.

## Worktree integration

Implementation must preserve the useful Ruby outline work without merging the
mixed Claude worktree wholesale.

Relevant work to reuse or port:

- `app/assets/javascripts/mbeditor/ruby_outline.js`
- `test/lib/mbeditor/ruby_outline_test.rb`
- the `RubyOutline` asset require
- the focused `EditorPanel` outline rendering changes
- the outline-specific styles

The parser's output contract will change from visibility groups to the flat
entry model described above. Existing visibility tests must be adapted, not
discarded. Drag-and-drop import, file-tree, dummy visibility-fixture, and other
unrelated changes remain outside this enhancement.

## Security

- No Ruby code is evaluated.
- No subprocess, backend endpoint, filesystem operation, or test execution is
  introduced.
- Parsing is limited to the already loaded Monaco model.
- The existing file-size cap and editor loading behavior remain unchanged.
- No additional file paths are sent to the server.

## Testing

### `RubyOutline` unit tests

MiniRacer-backed tests cover:

- ordinary instance and singleton methods;
- existing public, protected, and private transitions;
- Rails/Minitest `test` with single and double quotes;
- `def test_*`;
- RSpec suites and runnable examples;
- `RSpec.describe`;
- nested suite depth;
- parenthesized and brace-block forms;
- dynamic and multiline description fallbacks;
- comments, strings, regexes, percent literals, and heredocs containing
  test-looking source;
- non-test paths calling test DSL-named methods;
- malformed source degrading without an exception;
- source ordering; and
- the 5,000-entry limit.

### Tokenizer and browser tests

A real browser test uses Monaco's tokenizer to prove:

- `_test.rb` and `_spec.rb` models retain language ID `ruby`;
- runnable, suite, and hook/helper DSL words no longer receive a generic
  identifier token;
- ordinary Ruby syntax continues to receive its existing tokens; and
- Ruby LSP-backed behavior remains attached to the model.

Browser-level verification is required because static inspection of the Monarch
configuration does not prove the tokens Monaco actually emits.

### System tests

Tracked Minitest and RSpec fixtures verify:

- the toolbar label changes to `Outline` only for test/spec files;
- ordinary methods, suites, and tests appear in source order;
- nested RSpec entries are indented;
- private/protected method sections remain visible;
- selecting each entry moves the cursor to the exact declaration line;
- the panel reflects unsaved model edits when reopened;
- ordinary Ruby files retain their existing Methods panel; and
- test-at-cursor behavior remains unchanged.

### Static and regression checks

- `node --check` for the parser and modified JavaScript.
- Sprockets compilation includes `RubyOutline` before `EditorPanel`.
- Existing editor, Ruby LSP, test-runner, and system-test suites remain green.
- The full suite result is reported separately from targeted verification if an
  unrelated baseline failure remains.

## Acceptance criteria

The feature is complete when:

1. Rails/Minitest and RSpec DSL calls have meaningful Ruby highlighting in the
   real Monaco editor.
2. Test/spec models still report language ID `ruby`.
3. Jump to Method becomes Outline for recognized test files and lists ordinary
   methods, suites, and runnable tests from the unsaved buffer.
4. Every entry navigates to the correct declaration line.
5. False test entries are not produced from literals, comments, heredocs, or
   ordinary Ruby paths.
6. Existing method visibility, Ruby LSP, formatting, diagnostics, and
   test-at-cursor behavior are preserved.
7. No unrelated Claude worktree changes are included.
