# frozen_string_literal: true

require "system_test_helper"

module Mbeditor
  class EditorSystemTest < ActionDispatch::SystemTestCase
    driven_by :cuprite, options: MBEDITOR_CUPRITE_OPTIONS.dup

    def setup
      @workspace = Dir.mktmpdir("mbeditor_sys_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "README.md"), "# Hello\n")
      File.write(File.join(@workspace, "Gemfile"), "source \"https://rubygems.org\"\n")
      File.write(File.join(@workspace, "Gemfile.lock"), "GEM\n  specs:\n")
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      File.write(File.join(@workspace, "nested_example.rb"), "class Demo\n    def call\nend")
      File.write(File.join(@workspace, "component.jsx"), "<div")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      Capybara.reset_sessions!
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    test "page loads and React mounts" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
    end

    test "file tree shows workspace files" do
      visit "/mbeditor"
      assert_text "README.md", wait: 10
    end

    test "clicking a file opens it in the editor" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: "README.md").first.click
      assert_selector ".monaco-editor", wait: 10
    end

    test "Gemfile and Gemfile.lock use ruby syntax" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      all(".tree-item-name", text: "Gemfile").first.click
      assert_selector ".monaco-editor", wait: 10
      assert_equal "ruby", active_editor_language

      all(".tree-item-name", text: "Gemfile.lock").first.click
      assert_selector ".monaco-editor", wait: 10
      assert_equal "ruby", active_editor_language
    end

    test "Ctrl+P opens the quick-open dialog" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find("body").send_keys([:control, "p"])
      assert_selector ".quick-open-overlay", wait: 5

      find(".quick-open-input").set("README")
      assert_selector ".quick-open-result-icon", wait: 5
      assert_selector ".quick-open-clear-btn", wait: 5

      find(".quick-open-clear-btn").click
      assert_equal "", find(".quick-open-input").value
    end

    test "sidebar search shows loading and clear controls" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find(".ide-activity-btn[title='Search']").click

      page.execute_script(<<~'JS')
        window.SearchService.projectSearch = function () {
          return new Promise(function () {});
        };
      JS

      find(".search-input").set("README")
      assert_selector ".search-loading-overlay", wait: 5
      assert_selector ".search-adornment-clear", wait: 5

      find(".search-adornment-clear").click
      assert_equal "", find(".search-input").value
      assert_no_selector ".search-loading-overlay", wait: 5
    end

    test "server-online heartbeat shows no offline indicator" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      assert_no_selector ".statusbar-offline"
    end

    test "ruby auto-end inserts nested closing line below the cursor line" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "nested_example.rb").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue(["class Demo", "    def call", "end"].join("\n"));
        editor.getModel().updateOptions({ insertSpaces: true, tabSize: 4 });
        editor.setPosition({ lineNumber: 2, column: editor.getModel().getLineMaxColumn(2) });
        editor.focus();
        window.MbeditorEditorPlugins.runRubyEnter(editor);
      JS

      expected = "class Demo\n    def call\n        \n    end\nend"
      wait_for_editor_value(expected)
      assert_equal({ "lineNumber" => 3, "column" => 9 }, active_editor_position)
    end

    test "ruby auto-end still inserts end when a sibling method follows below" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "nested_example.rb").click
      assert_selector ".monaco-editor", wait: 10

      # The everyday case: writing a NEW method above an existing one. The
      # sibling's `end` (same indent) must not be mistaken for the opener's.
      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue(["class Demo", "  def fresh", "", "  def existing", "  end", "end"].join("\n"));
        editor.getModel().updateOptions({ insertSpaces: true, tabSize: 2 });
        editor.setPosition({ lineNumber: 2, column: editor.getModel().getLineMaxColumn(2) });
        editor.focus();
        window.MbeditorEditorPlugins.runRubyEnter(editor);
      JS

      expected = "class Demo\n  def fresh\n    \n  end\n\n  def existing\n  end\nend"
      wait_for_editor_value(expected)
    end

    test "ruby auto-end skips insertion when the opener already has its own end" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "nested_example.rb").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue(["class Demo", "  def has_end", "  end", "end"].join("\n"));
        editor.getModel().updateOptions({ insertSpaces: true, tabSize: 2 });
        editor.setPosition({ lineNumber: 2, column: editor.getModel().getLineMaxColumn(2) });
        editor.focus();
        window.MbeditorEditorPlugins.runRubyEnter(editor);
      JS

      expected = "class Demo\n  def has_end\n    \n  end\nend"
      wait_for_editor_value(expected)
    end

    test "jsx auto-close inserts matching closing tag and preserves inner cursor position" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        var editor = window.__mbeditorActiveEditor;
        editor.setValue("<div");
        editor.setPosition({ lineNumber: 1, column: editor.getModel().getLineMaxColumn(1) });
        editor.focus();
        editor.trigger('keyboard', 'type', { text: '>' });
      JS

      wait_for_editor_value("<div></div>")
      assert_equal({ "lineNumber" => 1, "column" => 6 }, active_editor_position)
    end

    test "tab key does not collapse multi-line selections in jsx" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      result = page.evaluate_script(<<~'JS')
        (function () {
          var editor = window.__mbeditorActiveEditor;
          var monaco = window.monaco;
          editor.setValue(["<div>", "<span>", "</span>"].join("\n"));

          var model = editor.getModel();
          editor.setSelection(new monaco.Selection(1, 1, 3, model.getLineMaxColumn(3)));
          var action = editor.getAction('mbeditor.emmet.expandAbbreviation');
          if (action && action.run) action.run();

          return {
            lineCount: model.getLineCount(),
            line1: model.getLineContent(1),
            line2: model.getLineContent(2),
            line3: model.getLineContent(3)
          };
        })()
      JS

      assert_equal 3, result["lineCount"]
      assert_match(/^\s*<div>\z/, result["line1"])
      assert_match(/^\s*<span>\z/, result["line2"])
      assert_match(/^\s*<\/span>\z/, result["line3"])
    end

    test "git blame toggle renders inline annotations" do
      repo_root = File.expand_path("../../..", __dir__)
      previous_workspace = @workspace

      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root = repo_root
        c.excluded_paths = %w[.git tmp log node_modules vendor/bundle]
      end

      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: "README.md", minimum: 1).first.click
      assert_selector ".monaco-editor", wait: 10

      click_button "Blame"
      assert_text "Loaded blame for", wait: 10

      header_count = page.evaluate_script(<<~JS)
        (function () {
          return document.querySelectorAll('.ide-blame-block-header').length;
        })()
      JS
      assert_operator header_count.to_i, :>, 0
    ensure
      Mbeditor.configure do |c|
        c.workspace_root = previous_workspace
      end
    end

    test "git panel refresh button spins while refreshing" do
      repo_root = File.expand_path("../../..", __dir__)
      previous_workspace = @workspace

      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root = repo_root
        c.excluded_paths = %w[.git tmp log node_modules vendor/bundle]
      end

      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find("button", text: "Git").click
      assert_selector ".ide-git-right-panel", wait: 5

      page.execute_script(<<~'JS')
        window.GitService.fetchInfo = function () {
          return new Promise(function () {});
        };
      JS

      find("button[title='Refresh']").click
      assert_selector "button[title='Refresh'] i.fa-spin", wait: 5
    ensure
      Mbeditor.configure do |c|
        c.workspace_root = previous_workspace
      end
    end

    # ── New feature tests ────────────────────────────────────────────────────────

    test "Ctrl+Shift+Z toggles zen mode hiding the sidebar" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      # Sidebar visible initially — style.display is empty string (not 'none')
      sidebar_initially_visible = page.evaluate_script(
        "document.querySelector('.ide-sidebar') && document.querySelector('.ide-sidebar').style.display !== 'none'"
      )
      assert sidebar_initially_visible, "Sidebar should be visible before zen mode"

      find("body").send_keys([:control, :shift, "z"])

      assert_selector ".statusbar-zen-btn", wait: 5
      sidebar_hidden = page.evaluate_script("document.querySelector('.ide-sidebar') === null")
      assert sidebar_hidden, "Sidebar should be hidden in zen mode"

      find(".statusbar-zen-btn").click
      assert_no_selector ".statusbar-zen-btn", wait: 5
      sidebar_restored = page.evaluate_script("document.querySelector('.ide-sidebar') !== null")
      assert sidebar_restored, "Sidebar should be visible after exiting zen mode"
    end

    test "search panel toggle reveals replace input row" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find(".ide-activity-btn[title='Search']").click

      assert_no_selector ".search-replace-row"

      find("button[title='Toggle Replace']").click
      assert_selector ".search-replace-row", wait: 5
      assert_selector ".search-replace-input", wait: 5

      find("button[title='Toggle Replace']").click
      assert_no_selector ".search-replace-row", wait: 5
    end

    test "file tab dirty dot clears after undoing all edits" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      all(".tree-item-name", text: "README.md").first.click
      assert_selector ".monaco-editor", wait: 10

      # No dirty dot initially
      assert_no_selector ".tab-item.active .tab-dirty-dot"

      # Type a character to dirty the model
      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.focus();
        window.__mbeditorActiveEditor.trigger('keyboard', 'type', { text: 'x' });
      JS

      assert_selector ".tab-item.active .tab-dirty-dot", wait: 5

      # Undo the edit — AVI returns to cleanVersionId
      page.execute_script("window.__mbeditorActiveEditor.trigger('keyboard', 'undo', {})")

      assert_no_selector ".tab-item.active .tab-dirty-dot", wait: 5
    end

    test "file stays dirty-trackable after undo-history replay swaps the model" do
      seed_git_workspace_with_history("README.md", "# Hello\n")

      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: "README.md").first.click
      assert_selector ".monaco-editor", wait: 10

      # Wait for the background replay to swap in the history-bearing model.
      assert_replayed_model("README.md")

      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.focus();
        window.__mbeditorActiveEditor.trigger('keyboard', 'type', { text: 'x' });
      JS

      assert_selector ".tab-item.active .tab-dirty-dot", wait: 5
    end

    test "LRU eviction keeps Monaco model count at or below 15" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      all(".tree-item-name", text: "README.md").first.click
      assert_selector ".monaco-editor", wait: 10

      model_count = page.evaluate_script(<<~'JS')
        (function () {
          if (!window.monaco || !window.__mbeditorModels || !window.TabManager) return null;
          var MAX = 15;
          for (var i = 0; i < 20; i++) {
            var uri = window.monaco.Uri.parse('inmemory://lru_cap_' + i + '.rb');
            if (!window.monaco.editor.getModel(uri)) {
              window.monaco.editor.createModel('# ' + i, 'ruby', uri);
            }
            var m = window.monaco.editor.getModel(uri);
            window.__mbeditorModels['lru_cap_' + i + '.rb'] = {
              model: m,
              lastAccessed: Date.now() - (20 - i) * 1000,
              cleanVersionId: m.getAlternativeVersionId()
            };
            if (Object.keys(window.__mbeditorModels).length > MAX) {
              window.TabManager.evictLruModel();
            }
          }
          return Object.keys(window.__mbeditorModels).length;
        })()
      JS

      assert_operator model_count.to_i, :<=, 15, "Expected ≤ 15 cached models, got #{model_count}"
    end

    test "hovering a file tree item for 200 ms triggers prefetch" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      page.execute_script(<<~'JS')
        window.__prefetchPaths = [];
        var _origPrefetch = FileService.prefetch;
        FileService.prefetch = function (path) {
          window.__prefetchPaths.push(path);
          return _origPrefetch.call(this, path);
        };
      JS

      find(".tree-item-name", text: "README.md").hover
      sleep 0.35  # 200 ms debounce + margin

      prefetch_paths = page.evaluate_script("window.__prefetchPaths || []")
      assert_operator prefetch_paths.length, :>, 0, "Expected FileService.prefetch to be called on hover"
    end

    test "repeated search query uses client-side cache instead of network" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      find(".ide-activity-btn[title='Search']").click

      page.execute_script(<<~'JS')
        window.__searchNetworkCount = 0;
        var _origGet = window.axios.get;
        window.axios.get = function (url, config) {
          if (typeof url === 'string' && url.indexOf('/search') !== -1) {
            window.__searchNetworkCount++;
          }
          return _origGet.apply(this, arguments);
        };
        SearchService.invalidate();
      JS

      find(".search-input").set("User")
      sleep 0.8  # Debounce + first network request

      count_after_first = page.evaluate_script("window.__searchNetworkCount")
      assert_operator count_after_first, :>=, 1, "Expected at least one network request for first search"

      # Clear and reissue the same query — should be served from cache
      find(".search-input").set("")
      find(".search-input").set("User")
      sleep 0.8

      count_after_second = page.evaluate_script("window.__searchNetworkCount")
      assert_equal count_after_first, count_after_second,
                   "Second identical search should use cache with no new network request"
    end

    test "fetchPage loads a results page without throwing" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10

      # The virtual-scroll loader calls SearchService.fetchPage directly (no UI
      # control), so drive it through its public interface. Capture both a
      # synchronous throw (the latent basePath ReferenceError) and any async
      # rejection so the failure message is informative.
      page.execute_script(<<~'JS')
        window.__fetchPageResult = null;
        try {
          Promise.resolve(SearchService.fetchPage('Hello', 0))
            .then(function (r) { window.__fetchPageResult = { ok: true, count: (r.results || []).length }; })
            .catch(function (e) { window.__fetchPageResult = { ok: false, error: String(e) }; });
        } catch (e) {
          window.__fetchPageResult = { ok: false, error: String(e) };
        }
      JS

      result = nil
      50.times do
        result = page.evaluate_script("window.__fetchPageResult")
        break if result
        sleep 0.1
      end

      assert result, "SearchService.fetchPage never settled"
      assert result["ok"], "SearchService.fetchPage threw instead of completing: #{result["error"]}"
    end

    test "monaco flags undefined variable used in jsx" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.setValue(
          'function App() { return React.createElement(UndefinedComponent, null); }'
        );
      JS

      assert wait_for_monaco_marker(matching: /UndefinedComponent/),
             "Expected Monaco to flag 'UndefinedComponent' as undefined"
    end

    test "monaco does not flag user-defined window globals as undefined" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      # FileService is set on window by mbeditor's own JS before Monaco initialises —
      # same pattern as a sprockets-loaded component (e.g. LinkComponent).
      # It is NOT in the static shim, so only the dynamic window scan can declare it.
      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.setValue(
          'FileService.getFile("x.js"); var y = TrulyUndefinedGlobal;'
        );
      JS

      assert wait_for_monaco_marker(matching: /TrulyUndefinedGlobal/),
             "Checker should flag TrulyUndefinedGlobal (confirms worker ran)"

      messages = page.evaluate_script(<<~'JS')
        (function () {
          var model = window.__mbeditorActiveEditor.getModel();
          return window.monaco.editor.getModelMarkers({ resource: model.uri })
            .map(function(m) { return m.message; });
        })()
      JS
      fs_errors = Array(messages).select { |m| m.match?(/FileService/) }
      assert_empty fs_errors,
                   "Expected no FileService errors (window global), got: #{fs_errors.inspect}"
    end

    test "monaco does not flag React or sprockets globals as undefined" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      # Mix a genuine undefined (TrulyUndefinedVar) with React so we know
      # when the checker has actually run before asserting React is clean.
      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.setValue(
          'const { useState } = React; var x = TrulyUndefinedVar;'
        );
      JS

      assert wait_for_monaco_marker(matching: /TrulyUndefinedVar/),
             "Checker should flag TrulyUndefinedVar (confirms worker ran)"

      messages = page.evaluate_script(<<~'JS')
        (function () {
          var model = window.__mbeditorActiveEditor.getModel();
          return window.monaco.editor.getModelMarkers({ resource: model.uri })
            .map(function(m) { return m.message; });
        })()
      JS
      react_errors = Array(messages).select { |m| m.match?(/\bReact\b/) }
      assert_empty react_errors,
                   "Expected no React errors (sprockets global), got: #{react_errors.inspect}"
    end

    test "monaco warns about unused local variable in javascript" do
      visit "/mbeditor"
      assert_selector ".file-tree", wait: 10
      find(".tree-item-name", text: "component.jsx").click
      assert_selector ".monaco-editor", wait: 10

      page.execute_script(<<~'JS')
        window.__mbeditorActiveEditor.setValue(
          'function App() { var unusedThing = 42; return null; }'
        );
      JS

      # severity 4 = Monaco MarkerSeverity.Warning (not 8 = Error)
      assert wait_for_monaco_marker(matching: /unusedThing/, severity: 4),
             "Expected Monaco to show 'unusedThing' as a Warning (severity 4), not an Error"
    end

    private

    # Turn the tmp workspace into a git repo and pre-seed a stored undo history for
    # `rel_path`, so opening the file triggers the background history replay that
    # swaps the Monaco model out from under the editor.
    def seed_git_workspace_with_history(rel_path, content)
      Dir.chdir(@workspace) do
        system("git", "init", "--quiet", out: File::NULL, err: File::NULL)
        system("git", "config", "user.email", "test@example.com")
        system("git", "config", "user.name", "Test")
        system("git", "add", ".", out: File::NULL, err: File::NULL)
        system("git", "commit", "--quiet", "-m", "init", out: File::NULL, err: File::NULL)
      end
      branch = `git -C #{@workspace} rev-parse --abbrev-ref HEAD`.strip

      # base + ops must reproduce the file's on-disk content, or the replay bails out.
      branch_hash = Digest::SHA256.hexdigest(branch)[0, 16]
      file_hash   = Digest::SHA256.hexdigest(rel_path)[0, 16]
      hist_path   = File.join(@workspace, "tmp", "mbeditor_history", "#{branch_hash}_#{file_hash}.json")
      FileUtils.mkdir_p(File.dirname(hist_path))
      File.write(hist_path, JSON.dump(
        "base" => "",
        "ops"  => [[1, 1, 1, 1, content]],
        "t"    => Time.now.utc.iso8601
      ))
    end

    # Blocks until the replayed model (AVI > 1 because ops were pushed onto it) is
    # installed for `rel_path`, or fails if the replay never happens.
    def assert_replayed_model(rel_path)
      deadline = Time.now + 10
      loop do
        avi = page.evaluate_script(<<~JS)
          (function () {
            var e = window.__mbeditorModels && window.__mbeditorModels[#{rel_path.to_json}];
            return e && e.model && !e.model.isDisposed() ? e.model.getAlternativeVersionId() : 0;
          })()
        JS
        break if avi.to_i > 1
        flunk "undo-history replay never swapped in a model for #{rel_path}" if Time.now > deadline
        sleep 0.1
      end
    end

    def active_editor_value
      page.evaluate_script("window.__mbeditorActiveEditor && window.__mbeditorActiveEditor.getValue()")
    end

    def active_editor_position
      page.evaluate_script(<<~JS)
        (function () {
          var editor = window.__mbeditorActiveEditor;
          if (!editor) return null;
          var position = editor.getPosition();
          return position ? { lineNumber: position.lineNumber, column: position.column } : null;
        })()
      JS
    end

    def active_editor_language
      page.evaluate_script(<<~JS)
        (function () {
          var editor = window.__mbeditorActiveEditor;
          if (!editor || !editor.getModel) return null;
          var model = editor.getModel();
          return model ? model.getLanguageId() : null;
        })()
      JS
    end

    # Polls until a Monaco marker whose message matches +matching+ appears (or timeout).
    # Pass +severity:+ to additionally require a specific Monaco MarkerSeverity value
    # (4 = Warning, 8 = Error). Returns the marker hash on success, nil on timeout.
    def wait_for_monaco_marker(matching:, severity: nil, timeout: 10)
      deadline = Time.now + timeout
      loop do
        markers = page.evaluate_script(<<~JS)
          (function () {
            var editor = window.__mbeditorActiveEditor;
            var model = editor && editor.getModel && editor.getModel();
            if (!model) return [];
            return window.monaco.editor.getModelMarkers({ resource: model.uri })
              .map(function(m) { return { message: m.message, severity: m.severity }; });
          })()
        JS
        found = Array(markers).find do |m|
          m["message"].match?(matching) && (severity.nil? || m["severity"] == severity)
        end
        return found if found
        return nil if Time.now >= deadline
        sleep 0.2
      end
    end

    def wait_for_editor_value(expected, timeout: Capybara.default_max_wait_time)
      deadline = Time.now + timeout
      loop do
        value = active_editor_value
        return if value == expected
        raise "Timed out waiting for editor value to become #{expected.inspect}; got #{value.inspect}" if Time.now >= deadline

        sleep 0.05
      end
    end
  end
end
