# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class EditorsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @workspace = Dir.mktmpdir("mbeditor_test_")
      FileUtils.mkdir_p(File.join(@workspace, "tmp"))
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      File.write(File.join(@workspace, "README.md"), "# Hello\n")

      Mbeditor.configure do |c|
        c.allowed_environments  = %i[test development]
        c.workspace_root        = @workspace
        c.excluded_paths        = %w[.git tmp log]
        c.authenticate_with     = nil
      end

    end

    # Automatically attach the CSRF-guard header to every non-GET/HEAD request.
    # Rails delegates post/patch/delete directly to integration_session, so we
    # override each method rather than process().
    %w[post patch put delete].each do |m|
      define_method(m) do |path, **kwargs|
        kwargs[:headers] = (kwargs[:headers] || {}).merge('X-Mbeditor-Client' => '1')
        super(path, **kwargs)
      end
    end

    # The workspace is a fresh tmpdir, so probe that volume rather than the repo
    # checkout — the two can differ.
    def case_insensitive_workspace?
      ExclusionMatcher.case_insensitive_filesystem?(@workspace)
    end

    def teardown
      FileUtils.rm_rf(@upload_dir) if @upload_dir
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure do |c|
        c.authenticate_with = nil
        c.rubocop_command   = "rubocop"
        # setup narrows excluded_paths per-test; restore the gem default so
        # suites running after this one see the real configuration.
        c.excluded_paths    = Configuration.new.excluded_paths
      end
      AvailabilityProbe.reset!
    end

    # ---------------------------------------------------------------------------
    # js_globals
    # ---------------------------------------------------------------------------

    test "js_globals returns top-level declarations and refreshes after a save" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "assets", "javascripts"))
      File.write(File.join(@workspace, "app", "assets", "javascripts", "widget.js.jsx"),
                 "function GlobalWidget() {}\n")
      JsGlobalsService.invalidate(@workspace)

      get "/mbeditor/js_globals"
      assert_response :ok
      assert json["ok"]
      names = json["symbols"].map { |s| s["name"] }
      assert_includes names, "GlobalWidget"

      # A save through mbeditor invalidates the cache, so a fresh symbol
      # appears without waiting out the TTL.
      post "/mbeditor/create_file", params: { path: "app/assets/javascripts/fresh.js", code: "var FreshGlobal = 1;\n" }
      assert_response :ok

      get "/mbeditor/js_globals"
      names = json["symbols"].map { |s| s["name"] }
      assert_includes names, "FreshGlobal"
    ensure
      JsGlobalsService.invalidate(@workspace)
    end

    # ---------------------------------------------------------------------------
    # js_program
    # ---------------------------------------------------------------------------

    test "js_program returns workspace source and refreshes a single file after a save" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "assets", "javascripts"))
      File.write(File.join(@workspace, "app", "assets", "javascripts", "prog.jsx"),
                 "var ProgWidget = function () { return null; };\n")
      JsProgramService.invalidate(@workspace)

      get "/mbeditor/js_program"
      assert_response :ok
      assert json["ok"]
      assert json["enabled"]
      entry = json["files"].find { |f| f["path"] == "app/assets/javascripts/prog.jsx" }
      assert entry, "expected the source file in the program"
      assert_includes entry["content"], "var ProgWidget"
      assert_operator json["totalBytes"], :>, 0

      # A save invalidates the cache, so new source is picked up without
      # waiting out the TTL.
      post "/mbeditor/create_file",
           params: { path: "app/assets/javascripts/added.js", code: "var AddedGlobal = 1;\n" }
      assert_response :ok

      get "/mbeditor/js_program"
      assert_includes json["files"].map { |f| f["path"] }, "app/assets/javascripts/added.js"

      # The single-file form is what the editor uses to refresh incrementally.
      get "/mbeditor/js_program", params: { path: "app/assets/javascripts/added.js" }
      assert_response :ok
      assert_equal "app/assets/javascripts/added.js", json["file"]["path"]
      assert_includes json["file"]["content"], "AddedGlobal"
    ensure
      JsProgramService.invalidate(@workspace)
    end

    test "js_program refuses a path outside the workspace" do
      get "/mbeditor/js_program", params: { path: "../../../etc/passwd.js" }
      assert_response :ok
      assert_nil json["file"]
    end

    # ---------------------------------------------------------------------------
    # ruby_lsp bridge
    # ---------------------------------------------------------------------------

    FAKE_LSP_SERVER = File.expand_path("../../fixtures/fake_lsp_server.rb", __dir__)

    def with_ruby_lsp_available(value)
      singleton = class << AvailabilityProbe; self; end
      singleton.alias_method :__orig_ruby_lsp, :ruby_lsp
      AvailabilityProbe.define_singleton_method(:ruby_lsp) { |*| value }
      yield
    ensure
      singleton.remove_method :ruby_lsp
      singleton.alias_method :ruby_lsp, :__orig_ruby_lsp
      singleton.remove_method :__orig_ruby_lsp
    end

    test "ruby_lsp requires the client header" do
      ActionDispatch::Integration::Session.new(Rails.application).tap do |sess|
        sess.post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "a.rb" }, as: :json
        assert_equal 403, sess.response.status
      end
    end

    test "ruby_lsp diagnostics translate into the marker shape the lint pipeline uses" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "diagnostics", path: "app/models/user.rb",
                                             content: "class User\n  x=1\nend\n" }
        assert_response :ok

        markers = json["markers"]
        assert_equal 2, markers.length
        assert_equal 2, json.dig("summary", "offense_count")

        rubocop = markers.first
        assert_equal "info", rubocop["severity"], "LSP severity 3 (INFORMATION) maps to info"
        assert_equal "Layout/SpaceAroundOperators", rubocop["copName"]
        assert_equal "rubocop", rubocop["source"], "must stay 'rubocop' so the quick-fix lightbulb appears"
        assert_equal true, rubocop["correctable"]
        assert_equal 3, rubocop["startLine"], "0-based LSP line 2 becomes 1-based 3"
        assert_equal 5, rubocop["startCol"]
        assert_includes rubocop["message"], "[Layout/SpaceAroundOperators]"

        assert_equal "https://docs.rubocop.org/rubocop/cops_layout.html#layoutspacearoundoperators",
                     rubocop["codeHref"], "the cop name links out to its docs"

        # ruby-lsp embeds the fix edits in the diagnostic, so the lightbulb
        # applies them with no second request.
        fixes = rubocop["fixes"]
        assert_equal ["Autocorrect Layout/SpaceAroundOperators",
                      "Disable Layout/SpaceAroundOperators for this line"],
                     fixes.map { |f| f["title"] }
        edit = fixes.first["edits"].first
        assert_equal 3, edit["startLine"], "0-based LSP line 2 becomes 1-based 3"
        assert_equal 5, edit["startCol"]
        assert_equal " = ", edit["text"]

        prism = markers.last
        assert_equal "error", prism["severity"]
        assert_equal "prism", prism["source"], "non-RuboCop sources must not claim a lightbulb"
        assert_equal "", prism["copName"]
        assert_equal false, prism["correctable"]
        assert_nil prism["fixes"], "a diagnostic with no code actions carries no fixes key"
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    test "ruby_lsp rejects an unknown lsp_method" do
      post "/mbeditor/ruby_lsp", params: { lsp_method: "workspace/executeCommand", path: "a.rb",
                                           content: "", line: 1, character: 1 }
      assert_response :bad_request
    end

    test "ruby_lsp passes raw methods through and rewrites their URIs" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "references", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        refs = json["result"]
        assert_equal 1, refs.length, "the gem location has no place in this editor and must be dropped"
        assert_equal "app/models/user.rb", refs.first["uri"], "absolute file:// URIs never reach the browser"
        refute_includes response.body, "file://"
        # Raw passthrough keeps LSP's own 0-based ranges; the JS provider converts.
        assert_equal 6, refs.first.dig("range", "start", "line")

        post "/mbeditor/ruby_lsp", params: { lsp_method: "document_symbol", path: "app/models/user.rb",
                                             content: "class User; end" }
        assert_response :ok
        assert_equal "User", json["result"].first["name"]
        assert_equal "full_name", json["result"].first["children"].first["name"]

        post "/mbeditor/ruby_lsp", params: { lsp_method: "folding_range", path: "app/models/user.rb",
                                             content: "class User; end" }
        assert_response :ok
        assert_equal [0, 2], json["result"].map { |r| r["startLine"] }

        post "/mbeditor/ruby_lsp", params: { lsp_method: "document_highlight", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        assert_equal [1, 2], json["result"].map { |h| h["kind"] }
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    test "ruby_lsp forwards formatting options and selection-range positions" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "formatting", path: "app/models/user.rb",
                                             content: "class User; end", tab_size: 4, insert_spaces: false }
        assert_response :ok
        assert_includes json["result"].first["newText"], "tabSize=4"
        assert_includes json["result"].first["newText"], "insertSpaces=false"

        # Defaults when the editor sends nothing.
        post "/mbeditor/ruby_lsp", params: { lsp_method: "formatting", path: "app/models/user.rb",
                                             content: "class User; end" }
        assert_response :ok
        assert_includes json["result"].first["newText"], "tabSize=2"
        assert_includes json["result"].first["newText"], "insertSpaces=true"

        # selectionRange takes a list of positions, not the single `position`
        # every other positional method uses.
        post "/mbeditor/ruby_lsp", params: { lsp_method: "selection_range", path: "app/models/user.rb",
                                             content: "class User; end", line: 3, character: 5 }
        assert_response :ok
        chain = json["result"].first
        assert_equal 2, chain.dig("range", "start", "line")
        assert_equal 0, chain.dig("parent", "range", "start", "character")
        assert_equal 0, chain.dig("parent", "parent", "range", "start", "line"), "the chain survives intact"

        post "/mbeditor/ruby_lsp", params: { lsp_method: "signature_help", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        assert_equal "full_name(first, last)", json.dig("result", "signatures", 0, "label")
        assert_equal 1, json.dig("result", "activeParameter")

        # ruby-lsp embeds file:// links in signature documentation. They must
        # get the same treatment as hover's: no absolute host path reaches the
        # browser, in-workspace links become openable, gem links go inert.
        docs = json.dig("result", "signatures", 0, "documentation", "value")
        refute_includes docs, "file://"
        refute_includes response.body, Rails.root.to_s
        assert_includes docs, "command:mbeditor.openDefinition"
        assert_includes docs, "`set.rb`", "a gem this editor cannot open must not look like a link"
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    # ── exceptions ───────────────────────────────────────────────────────────

    test "exceptions returns recorded host-app failures newest first" do
      Mbeditor::ExceptionLog.clear!
      error = RuntimeError.new("kaboom")
      error.set_backtrace(["#{@workspace}/app/models/user.rb:3:in 'go'",
                           "/gems/actionpack/lib/metal.rb:1:in 'dispatch'"])
      Mbeditor::ExceptionLog.record(error, { controller: "UsersController", action: "show" },
                                    workspace_root: @workspace)

      get "/mbeditor/exceptions"
      assert_response :ok

      entry = json["exceptions"].first
      assert_equal "RuntimeError", entry["klass"]
      assert_equal "UsersController", entry["controller"]
      assert_equal [{ "file" => "app/models/user.rb", "line" => 3 }], entry["frames"],
                   "gem frames are dropped and the workspace root stripped"
      refute_includes response.body, @workspace, "no absolute host path in the payload"
    ensure
      Mbeditor::ExceptionLog.clear!
    end

    test "exceptions can be cleared" do
      Mbeditor::ExceptionLog.record(RuntimeError.new("x"), {}, workspace_root: @workspace)

      delete "/mbeditor/exceptions"
      assert_response :ok

      get "/mbeditor/exceptions"
      assert_empty json["exceptions"]
    ensure
      Mbeditor::ExceptionLog.clear!
    end

    test "clearing exceptions requires the client header" do
      ActionDispatch::Integration::Session.new(Rails.application).tap do |sess|
        sess.delete "/mbeditor/exceptions", as: :json
        assert_equal 403, sess.response.status
      end
    end

    # ── ruby_rename ──────────────────────────────────────────────────────────

    def with_fake_lsp
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!
      with_ruby_lsp_available(true) { yield }
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    def sibling_path
      File.join(@workspace, "app", "models", "rename_sibling.rb")
    end

    test "ruby_rename rejects anything that is not a Ruby constant" do
      ["lower_case", "9Bad", "With Space", "", "Foo::bar"].each do |name|
        post "/mbeditor/ruby_rename", params: { path: "app/models/user.rb", content: "class User; end",
                                                line: 1, character: 7, new_name: name }
        assert_response :unprocessable_content, "#{name.inspect} should be refused"
        assert_includes json["error"], "constants"
      end
    end

    test "ruby_rename writes closed files and returns edits for open ones" do
      File.write(sibling_path, "class User\n  def x(User); end\nend\n")

      with_fake_lsp do
        post "/mbeditor/ruby_rename", params: {
          path: "app/models/user.rb", content: "class User; end", line: 1, character: 7,
          new_name: "Account", open_paths: ["app/models/user.rb"]
        }
        assert_response :ok

        # The open file is never written; its edits come back for Monaco.
        assert_equal ["app/models/user.rb"], json["edits"].keys
        assert_equal "class User; end\n", File.read(File.join(@workspace, "app/models/user.rb")),
                     "an open buffer must not be overwritten behind the editor's back"
        edit = json["edits"]["app/models/user.rb"].first
        assert_equal [1, 7, 1, 11], edit.values_at("startLine", "startCol", "endLine", "endCol")
        assert_equal "Account", edit["text"]

        # The closed sibling is written, with both of its edits applied.
        assert_equal ["app/models/rename_sibling.rb"], json["written"]
        assert_equal "class Account\n  def x(Account); end\nend\n", File.read(sibling_path)

        # And the out-of-workspace target is refused, visibly.
        assert_equal 1, json["rejected"].length
        assert_equal "class User; end\n", File.read(File.join(@workspace, "app/models/user.rb"))
      end
    end

    test "ruby_rename writes a file the editor did not declare as open" do
      File.write(sibling_path, "class User\n  def x(User); end\nend\n")

      with_fake_lsp do
        post "/mbeditor/ruby_rename", params: {
          path: "app/models/user.rb", content: "class User; end", line: 1, character: 7,
          new_name: "Account", open_paths: []
        }
        assert_response :ok
        assert_empty json["edits"], "nothing is open, so nothing comes back for Monaco"
        assert_equal %w[app/models/user.rb app/models/rename_sibling.rb].sort, json["written"].sort
        assert_equal "class Account; end\n", File.read(File.join(@workspace, "app/models/user.rb"))
      end
    end

    test "ruby_rename returns 422 when ruby-lsp is unavailable" do
      with_ruby_lsp_available(false) do
        post "/mbeditor/ruby_rename", params: { path: "app/models/user.rb", content: "class User; end",
                                                line: 1, character: 7, new_name: "Account" }
        assert_response :unprocessable_content
        assert_equal false, json["rubyLspAvailable"]
      end
    end

    test "ruby_rename requires the client header" do
      ActionDispatch::Integration::Session.new(Rails.application).tap do |sess|
        sess.post "/mbeditor/ruby_rename",
                  params: { path: "app/models/user.rb", new_name: "Account" }, as: :json
        assert_equal 403, sess.response.status
      end
    end

    test "definition results carry a full range so peek has something to show" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        first = json["results"].first
        assert_equal 5, first["line"]
        assert_equal 3, first["col"], "0-based character 2 becomes 1-based 3"
        assert_equal 5, first["endLine"]
        assert_equal 11, first["endCol"]
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    test "ruby_lsp rejects a traversal path" do
      post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "../../etc/passwd", content: "", line: 1, character: 1 }
      assert_response :bad_request
    end

    test "ruby_lsp rejects oversized content" do
      # as: :json — the real client posts JSON; Rack's urlencoded parser has
      # its own 4MB body limit that would 400 before reaching the action.
      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "app/models/user.rb",
                                             content: "x" * (5 * 1024 * 1024 + 1), line: 1, character: 1 },
             as: :json
        assert_response :content_too_large
      end
    end

    test "ruby_lsp returns 422 with the availability flag and a reason when the probe fails" do
      with_ruby_lsp_available(false) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 1 }
        assert_response :unprocessable_content
        assert_equal false, json["rubyLspAvailable"]
        assert_predicate json["reason"].to_s, :present?, "the status chip needs something to show"
      end
    end

    test "ruby_lsp health needs no path and does not start the server" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "health" }
        assert_response :ok
        assert_equal true, json["available"]
        assert_equal false, json["disabled"]
        assert_equal "stopped", json["state"], "health must not boot the process"
        assert_equal 0, json["restarts"]
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    test "ruby_lsp health reports unavailability with a reason instead of 422" do
      with_ruby_lsp_available(false) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "health" }
        assert_response :ok, "the indicator must be able to ask even when ruby-lsp is gone"
        assert_equal false, json["available"]
        assert_predicate json["reason"].to_s, :present?
      end
    end

    test "ruby_lsp restart brings the client back to ready" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "restart" }
        assert_response :ok
        assert_equal true, json["available"]
        assert_equal "ready", json["state"]
        assert_nil json["error"]
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
      Mbeditor::AvailabilityProbe.reset!
    end

    test "ruby_lsp health never leaks the resolved command" do
      with_ruby_lsp_available(false) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "health" }
        assert_response :ok
        refute_includes json.keys, "command"
        refute_includes response.body, Rails.root.to_s
      end
    end

    test "ruby_lsp translates definition, hover, and completion responses" do
      original_cmd = Mbeditor.configuration.ruby_lsp_command
      Mbeditor.configuration.ruby_lsp_command = [RbConfig.ruby, FAKE_LSP_SERVER]
      Mbeditor::RubyLspClient.reset!

      with_ruby_lsp_available(true) do
        post "/mbeditor/ruby_lsp", params: { lsp_method: "definition", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        first = json["results"].first
        assert_equal "app/models/user.rb", first["file"]
        assert_equal 5, first["line"], "0-based LSP line 4 becomes 1-based 5"

        post "/mbeditor/ruby_lsp", params: { lsp_method: "hover", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        assert_includes json["markdown"], "fake hover"
        # ruby-lsp emits file:// links, which are inert in a browser. In-workspace
        # links become Monaco command links; anything outside loses its link.
        refute_includes json["markdown"], "file://"
        assert_includes json["markdown"],
                        "[user.rb](command:mbeditor.openDefinition?" \
                        "#{ERB::Util.url_encode(%(["app/models/user.rb",3]))})"
        assert_includes json["markdown"], "`set.rb`"
        # ruby-lsp strips one "# " per comment line, so a ##-opened doc block
        # arrives as "# Title" and would render as an <h1> filling the hover.
        assert_includes json["markdown"], "\\# Doc comment opened with ## in the source"
        refute_match(/^# /, json["markdown"], "no comment line may render as a heading")
        # The Ruby code fence is untouched — # in there is source, not a heading.
        assert_includes json["markdown"], "```ruby\nUser\n```"

        post "/mbeditor/ruby_lsp", params: { lsp_method: "completion", path: "app/models/user.rb",
                                             content: "class User; end", line: 1, character: 7 }
        assert_response :ok
        suggestion = json["suggestions"].first
        assert_equal "fake_method", suggestion["label"]
        assert_equal "Method", suggestion["kind"]
      end
    ensure
      Mbeditor::RubyLspClient.reset!
      Mbeditor.configuration.ruby_lsp_command = original_cmd
    end

    test "workspace reports rubyLspAvailable" do
      with_ruby_lsp_available(false) do
        get "/mbeditor/workspace"
        assert_response :ok
        assert_equal false, json["rubyLspAvailable"]
      end
    end

    # ---------------------------------------------------------------------------
    # js_definition parent context
    # ---------------------------------------------------------------------------

    test "js_definition rejects an invalid parent identifier" do
      get "/mbeditor/js_definition", params: { symbol: "myFunc", parent: "bad-name!" }
      assert_response :bad_request
      assert_equal "Invalid parent", json["error"]
    end

    test "js_definition with parent resolves the member assignment" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "assets", "javascripts"))
      File.write(File.join(@workspace, "app", "assets", "javascripts", "parent.js"),
                 "var SomeParent = {};\nSomeParent.myFunc = function() {};\n")
      File.write(File.join(@workspace, "app", "assets", "javascripts", "global.js"),
                 "function myFunc() {}\n")

      get "/mbeditor/js_definition", params: { symbol: "myFunc", parent: "SomeParent" }
      assert_response :ok
      first = json["results"].first
      assert_equal "app/assets/javascripts/parent.js", first["file"]
      assert_equal 2, first["line"]
      assert first["member"]
    end

    # ---------------------------------------------------------------------------
    # lint language=javascript (babel syntax check)
    # ---------------------------------------------------------------------------

    test "lint with language javascript returns 422 when the checker is unavailable" do
      File.write(File.join(@workspace, "app.js"), "var x = 1;\n")
      original = Mbeditor.configuration.js_syntax_check
      Mbeditor.configuration.js_syntax_check = false

      post "/mbeditor/lint", params: { path: "app.js", code: "var x = 1;", language: "javascript" }
      assert_response :unprocessable_content
      assert_equal [], json["markers"]
    ensure
      Mbeditor.configuration.js_syntax_check = original
    end

    test "lint with language javascript maps a babel parse error to a marker" do
      skip "mini_racer not available" unless defined?(::MiniRacer) || begin
        require "mini_racer"
        true
      rescue LoadError
        false
      end

      File.write(File.join(@workspace, "babel-stub.js"), <<~JS)
        var Babel = { transform: function (src) {
          if (src.indexOf("BROKEN") !== -1) {
            var e = new Error("Unexpected token (1:3)");
            e.loc = { line: 1, column: 3 };
            throw e;
          }
          return { code: null };
        } };
      JS
      File.write(File.join(@workspace, "app.js"), "ok\n")
      original_check = Mbeditor.configuration.js_syntax_check
      original_path  = Mbeditor.configuration.babel_standalone_path
      Mbeditor.configuration.js_syntax_check = :auto
      Mbeditor.configuration.babel_standalone_path = File.join(@workspace, "babel-stub.js")
      JsSyntaxCheckService.reset!

      post "/mbeditor/lint", params: { path: "app.js", code: "var BROKEN = ;", language: "javascript" }
      assert_response :ok
      marker = json["markers"].first
      assert marker, "expected a babel marker"
      assert_equal "error", marker["severity"]
      assert_includes marker["message"], "Unexpected token"
      assert_equal 1, marker["startLine"]
      assert_equal 4, marker["startCol"]

      post "/mbeditor/lint", params: { path: "app.js", code: "var fine = 1;", language: "javascript" }
      assert_response :ok
      assert_equal [], json["markers"]
    ensure
      Mbeditor.configuration.js_syntax_check = original_check
      Mbeditor.configuration.babel_standalone_path = original_path
      JsSyntaxCheckService.reset!
    end

    # ---------------------------------------------------------------------------
    # authenticate_with
    # ---------------------------------------------------------------------------

    test "authenticate_with nil allows requests through" do
      get "/mbeditor/ping"
      assert_response :ok
    end

    test "authenticate_with proc that halts blocks request" do
      Mbeditor.configure { |c| c.authenticate_with = proc { render plain: "Unauthorized", status: :unauthorized } }
      get "/mbeditor/ping"
      assert_response :unauthorized
    end

    test "authenticate_with proc that allows passes request through" do
      Mbeditor.configure { |c| c.authenticate_with = proc { } }
      get "/mbeditor/ping"
      assert_response :ok
    end

    test "authentication_cache_ttl skips proc when session timestamp is within ttl" do
      call_count = 0
      Mbeditor.configure do |c|
        c.authenticate_with     = proc { call_count += 1 }
        c.authentication_cache_ttl = 60
      end

      # First request — proc runs and stamps the session
      get "/mbeditor/ping"
      assert_response :ok
      assert_equal 1, call_count

      # Second request within ttl — proc must NOT run again
      get "/mbeditor/ping"
      assert_response :ok
      assert_equal 1, call_count, "auth proc should not be called again within ttl"
    ensure
      Mbeditor.configure { |c| c.authentication_cache_ttl = 0 }
    end

    test "authentication_cache_ttl calls proc again when ttl has expired" do
      call_count = 0
      Mbeditor.configure do |c|
        c.authenticate_with     = proc { call_count += 1 }
        c.authentication_cache_ttl = 5
      end

      # First request — auth proc runs and stamps the session with current time
      get "/mbeditor/ping"
      assert_response :ok
      assert_equal 1, call_count

      # Travel forward in time past the TTL (5 seconds)
      travel 6.seconds do
        # Second request with time advanced — auth proc should run again
        get "/mbeditor/ping"
        assert_response :ok
        assert_equal 2, call_count, "auth proc should be called again after ttl expires"
      end
    ensure
      Mbeditor.configure { |c| c.authentication_cache_ttl = 0 }
    end

    # ---------------------------------------------------------------------------
    # ping
    # ---------------------------------------------------------------------------

    test "ping returns ok" do
      get "/mbeditor/ping"
      assert_response :ok
      assert_equal true, json["ok"]
    end

    # ---------------------------------------------------------------------------
    # workspace
    # ---------------------------------------------------------------------------

    test "workspace returns root name and path" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert_equal File.basename(@workspace), json["rootName"]
      assert_equal @workspace, json["rootPath"]
    end

    test "workspace reports rubocop availability for configured command" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }

      get "/mbeditor/workspace"

      assert_response :ok
      assert_equal true, json["rubocopAvailable"]
    end

    test "workspace reports rubocop unavailable for invalid command" do
      Mbeditor.configure { |c| c.rubocop_command = "definitely_missing_rubocop_command" }

      get "/mbeditor/workspace"

      assert_response :ok
      assert_equal false, json["rubocopAvailable"]
    ensure
      Mbeditor.configure { |c| c.rubocop_command = "rubocop" }
    end

    test "workspace includes gitAvailable flag" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert json.key?("gitAvailable"), "gitAvailable missing from workspace response"
      assert_includes [true, false], json["gitAvailable"]
    end

    test "workspace includes blameAvailable flag" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert json.key?("blameAvailable"), "blameAvailable missing from workspace response"
      assert_includes [true, false], json["blameAvailable"]
    end

    test "workspace includes actionCableEnabled flag" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert json.key?("actionCableEnabled"), "actionCableEnabled missing from workspace response"
      assert_includes [true, false], json["actionCableEnabled"]
    end

    test "workspace gitAvailable is false when workspace_root is not a git repo" do
      Dir.mktmpdir("mbeditor_nongit_") do |non_git_dir|
        Mbeditor.configure { |c| c.workspace_root = non_git_dir }
        get "/mbeditor/workspace"
        assert_response :ok
        assert_equal false, json["gitAvailable"]
      end
    ensure
      Mbeditor.configure { |c| c.workspace_root = @workspace }
    end

    # ---------------------------------------------------------------------------
    # files
    # ---------------------------------------------------------------------------

    test "files returns file tree" do
      get "/mbeditor/files"
      assert_response :ok
      assert_kind_of Array, json
      names = json.map { |n| n["name"] }
      assert_includes names, "README.md"
      assert_includes names, "app"
    end

    test "files includes size for file entries but not folders" do
      get "/mbeditor/files"
      assert_response :ok

      files   = json.select { |n| n["type"] == "file" }
      folders = json.select { |n| n["type"] == "folder" }

      assert files.any?,   "expected at least one file at root"
      assert folders.any?, "expected at least one folder at root"

      files.each   { |f| assert f.key?("size"),    "file #{f["name"]} missing size key" }
      folders.each { |d| assert_not d.key?("size"), "folder #{d["name"]} should not have size key" }
      files.each   { |f| assert_kind_of Integer, f["size"] }
      files.each   { |f| assert f["size"] >= 0 }
    end

    test "files shows excluded_paths in the explorer (only search excludes them)" do
      get "/mbeditor/files"
      assert_response :ok
      names = json.map { |n| n["name"] }
      assert_includes names, "tmp"
    end

    # ---------------------------------------------------------------------------
    # state
    # ---------------------------------------------------------------------------

    test "state returns empty hash when no state file exists" do
      get "/mbeditor/state"
      assert_response :ok
      assert_equal({}, json)
    end

    test "save_state persists state and state retrieves it" do
      post "/mbeditor/state", params: { state: { openTabs: ["foo.rb"] } }, as: :json
      assert_response :ok
      assert_equal true, json["ok"]

      get "/mbeditor/state"
      assert_response :ok
      assert_equal ["foo.rb"], json["openTabs"]
    end

    test "save_state returns 413 for oversized payload" do
      oversized = "x" * (Mbeditor::EditorsController::STATE_MAX_BYTES + 1)
      post "/mbeditor/state", params: { state: oversized }, as: :json
      assert_response :content_too_large
      assert_match(/too large/i, json["error"])
    end

    # ---------------------------------------------------------------------------
    # branch_state
    # ---------------------------------------------------------------------------

    test "branch_state returns empty hash when no state file exists" do
      get "/mbeditor/branch_state", params: { branch: "main" }
      assert_response :ok
      assert_equal({}, json)
    end

    test "branch_state returns 400 for invalid branch name" do
      get "/mbeditor/branch_state", params: { branch: "../../etc" }
      assert_response :bad_request
    end

    test "save_branch_state persists and branch_state retrieves it" do
      pane_state = { panes: [{ id: 1, tabs: [], activeTabId: nil }], focusedPaneId: 1 }
      post "/mbeditor/branch_state", params: { branch: "feature/test-123", state: pane_state }, as: :json
      assert_response :ok
      assert_equal true, json["ok"]

      get "/mbeditor/branch_state", params: { branch: "feature/test-123" }
      assert_response :ok
      assert_equal 1, json["panes"].length
    end

    test "save_branch_state returns 400 for invalid branch name" do
      post "/mbeditor/branch_state", params: { branch: "bad name!", state: {} }, as: :json
      assert_response :bad_request
    end

    test "prune_branch_states removes states for deleted branches" do
      # Initialize a git repo so `git branch` works
      system("git", "-C", @workspace, "init", "-q")
      system("git", "-C", @workspace, "-c", "user.email=t@t.com", "-c", "user.name=T", "commit", "--allow-empty", "-m", "init", "-q")

      # Save state for a branch that definitely doesn't exist in the repo
      post "/mbeditor/branch_state", params: { branch: "definitely-not-a-real-branch-xyz", state: { panes: [] } }, as: :json

      post "/mbeditor/prune_branch_states", as: :json
      assert_response :ok
      assert_includes json["pruned"], "definitely-not-a-real-branch-xyz"
    end

    test "prune_branch_states routes its git subprocess through ProcessRunner with configured timeout" do
      system("git", "-C", @workspace, "init", "-q")
      system("git", "-C", @workspace, "-c", "user.email=t@t.com", "-c", "user.name=T", "commit", "--allow-empty", "-m", "init", "-q")

      original = Mbeditor.configuration.git_timeout
      Mbeditor.configuration.git_timeout = 9

      captured = []
      with_process_runner_recorder(captured) { post "/mbeditor/prune_branch_states", as: :json }
      assert_response :ok

      branch_call = captured.find { |c| c[:cmd].include?("branch") }
      refute_nil branch_call,
                 "expected `git branch` to run through ProcessRunner, " \
                 "but it bypassed the timeout mechanism"
      assert_equal 9, branch_call[:timeout],
                   "expected the configured git_timeout to be applied to the prune_branch_states call"
    ensure
      Mbeditor.configuration.git_timeout = original
    end

    # ---------------------------------------------------------------------------
    # file_history
    # ---------------------------------------------------------------------------

    test "file_history returns empty hash when no history exists" do
      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_response :ok
      assert_equal({}, json)
    end

    test "file_history returns 400 for invalid branch name" do
      get "/mbeditor/file_history", params: { branch: "../../etc", path: "app/models/user.rb" }
      assert_response :bad_request
    end

    test "file_history returns 403 for path outside workspace" do
      get "/mbeditor/file_history", params: { branch: "main", path: "/etc/passwd" }
      assert_response :forbidden
    end

    test "file_history returns base and ops after save" do
      post "/mbeditor/file_history", params: {
        branch: "main",
        path: "app/models/user.rb",
        ops: [[1,1,1,1,"hello"]],
        base: "class User; end\n"
      }, as: :json
      assert_response :no_content

      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_response :ok
      assert_equal "class User; end\n", json["base"]
      assert_equal [[1,1,1,1,"hello"]], json["ops"]
    end

    test "file_history prunes and returns empty when history is older than 7 days" do
      hist_dir = File.join(@workspace, "tmp", "mbeditor_history")
      FileUtils.mkdir_p(hist_dir)
      branch_hash = Digest::SHA256.hexdigest("main")[0,16]
      file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
      hist_file   = File.join(hist_dir, "#{branch_hash}_#{file_hash}.json")
      File.write(hist_file, {
        branch: "main", path: "app/models/user.rb",
        base: "x", ops: [], t: (Time.now.utc - 8 * 24 * 3600).iso8601
      }.to_json)

      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_response :ok
      assert_equal({}, json)
      assert_not File.exist?(hist_file), "history file should be pruned"
    end

    test "file_history returns empty and deletes corrupted history file" do
      hist_dir = File.join(@workspace, "tmp", "mbeditor_history")
      FileUtils.mkdir_p(hist_dir)
      branch_hash = Digest::SHA256.hexdigest("main")[0,16]
      file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
      hist_file   = File.join(hist_dir, "#{branch_hash}_#{file_hash}.json")
      File.write(hist_file, "not json {{{{")

      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_response :ok
      assert_equal({}, json)
      assert_not File.exist?(hist_file), "corrupt file should be deleted"
    end

    # ---------------------------------------------------------------------------
    # save_file_history (POST /file_history)
    # ---------------------------------------------------------------------------

    test "save_file_history returns 400 for invalid branch name" do
      post "/mbeditor/file_history", params: {
        branch: "bad name!", path: "app/models/user.rb",
        ops: [], base: "x"
      }, as: :json
      assert_response :bad_request
    end

    test "save_file_history returns 403 for path outside workspace" do
      post "/mbeditor/file_history", params: {
        branch: "main", path: "/etc/passwd",
        ops: [[1,1,1,1,"x"]], base: "x"
      }, as: :json
      assert_response :forbidden
    end

    test "save_file_history returns 400 when base is missing on first write" do
      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: [[1,1,1,1,"hello"]]
      }, as: :json
      assert_response :bad_request
    end

    test "save_file_history appends ops on subsequent writes" do
      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: [[1,1,1,1,"hello"]], base: "class User; end\n"
      }, as: :json
      assert_response :no_content

      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: [[1,6,1,6," world"]]
      }, as: :json
      assert_response :no_content

      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_equal 2, json["ops"].length
      assert_equal [1,6,1,6," world"], json["ops"].last
    end

    test "save_file_history compacts when ops exceed HISTORY_MAX_OPS" do
      base = "line\n"
      first_ops = Array.new(Mbeditor::EditorsController::HISTORY_MAX_OPS) { [1,1,1,1,"x"] }

      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: first_ops, base: base
      }, as: :json
      assert_response :no_content

      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: [[1,1,1,1,"y"]]
      }, as: :json
      assert_response :no_content

      get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
      assert_equal Mbeditor::EditorsController::HISTORY_MAX_OPS - Mbeditor::EditorsController::HISTORY_COMPACT_TARGET + 1, json["ops"].length
    end

    test "save_file_history returns 204 with empty ops array" do
      post "/mbeditor/file_history", params: {
        branch: "main", path: "app/models/user.rb",
        ops: [], base: "x"
      }, as: :json
      assert_response :no_content
    end

    test "prune_branch_states also deletes history files for deleted branches" do
      system("git", "-C", @workspace, "init", "-q")
      system("git", "-C", @workspace, "-c", "user.email=t@t.com", "-c", "user.name=T", "commit", "--allow-empty", "-m", "init", "-q")

      # Save history for a branch that won't exist in the repo
      post "/mbeditor/file_history", params: {
        branch: "ghost-branch-xyz",
        path: "app/models/user.rb",
        ops: [[1,1,1,1,"x"]],
        base: "x"
      }, as: :json
      assert_response :no_content

      branch_hash = Digest::SHA256.hexdigest("ghost-branch-xyz")[0,16]
      file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
      hist_file   = File.join(@workspace, "tmp", "mbeditor_history", "#{branch_hash}_#{file_hash}.json")
      assert File.exist?(hist_file), "history file should exist before prune"

      post "/mbeditor/prune_branch_states", as: :json
      assert_response :ok
      assert_not File.exist?(hist_file), "history file should be deleted after prune"
    end

    test "prune_branch_states logs an error for a corrupt history file" do
      system("git", "-C", @workspace, "init", "-q")
      system("git", "-C", @workspace, "-c", "user.email=t@t.com", "-c", "user.name=T", "commit", "--allow-empty", "-m", "init", "-q")

      hist_dir = File.join(@workspace, "tmp", "mbeditor_history")
      FileUtils.mkdir_p(hist_dir)
      corrupt = File.join(hist_dir, "deadbeef_cafebabe.json")
      File.write(corrupt, "{ not valid json")

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)
      begin
        post "/mbeditor/prune_branch_states", as: :json
        assert_response :ok
      ensure
        Rails.logger = original_logger
      end

      assert_match(/mbeditor/, log.string)
      assert_match(/deadbeef_cafebabe\.json/, log.string)
      assert File.exist?(corrupt), "corrupt history file with no parseable branch should be left in place"
    end

    # ---------------------------------------------------------------------------
    # show (GET /file)
    # ---------------------------------------------------------------------------

    test "show returns file content" do
      get "/mbeditor/file", params: { path: "README.md" }
      assert_response :ok
      assert_equal "README.md", json["path"]
      assert_equal "# Hello\n", json["content"]
    end

    test "show returns 404 for missing file" do
      get "/mbeditor/file", params: { path: "does_not_exist.rb" }
      assert_response :not_found
    end

    test "show returns missing payload when allow_missing is set" do
      get "/mbeditor/file", params: { path: "does_not_exist.rb", allow_missing: "1" }

      assert_response :ok
      assert_equal "does_not_exist.rb", json["path"]
      assert_equal "", json["content"]
      assert_equal true, json["missing"]
    end

    test "show returns 403 for path traversal attempt" do
      get "/mbeditor/file", params: { path: "../../etc/passwd" }
      assert_response :forbidden
    end

    test "show returns 403 when path is a symlink pointing outside the workspace" do
      outside = Tempfile.new('mbeditor_outside_')
      outside.write('secret')
      outside.flush
      link = File.join(@workspace, 'evil_link.txt')
      File.symlink(outside.path, link)

      get '/mbeditor/file', params: { path: 'evil_link.txt' }
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      outside&.close!
    end

    test "show returns image metadata without content for image files" do
      png = File.join(@workspace, "logo.png")
      File.binwrite(png, "\x89PNG\r\n")

      get "/mbeditor/file", params: { path: "logo.png" }
      assert_response :ok
      assert_equal true, json["image"]
      assert_equal "", json["content"]
    end

    # ---------------------------------------------------------------------------
    # raw
    # ---------------------------------------------------------------------------

    test "raw serves file inline" do
      get "/mbeditor/raw", params: { path: "README.md" }
      assert_response :ok
      assert_equal "# Hello\n", response.body
    end

    test "raw returns 404 for missing file" do
      get "/mbeditor/raw", params: { path: "nope.txt" }
      assert_response :not_found
    end

    test "raw returns 403 for path traversal" do
      get "/mbeditor/raw", params: { path: "../secret" }
      assert_response :forbidden
    end

    test 'raw returns 413 for file exceeding size limit' do
      big = File.join(@workspace, 'big.bin')
      File.binwrite(big, 'x' * (Mbeditor::FileOperationService::MAX_FILE_SIZE_BYTES + 1))
      get '/mbeditor/raw', params: { path: 'big.bin' }
      assert_response 413
    end

    test 'raw returns 403 for symlink pointing outside workspace' do
      outside = Tempfile.new('mbeditor_outside_')
      outside.write('secret content')
      outside.flush
      link = File.join(@workspace, 'evil_link.txt')
      File.symlink(outside.path, link)
      get '/mbeditor/raw', params: { path: 'evil_link.txt' }
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      outside&.close!
    end

    # ---------------------------------------------------------------------------
    # save (POST /file)
    # ---------------------------------------------------------------------------

    test "save writes content to an existing file" do
      post "/mbeditor/file", params: { path: "README.md", code: "# Updated\n" }, as: :json
      assert_response :ok
      assert_equal "# Updated\n", File.read(File.join(@workspace, "README.md"))
    end

    test "save returns 403 for path traversal" do
      post "/mbeditor/file", params: { path: "../../evil.rb", code: "bad" }, as: :json
      assert_response :forbidden
    end

    test "save returns 403 for excluded path" do
      post "/mbeditor/file", params: { path: "tmp/cache.txt", code: "x" }, as: :json
      assert_response :forbidden
    end

    test "save rejects content exceeding MAX_FILE_SIZE_BYTES" do
      oversized = "x" * (Mbeditor::FileOperationService::MAX_FILE_SIZE_BYTES + 1)
      post "/mbeditor/file", params: { path: "README.md", code: oversized }, as: :json
      assert_response 413
      assert json.key?("error")
    end

    # ---------------------------------------------------------------------------
    # create_file
    # ---------------------------------------------------------------------------

    test "create_file creates a new file" do
      post "/mbeditor/create_file", params: { path: "new_file.rb", code: "# new\n" }, as: :json
      assert_response :ok
      assert_equal "file", json["type"]
      assert File.exist?(File.join(@workspace, "new_file.rb"))
    end

    test "create_file creates intermediate directories" do
      post "/mbeditor/create_file", params: { path: "lib/tasks/my_task.rake", code: "" }, as: :json
      assert_response :ok
      assert File.exist?(File.join(@workspace, "lib", "tasks", "my_task.rake"))
    end

    test "create_file returns 422 if file already exists" do
      post "/mbeditor/create_file", params: { path: "README.md", code: "" }, as: :json
      assert_response :unprocessable_content
      assert_match(/already exists/i, json["error"])
    end

    test "create_file returns 403 for path traversal" do
      post "/mbeditor/create_file", params: { path: "../../evil.rb", code: "" }, as: :json
      assert_response :forbidden
    end

    test "create_file returns 403 for excluded path" do
      post "/mbeditor/create_file", params: { path: "tmp/new.txt", code: "" }, as: :json
      assert_response :forbidden
    end

    # A case-insensitive filesystem resolves "TMP/" and ".GIT/" to the real
    # excluded directories, so the exclusion check has to fold case there too —
    # ".GIT/hooks/post-checkout" is arbitrary code execution on the next git
    # operation. Gated on a runtime probe of the workspace volume: on a
    # case-sensitive filesystem (Linux CI) these are genuinely distinct paths
    # and creating them is correct.
    test "create_file returns 403 for a case variant of an excluded path" do
      skip "workspace filesystem is case-sensitive" unless case_insensitive_workspace?

      post "/mbeditor/create_file", params: { path: "TMP/new.txt", code: "" }, as: :json
      assert_response :forbidden
      refute File.exist?(File.join(@workspace, "tmp", "new.txt"))
    end

    test "create_file returns 403 for a case variant of the .git directory" do
      skip "workspace filesystem is case-sensitive" unless case_insensitive_workspace?

      post "/mbeditor/create_file", params: { path: ".GIT/hooks/post-checkout", code: "#!/bin/sh\n" }, as: :json
      assert_response :forbidden
      refute File.exist?(File.join(@workspace, ".git", "hooks", "post-checkout"))
    end

    test "create_file returns 403 for an NFD spelling of an excluded path" do
      nfc = "caf\u00E9"  # precomposed
      nfd = "cafe\u0301" # e + combining acute
      original = Mbeditor.configuration.excluded_paths
      Mbeditor.configure { |c| c.excluded_paths = original + [nfc] }

      post "/mbeditor/create_file", params: { path: "#{nfd}/secret.txt", code: "" }, as: :json
      assert_response :forbidden
    ensure
      Mbeditor.configure { |c| c.excluded_paths = original }
    end

    test "create_file rejects content exceeding MAX_FILE_SIZE_BYTES" do
      oversized = "x" * (Mbeditor::FileOperationService::MAX_FILE_SIZE_BYTES + 1)
      post "/mbeditor/create_file", params: { path: "big_new.txt", code: oversized }, as: :json
      assert_response 413
      assert json.key?("error")
    end

    test 'create_file returns 403 when parent directory is a symlink pointing outside workspace' do
      outside_dir = Dir.mktmpdir('mbeditor_outside_dir_')
      link = File.join(@workspace, 'escaped_dir')
      File.symlink(outside_dir, link)
      post '/mbeditor/create_file', params: { path: 'escaped_dir/secret.rb', code: '' }, as: :json
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(outside_dir) if outside_dir && File.directory?(outside_dir)
    end

    test 'save returns 403 when parent directory is a symlink pointing outside workspace' do
      outside_dir = Dir.mktmpdir('mbeditor_outside_dir_')
      link = File.join(@workspace, 'escaped_dir')
      File.symlink(outside_dir, link)
      post '/mbeditor/file', params: { path: 'escaped_dir/secret.rb', code: 'bad' }, as: :json
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(outside_dir) if outside_dir && File.directory?(outside_dir)
    end

    # ---------------------------------------------------------------------------
    # dangling symlink escapes
    #
    # File.exist? follows symlinks, so a symlink whose target does not exist
    # looks like "nothing here" to an existence walk. Writing through it still
    # creates the target, outside the sandbox.
    # ---------------------------------------------------------------------------

    test 'save returns 403 when path is a dangling symlink pointing outside workspace' do
      outside = File.join(Dir.tmpdir, "mbeditor_pwned_#{Process.pid}.txt")
      FileUtils.rm_f(outside)
      link = File.join(@workspace, 'dangling_link.txt')
      File.symlink(outside, link)

      post '/mbeditor/file', params: { path: 'dangling_link.txt', code: 'pwned' }, as: :json
      assert_response :forbidden
      refute File.exist?(outside), 'write escaped the workspace through a dangling symlink'
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_f(outside) if outside
    end

    test 'create_file returns 403 when path is a dangling symlink pointing outside workspace' do
      outside = File.join(Dir.tmpdir, "mbeditor_pwned_create_#{Process.pid}.txt")
      FileUtils.rm_f(outside)
      link = File.join(@workspace, 'dangling_link.rb')
      File.symlink(outside, link)

      post '/mbeditor/create_file', params: { path: 'dangling_link.rb', code: 'pwned' }, as: :json
      assert_response :forbidden
      refute File.exist?(outside), 'write escaped the workspace through a dangling symlink'
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_f(outside) if outside
    end

    test 'create_file returns 403 when an ancestor is a dangling symlink pointing outside workspace' do
      outside_dir = File.join(Dir.tmpdir, "mbeditor_pwned_dir_#{Process.pid}")
      FileUtils.rm_rf(outside_dir)
      link = File.join(@workspace, 'dangling_dir')
      File.symlink(outside_dir, link)

      post '/mbeditor/create_file', params: { path: 'dangling_dir/secret.rb', code: 'pwned' }, as: :json
      assert_response :forbidden
      refute File.exist?(outside_dir), 'mkdir_p escaped the workspace through a dangling symlink'
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(outside_dir) if outside_dir
    end

    test 'create_dir returns 403 when path is a dangling symlink pointing outside workspace' do
      outside_dir = File.join(Dir.tmpdir, "mbeditor_pwned_mkdir_#{Process.pid}")
      FileUtils.rm_rf(outside_dir)
      link = File.join(@workspace, 'dangling_folder')
      File.symlink(outside_dir, link)

      post '/mbeditor/create_dir', params: { path: 'dangling_folder' }, as: :json
      assert_response :forbidden
      refute File.exist?(outside_dir), 'mkdir escaped the workspace through a dangling symlink'
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(outside_dir) if outside_dir
    end

    test 'rename returns 403 when the destination is a dangling symlink pointing outside workspace' do
      outside = File.join(Dir.tmpdir, "mbeditor_pwned_rename_#{Process.pid}.md")
      FileUtils.rm_f(outside)
      link = File.join(@workspace, 'dangling_dest.md')
      File.symlink(outside, link)

      patch '/mbeditor/rename', params: { path: 'README.md', new_path: 'dangling_dest.md' }, as: :json
      assert_response :forbidden
      refute File.exist?(outside), 'rename escaped the workspace through a dangling symlink'
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_f(outside) if outside
    end

    # The legitimate cases resolve_path exists for must keep working: a target
    # that simply does not exist yet, and a dangling symlink that resolves back
    # inside the workspace.
    test 'save writes through a dangling symlink whose target is inside the workspace' do
      link = File.join(@workspace, 'inside_link.txt')
      File.symlink(File.join(@workspace, 'not_yet.txt'), link)

      post '/mbeditor/file', params: { path: 'inside_link.txt', code: 'fine' }, as: :json
      assert_response :ok
      assert_equal 'fine', File.read(File.join(@workspace, 'not_yet.txt'))
    end

    # ---------------------------------------------------------------------------
    # create_dir
    # ---------------------------------------------------------------------------

    test "create_dir creates a new directory" do
      post "/mbeditor/create_dir", params: { path: "new_folder" }, as: :json
      assert_response :ok
      assert_equal "folder", json["type"]
      assert File.directory?(File.join(@workspace, "new_folder"))
    end

    test "create_dir returns 422 if path already exists" do
      post "/mbeditor/create_dir", params: { path: "app" }, as: :json
      assert_response :unprocessable_content
      assert_match(/already exists/i, json["error"])
    end

    test "create_dir returns 403 for path traversal" do
      post "/mbeditor/create_dir", params: { path: "../../evil_dir" }, as: :json
      assert_response :forbidden
    end

    # ---------------------------------------------------------------------------
    # rename
    # ---------------------------------------------------------------------------

    test "rename moves a file to a new path" do
      patch "/mbeditor/rename", params: { path: "README.md", new_path: "NOTES.md" }, as: :json
      assert_response :ok
      assert_equal "NOTES.md", json["path"]
      assert File.exist?(File.join(@workspace, "NOTES.md"))
      assert_not File.exist?(File.join(@workspace, "README.md"))
    end

    test "rename returns 404 when source does not exist" do
      patch "/mbeditor/rename", params: { path: "ghost.rb", new_path: "real.rb" }, as: :json
      assert_response :not_found
    end

    test "rename returns 422 when target already exists" do
      File.write(File.join(@workspace, "target.rb"), "")
      patch "/mbeditor/rename", params: { path: "README.md", new_path: "target.rb" }, as: :json
      assert_response :unprocessable_content
    end

    test "rename returns 403 for path traversal on source" do
      patch "/mbeditor/rename", params: { path: "../../etc/passwd", new_path: "stolen.txt" }, as: :json
      assert_response :forbidden
    end

    test "rename returns 403 for path traversal on target" do
      patch "/mbeditor/rename", params: { path: "README.md", new_path: "../../evil.md" }, as: :json
      assert_response :forbidden
    end

    test 'rename returns 403 when target parent directory is a symlink pointing outside workspace' do
      outside_dir = Dir.mktmpdir('mbeditor_outside_dir_')
      link = File.join(@workspace, 'escaped_dir')
      File.symlink(outside_dir, link)
      patch '/mbeditor/rename', params: { path: 'README.md', new_path: 'escaped_dir/stolen.md' }, as: :json
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      FileUtils.rm_rf(outside_dir) if outside_dir && File.directory?(outside_dir)
    end

    # ---------------------------------------------------------------------------
    # destroy_path (DELETE /delete)
    # ---------------------------------------------------------------------------

    test "destroy_path deletes a file" do
      delete "/mbeditor/delete", params: { path: "README.md" }, as: :json
      assert_response :ok
      assert_equal "file", json["type"]
      assert_not File.exist?(File.join(@workspace, "README.md"))
    end

    test "destroy_path deletes a directory recursively" do
      delete "/mbeditor/delete", params: { path: "app" }, as: :json
      assert_response :ok
      assert_equal "folder", json["type"]
      assert_not File.exist?(File.join(@workspace, "app"))
    end

    test "destroy_path returns 200 for already-missing path (idempotent)" do
      delete "/mbeditor/delete", params: { path: "ghost.rb" }, as: :json
      assert_response :ok
      assert_equal true, json["ok"]
    end

    test "destroy_path returns 403 for path traversal" do
      delete "/mbeditor/delete", params: { path: "../../etc" }, as: :json
      assert_response :forbidden
    end

    test "destroy_path returns 403 for excluded path" do
      delete "/mbeditor/delete", params: { path: "tmp" }, as: :json
      assert_response :forbidden
    end

    # ---------------------------------------------------------------------------
    # show — file over size limit
    # ---------------------------------------------------------------------------

    test "show returns 413 for file over size limit" do
      big_file = File.join(@workspace, "big.txt")
      File.open(big_file, "wb") do |f|
        f.write("x" * (Mbeditor::FileOperationService::MAX_FILE_SIZE_BYTES + 1))
      end

      get "/mbeditor/file", params: { path: "big.txt" }
      assert_response 413
    ensure
      File.delete(big_file) if File.exist?(big_file)
    end

    # ---------------------------------------------------------------------------
    # show — chunked/paginated reading (start_line param)
    # ---------------------------------------------------------------------------

    test "show with start_line returns first N lines" do
      paged_file = File.join(@workspace, "paged.txt")
      File.write(paged_file, (1..10).map { |i| "line#{i}\n" }.join)

      get "/mbeditor/file", params: { path: "paged.txt", start_line: 0, line_count: 3 }
      assert_response :ok
      body = json
      assert_equal "line1\nline2\nline3\n", body["content"]
      assert_equal 10, body["total_lines"]
      assert_equal 3,  body["line_count"]
      assert_equal 0,  body["start_line"]
      assert body["truncated"]
    ensure
      File.delete(paged_file) if File.exist?(paged_file)
    end

    test "show with start_line returns lines from offset" do
      paged_file = File.join(@workspace, "paged2.txt")
      File.write(paged_file, (1..10).map { |i| "line#{i}\n" }.join)

      get "/mbeditor/file", params: { path: "paged2.txt", start_line: 2, line_count: 3 }
      assert_response :ok
      body = json
      assert_equal "line3\nline4\nline5\n", body["content"]
      assert_equal 10, body["total_lines"]
      assert_equal 3,  body["line_count"]
      assert_equal 2,  body["start_line"]
      assert body["truncated"]
    ensure
      File.delete(paged_file) if File.exist?(paged_file)
    end

    test "show with start_line bypasses 5MB size cap" do
      big_file = File.join(@workspace, "bigpaged.txt")
      # Write just enough lines to test; the file doesn't need to actually exceed 5 MB
      # — we verify that start_line mode returns 200 even for a file over the limit
      File.open(big_file, "wb") do |f|
        f.write("x" * (Mbeditor::FileOperationService::MAX_FILE_SIZE_BYTES + 1))
      end

      get "/mbeditor/file", params: { path: "bigpaged.txt", start_line: 0, line_count: 5 }
      assert_response :ok
      assert_equal 200, response.status
    ensure
      File.delete(big_file) if File.exist?(big_file)
    end

    test "show clamps line_count to 5000" do
      paged_file = File.join(@workspace, "paged3.txt")
      # 6000 lines
      File.write(paged_file, (1..6000).map { |i| "line#{i}\n" }.join)

      get "/mbeditor/file", params: { path: "paged3.txt", start_line: 0, line_count: 9999 }
      assert_response :ok
      body = json
      assert_equal 5000, body["line_count"]
      assert_equal 6000, body["total_lines"]
    ensure
      File.delete(paged_file) if File.exist?(paged_file)
    end

    test "show with start_line past end of file returns empty content" do
      paged_file = File.join(@workspace, "paged4.txt")
      File.write(paged_file, (1..5).map { |i| "line#{i}\n" }.join)

      get "/mbeditor/file", params: { path: "paged4.txt", start_line: 100, line_count: 10 }
      assert_response :ok
      body = json
      assert_equal "", body["content"]
      assert_equal 0,  body["line_count"]
      assert_equal 5,  body["total_lines"]
      refute body["truncated"]
    ensure
      File.delete(paged_file) if File.exist?(paged_file)
    end

    # ---------------------------------------------------------------------------
    # save — symlink path traversal
    # ---------------------------------------------------------------------------

    test "save returns 403 for symlink pointing outside workspace" do
      outside = Tempfile.new('mbeditor_outside_save_')
      outside.write('secret')
      outside.flush
      link = File.join(@workspace, 'evil_save_link.txt')
      File.symlink(outside.path, link)

      post '/mbeditor/file', params: { path: 'evil_save_link.txt', code: 'pwned' }, as: :json
      assert_response :forbidden
    ensure
      File.unlink(link) if link && File.symlink?(link)
      outside&.close!
    end

    # ---------------------------------------------------------------------------
    # state — corrupted JSON
    # ---------------------------------------------------------------------------

    test "state returns empty hash for corrupted JSON in state file" do
      state_path = File.join(@workspace, "tmp", "mbeditor_workspace.json")
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, "this is not valid json {{{{")

      get "/mbeditor/state"
      assert_response :ok
      assert_equal({}, json)
    end

    # ---------------------------------------------------------------------------
    # search
    # ---------------------------------------------------------------------------

    test "search returns empty array for blank query" do
      get "/mbeditor/search", params: { q: "" }
      assert_response :ok
      assert_equal [], json
    end

    test "search returns results for a matching term" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User < ApplicationRecord\nend\n")
      get "/mbeditor/search", params: { q: "ApplicationRecord" }
      assert_response :ok
      assert_kind_of Hash, json
      assert_kind_of Array, json["results"]
      assert json["results"].any? { |r| r["file"].include?("user.rb") }, "expected user.rb in results"
      assert_includes [true, false], json["has_more"]
    end

    test "search singular query matches plural occurrences" do
      File.write(File.join(@workspace, "app", "models", "project.rb"), "class Projects < ApplicationRecord\nend\n")
      get "/mbeditor/search", params: { q: "Project" }
      assert_response :ok
      assert json["results"].any? { |r| r["file"].include?("project.rb") },
             "searching 'Project' should match 'Projects' in file content (substring match)"
    end

    test "search returns ok with empty array when query param is absent" do
      get "/mbeditor/search"
      assert_response :ok
      assert_equal [], json
    end

    test "search response includes results and has_more; total_count is optional on first page" do
      get "/mbeditor/search", params: { q: "class" }
      assert_response :ok
      assert_kind_of Hash, json
      assert json.key?("results")
      assert json.key?("has_more")
      assert_kind_of Array, json["results"]
      assert_includes [true, false], json["has_more"]
      # total_count is returned only when the count thread finishes within the 100ms deadline
      if json.key?("total_count")
        assert_kind_of Integer, json["total_count"]
        assert json["total_count"] >= json["results"].length
      end
    end

    test "search includes total_count on subsequent pages (served from result cache)" do
      get "/mbeditor/search", params: { q: "class", offset: 50 }
      assert_response :ok
      assert_kind_of Hash, json
      assert json.key?("total_count"), "paged response should include total_count from the cached full result set"
    end

    test "search fallback excludes nested path without excluding similarly named directories" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "assets"))
      FileUtils.mkdir_p(File.join(@workspace, "public", "assets"))

      File.write(File.join(@workspace, "app", "assets", "site.css"), "/* NEEDLE_TOKEN */\n")
      File.write(File.join(@workspace, "public", "assets", "bundle.css"), "/* NEEDLE_TOKEN */\n")

      original_excluded = Mbeditor.configuration.excluded_paths
      Mbeditor.configure { |c| c.excluded_paths = %w[.git tmp log public/assets] }

      singleton = class << Mbeditor::SearchReplaceService; self; end
      singleton.alias_method :__orig_rg_available?, :rg_available?
      Mbeditor::SearchReplaceService.define_singleton_method(:rg_available?) { false }
      original_rg = Mbeditor::AvailabilityProbe.method(:rg)
      Mbeditor::AvailabilityProbe.define_singleton_method(:rg) { false }

      get "/mbeditor/search", params: { q: "NEEDLE_TOKEN" }
      assert_response :ok

      files = json.fetch("results", []).map { |row| row["file"] }
      assert_includes files, "app/assets/site.css"
      assert_not_includes files, "public/assets/bundle.css"
      assert json.key?("total_count"), "grep fallback must include total_count"
      assert json["total_count"] >= 1, "grep total_count must reflect at least the one matched file"
    ensure
      Mbeditor.configure { |c| c.excluded_paths = original_excluded }
      singleton.remove_method :rg_available?
      singleton.alias_method :rg_available?, :__orig_rg_available?
      singleton.remove_method :__orig_rg_available?
      Mbeditor::AvailabilityProbe.singleton_class.send(:remove_method, :rg)
      Mbeditor::AvailabilityProbe.define_singleton_method(:rg, original_rg)
    end

    test 'search accepts query of exactly 500 characters' do
      get '/mbeditor/search', params: { q: 'a' * 500 }
      assert_response :ok
    end

    test 'search accepts query of 499 characters' do
      get '/mbeditor/search', params: { q: 'a' * 499 }
      assert_response :ok
    end

    test 'search rejects query of 501 characters with 400' do
      get '/mbeditor/search', params: { q: 'a' * 501 }
      assert_response :bad_request
    end

    # ---------------------------------------------------------------------------
    # definition
    # ---------------------------------------------------------------------------

    test "definition returns 200 with empty results for blank symbol" do
      get "/mbeditor/definition", params: { symbol: "", language: "ruby" }
      assert_response :ok
      data = JSON.parse(response.body)
      assert_equal [], data["results"]
    end

    test "definition returns 400 for symbol with path-traversal characters" do
      get "/mbeditor/definition", params: { symbol: "../etc/passwd", language: "ruby" }
      assert_response :bad_request
    end

    test "definition returns 400 for symbol with spaces" do
      get "/mbeditor/definition", params: { symbol: "foo bar", language: "ruby" }
      assert_response :bad_request
    end

    test "definition returns 200 with empty results for unsupported language" do
      get "/mbeditor/definition", params: { symbol: "foo", language: "python" }
      assert_response :ok
      data = JSON.parse(response.body)
      assert_equal [], data["results"]
    end

    test "definition finds a Ruby method defined in the workspace" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), <<~RUBY)
        class User
          # Finds by email
          def find_by_email(email)
            where(email: email)
          end
        end
      RUBY

      get "/mbeditor/definition", params: { symbol: "find_by_email", language: "ruby" }
      assert_response :ok

      data = JSON.parse(response.body)
      assert data["results"].length >= 1

      first = data["results"][0]
      assert_includes first["file"], "user.rb"
      assert_equal 3, first["line"]
      assert_includes first["signature"], "def find_by_email"
      assert_includes first["comments"], "Finds by email"
    end

    test "definition returns empty results when symbol not found" do
      get "/mbeditor/definition", params: { symbol: "totally_missing_xyz", language: "ruby" }
      assert_response :ok
      data = JSON.parse(response.body)
      assert_equal [], data["results"]
    end

    test "definition response includes a 'results' array for Ruby" do
      get "/mbeditor/definition", params: { symbol: "puts", language: "ruby" }
      assert_response :ok
      data = JSON.parse(response.body)
      assert data.key?("results"), "Response must have a 'results' key"
      assert_kind_of Array, data["results"]
    end

    test "definition workspace results appear before ri results when both present" do
      # Override RiDefinitionService.call to inject a known ri result without
      # spawning a subprocess, using simple method aliasing.
      ri_result = [{ file: "ruby core", line: 0, signature: "my_ws_symbol() -> nil", comments: "" }]

      File.write(File.join(@workspace, "app", "models", "user.rb"), <<~RUBY)
        class User
          def my_ws_symbol; end
        end
      RUBY

      original = RiDefinitionService.method(:call)
      RiDefinitionService.singleton_class.remove_method(:call)
      RiDefinitionService.define_singleton_method(:call) { |_sym| ri_result }
      begin
        get "/mbeditor/definition", params: { symbol: "my_ws_symbol", language: "ruby" }
        assert_response :ok
        data = JSON.parse(response.body)
        results = data["results"]
        assert results.length >= 2, "Expected workspace + ri results"
        # All workspace results (line > 0) must precede ri results (line == 0)
        first_ri_index = results.index { |r| r["line"] == 0 }
        last_ws_index  = results.rindex { |r| r["line"] > 0 }
        assert last_ws_index < first_ri_index, "Workspace results must come before ri results"
      ensure
        RiDefinitionService.singleton_class.remove_method(:call)
        RiDefinitionService.define_singleton_method(:call, &original)
      end
    end

    # ---------------------------------------------------------------------------
    # index (HTML smoke test)
    # ---------------------------------------------------------------------------

    test "index renders the IDE shell as HTML" do
      get "/mbeditor"
      assert_response :ok
      assert_includes response.content_type, "text/html"
      assert_match "mbeditor", response.body
    end

    test "manifest endpoint returns valid manifest json" do
      get "/mbeditor/manifest.webmanifest"

      assert_response :ok
      assert_equal "application/manifest+json; charset=utf-8", response.content_type

      manifest = JSON.parse(response.body)
      assert_equal "/mbeditor/", manifest.fetch("start_url")
      assert_equal "/mbeditor/", manifest.fetch("scope")
      assert_equal "/mbeditor/mbeditor-icon.svg", manifest.fetch("icons").first.fetch("src")
    end

    test "manifest urls are absolute when SCRIPT_NAME lacks a leading slash" do
      get "/mbeditor/manifest.webmanifest", headers: { "SCRIPT_NAME" => "mbeditor" }

      assert_response :ok
      manifest = JSON.parse(response.body)
      assert manifest.fetch("start_url").start_with?("/"), "start_url must be an absolute path"
      assert manifest.fetch("scope").start_with?("/"), "scope must be an absolute path"
      assert manifest.fetch("icons").first.fetch("src").start_with?("/"), "icon src must be an absolute path"
    end

    test "service worker avoids no-op fetch handler" do
      get "/mbeditor/sw.js"

      assert_response :ok
      assert_includes response.content_type, "application/javascript"
      refute_includes response.body, "addEventListener('fetch'"
      assert_includes response.body, "addEventListener('install'"
      assert_includes response.body, "addEventListener('activate'"
    end

    # ---------------------------------------------------------------------------
    # git_status
    # ---------------------------------------------------------------------------

    test "git_status returns expected JSON keys" do
      get "/mbeditor/git_status"
      assert_response :ok
      assert json.key?("ok")
      assert json.key?("files")
      assert json.key?("branch")
      assert_kind_of Array, json["files"]
    end

    test "git_status routes its git subprocess through ProcessRunner with configured timeout" do
      original = Mbeditor.configuration.git_timeout
      Mbeditor.configuration.git_timeout = 7

      captured = []
      with_process_runner_recorder(captured) { get "/mbeditor/git_status" }
      assert_response :ok

      status_call = captured.find { |c| c[:cmd].include?("status") }
      refute_nil status_call,
                 "expected `git status` to run through ProcessRunner, " \
                 "but it bypassed the timeout mechanism"
      assert_equal 7, status_call[:timeout],
                   "expected the configured git_timeout to be applied to the git_status call"
    ensure
      Mbeditor.configuration.git_timeout = original
    end

    # ---------------------------------------------------------------------------
    # git_info
    # ---------------------------------------------------------------------------

    test "git_info returns error JSON in a non-git workspace" do
      get "/mbeditor/git_info"
      assert_response :ok
      assert_equal false, json["ok"]
      assert json.key?("error")
    end

    # ---------------------------------------------------------------------------
    # lint
    # ---------------------------------------------------------------------------

    test "lint returns 403 for path traversal" do
      post "/mbeditor/lint", params: { path: "../../evil.rb", code: "x = 1" }, as: :json
      assert_response :forbidden
    end

    test "lint returns markers array for a valid Ruby file" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }
      post "/mbeditor/lint",
           params: { path: "app/models/user.rb", code: "class User; end\n" },
           as: :json
      assert_response :ok
      assert json.key?("markers"), "response should have markers key"
      assert_kind_of Array, json["markers"]
    end

    test "lint returns empty markers for clean Ruby code" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }
      clean_code = "# frozen_string_literal: true\n\nclass User\nend\n"
      post "/mbeditor/lint",
           params: { path: "app/models/user.rb", code: clean_code },
           as: :json
      assert_response :ok
      assert_equal [], json["markers"]
    end

    test 'lint returns error when rubocop command times out' do
      # Use a temp script file so Ruby treats the appended RuboCop flags (e.g.
      # --no-server) as ARGV rather than trying to parse them as Ruby options,
      # which would cause immediate exit instead of sleeping.
      script = Tempfile.new(['fake_rubocop', '.rb'])
      script.write("sleep\n")
      script.flush

      Mbeditor.configure { |c| c.rubocop_command = "ruby #{script.path}"; c.lint_timeout = 2 }

      post '/mbeditor/lint',
           params: { path: 'app/models/user.rb', code: 'class User; end' },
           as: :json

      assert_response :unprocessable_content
      assert_match(/timed out/i, json['error'])
    ensure
      Mbeditor.configure { |c| c.rubocop_command = 'rubocop'; c.lint_timeout = 15 }
      script&.close!
    end

    # ---------------------------------------------------------------------------
    # lint (HAML)
    # ---------------------------------------------------------------------------

    test "lint returns 403 for path traversal on haml file" do
      post "/mbeditor/lint", params: { path: "../../evil.haml", code: "%p Hello" }, as: :json
      assert_response :forbidden
    end

    test "workspace includes hamlLintAvailable key" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert json.key?("hamlLintAvailable"), "workspace should include hamlLintAvailable"
      assert_includes [true, false], json["hamlLintAvailable"]
    end

    test "lint returns markers array for a haml file when haml-lint is available" do
      skip "haml-lint not installed" unless system("haml-lint --version > /dev/null 2>&1")

      FileUtils.mkdir_p(File.join(@workspace, "app", "views"))
      File.write(File.join(@workspace, "app", "views", "index.haml"), "%p Hello\n")

      post "/mbeditor/lint",
           params: { path: "app/views/index.haml", code: "%p Hello\n" },
           as: :json
      assert_response :ok
      assert json.key?("markers"), "response should have markers key"
      assert_kind_of Array, json["markers"]
    end

    test "lint returns error when haml-lint not available for haml files" do
      # Temporarily make haml-lint appear unavailable by using a workspace where
      # the path is valid but haml-lint binary check would fail — we test the
      # error response path via stubbing the availability check
      skip "haml-lint is installed; cannot test unavailable path" if system("haml-lint --version > /dev/null 2>&1")

      FileUtils.mkdir_p(File.join(@workspace, "app", "views"))
      File.write(File.join(@workspace, "app", "views", "index.haml"), "%p Hello\n")

      post "/mbeditor/lint",
           params: { path: "app/views/index.haml", code: "%p Hello\n" },
           as: :json
      assert_response :unprocessable_content
      assert json.key?("error")
    end

    # ---------------------------------------------------------------------------
    # format_file
    # ---------------------------------------------------------------------------

    test "format_file returns 403 for path traversal" do
      post "/mbeditor/format", params: { path: "../../evil.rb" }, as: :json
      assert_response :forbidden
    end

    test "format_file returns corrected content for a Ruby file" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }
      unformatted = "x=1\n"
      File.write(File.join(@workspace, "app", "models", "user.rb"), unformatted)

      post "/mbeditor/format", params: { path: "app/models/user.rb", code: unformatted }, as: :json
      assert_response :ok
      assert json.key?("content"), "response should have content key"
      assert_kind_of String, json["content"]
      # Verify the original file on disk is NOT modified (format is buffer-only)
      assert_equal unformatted, File.read(File.join(@workspace, "app", "models", "user.rb"))
    end

    test "format_file returns 422 when code param is missing" do
      post "/mbeditor/format", params: { path: "app/models/user.rb" }, as: :json
      assert_response :unprocessable_content
    end

    # ---------------------------------------------------------------------------
    # quick_fix
    # ---------------------------------------------------------------------------

    test "quick_fix returns 403 for path traversal" do
      post "/mbeditor/quick_fix",
           params: { path: "../../evil.rb", code: "x=1\n", cop_name: "Style/StringLiterals" },
           as: :json
      assert_response :forbidden
    end

    test "quick_fix returns 422 when cop_name is missing" do
      post "/mbeditor/quick_fix",
           params: { path: "app/models/user.rb", code: "x=1\n" },
           as: :json
      assert_response :unprocessable_content
      assert json.key?("error")
    end

    test "quick_fix returns 422 for an invalid cop_name" do
      post "/mbeditor/quick_fix",
           params: { path: "app/models/user.rb", code: "x=1\n", cop_name: "../../etc/passwd" },
           as: :json
      assert_response :unprocessable_content
      assert_match(/invalid cop name/i, json["error"])
    end

    test "quick_fix returns a text edit for an autocorrectable offense" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }
      # Style/StringLiterals flags double quotes; autocorrect converts them to single quotes
      code = "x = \"hello\"\n"
      post "/mbeditor/quick_fix",
           params: { path: "app/models/user.rb", code: code, cop_name: "Style/StringLiterals" },
           as: :json
      assert_response :ok
      fix = json["fix"]
      # If rubocop considers this correctable we get a fix; if the workspace .rubocop.yml
      # disables the cop or prefers double quotes we get nil — both are valid responses.
      if fix
        assert fix.key?("startLine"), "fix should have startLine"
        assert fix.key?("startCol"),  "fix should have startCol"
        assert fix.key?("endLine"),   "fix should have endLine"
        assert fix.key?("endCol"),    "fix should have endCol"
        assert fix.key?("replacement"), "fix should have replacement"
        assert_kind_of Integer, fix["startLine"]
        assert_kind_of String,  fix["replacement"]
      end
    ensure
      Mbeditor.configure { |c| c.rubocop_command = "rubocop" }
    end

    test "quick_fix returns nil fix when cop produces no change" do
      Mbeditor.configure { |c| c.rubocop_command = "bundle exec rubocop" }
      # Already clean; autocorrect should produce no diff
      clean_code = "# frozen_string_literal: true\n\nx = 'hello'\n"
      post "/mbeditor/quick_fix",
           params: { path: "app/models/user.rb", code: clean_code, cop_name: "Style/StringLiterals" },
           as: :json
      assert_response :ok
      # fix may be nil (no change) or a valid edit if the cop finds something;
      # the response must be well-formed either way.
      assert json.key?("fix"), "response should always have a 'fix' key"
    ensure
      Mbeditor.configure { |c| c.rubocop_command = "rubocop" }
    end

    # ---------------------------------------------------------------------------
    # monaco_asset
    # ---------------------------------------------------------------------------

    test "monaco_asset serves the main editor bundle" do
      get "/mbeditor/monaco-editor/monaco.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset returns 404 for a missing file" do
      get "/mbeditor/monaco-editor/nonexistent.js"
      assert_response :not_found
    end

    test "monaco_asset returns 404 for a path traversal attempt" do
      get "/mbeditor/monaco-editor/../../etc/passwd"
      assert_response :not_found
    end

    test "monaco_asset serves the editor web worker" do
      get "/mbeditor/monaco-editor/editor.worker.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset serves the TypeScript web worker" do
      get "/mbeditor/monaco-editor/ts.worker.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset serves the editor stylesheet" do
      get "/mbeditor/monaco-editor/monaco.css"
      assert_response :ok
      assert_includes response.content_type, "css"
    end

    test "monaco_asset serves the bundled monaco-vim" do
      get "/mbeditor/monaco-editor/monaco-vim.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    # ---------------------------------------------------------------------------
    # run_test
    # ---------------------------------------------------------------------------

    test "run_test returns 403 for path traversal" do
      post "/mbeditor/test", params: { path: "../../etc/passwd" }, as: :json
      assert_response :forbidden
    end

    test "run_test rejects a non-numeric line" do
      FileUtils.mkdir_p(File.join(@workspace, "test"))
      File.write(File.join(@workspace, "test", "direct_test.rb"), "require \"minitest/autorun\"\n")

      post "/mbeditor/test", params: { path: "test/direct_test.rb", line: "3; rm -rf /" }, as: :json
      assert_response :bad_request
      assert_equal "Invalid line", json["error"]
    end

    test "run_test reports the filtered line when running a test file at a cursor" do
      FileUtils.mkdir_p(File.join(@workspace, "test"))
      File.write(File.join(@workspace, "test", "direct_test.rb"), <<~RUBY)
        require "minitest/autorun"

        class DirectTest < Minitest::Test
          def test_one
            assert true
          end

          def test_two
            assert true
          end
        end
      RUBY

      post "/mbeditor/test", params: { path: "test/direct_test.rb", line: 5 }, as: :json
      assert_response :ok
      assert_equal 5, json["filteredLine"]
      assert_equal 1, json.dig("summary", "total"), "only the test at the cursor should run"
    end

    test "run_test ignores a line when resolving from a source file" do
      FileUtils.mkdir_p(File.join(@workspace, "test", "models"))
      File.write(File.join(@workspace, "test", "models", "user_test.rb"), <<~RUBY)
        require "minitest/autorun"

        class UserTest < Minitest::Test
          def test_one
            assert true
          end
        end
      RUBY

      post "/mbeditor/test", params: { path: "app/models/user.rb", line: 4 }, as: :json
      assert_response :ok
      assert_nil json["filteredLine"], "a line in the source file cannot filter the test file"
    end

    test "run_test returns 404 when no matching test file exists" do
      post "/mbeditor/test", params: { path: "app/models/user.rb" }, as: :json
      assert_response :not_found
      assert_match(/no matching test file/i, json["error"])
    end

    test "run_test runs a test file when it exists" do
      # Create a simple minitest file
      FileUtils.mkdir_p(File.join(@workspace, "test", "models"))
      test_content = <<~RUBY
        require "minitest/autorun"

        class UserTest < Minitest::Test
          def test_truth
            assert true
          end
        end
      RUBY
      File.write(File.join(@workspace, "test", "models", "user_test.rb"), test_content)

      post "/mbeditor/test", params: { path: "app/models/user.rb" }, as: :json
      assert_response :ok
      assert json.key?("ok"), "response should have ok key"
      assert json.key?("summary"), "response should have summary key"
      assert json.key?("testFile"), "response should have testFile key"
      assert_equal "test/models/user_test.rb", json["testFile"]
    end

    test "run_test runs a test file directly when opened" do
      FileUtils.mkdir_p(File.join(@workspace, "test"))
      test_content = <<~RUBY
        require "minitest/autorun"

        class DirectTest < Minitest::Test
          def test_passes
            assert_equal 1, 1
          end
        end
      RUBY
      File.write(File.join(@workspace, "test", "direct_test.rb"), test_content)

      post "/mbeditor/test", params: { path: "test/direct_test.rb" }, as: :json
      assert_response :ok
      assert_equal true, json["ok"]
      assert_equal "test/direct_test.rb", json["testFile"]
    end

    test "workspace includes testAvailable flag" do
      get "/mbeditor/workspace"
      assert_response :ok
      assert json.key?("testAvailable"), "testAvailable missing from workspace response"
      assert_includes [true, false], json["testAvailable"]
    end

    test "workspace testAvailable is true when test directory exists" do
      FileUtils.mkdir_p(File.join(@workspace, "test"))
      get "/mbeditor/workspace"
      assert_response :ok
      assert_equal true, json["testAvailable"]
    end

    # ---------------------------------------------------------------------------
    # Environment gating
    # ---------------------------------------------------------------------------

    test "returns 404 when current environment is not in allowed_environments" do
      Mbeditor.configure { |c| c.allowed_environments = [:production] }
      get "/mbeditor/ping"
      assert_response :not_found
    ensure
      Mbeditor.configure { |c| c.allowed_environments = %i[test development] }
    end

    # ---------------------------------------------------------------------------
    # replace_in_files (POST /replace_in_files) — HTTP-level only
    # ---------------------------------------------------------------------------

    test "replace_in_files returns 200 with expected JSON shape" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User\n  ROLE = 'admin'\nend\n")
      post "/mbeditor/replace_in_files", params: { query: "admin", replacement: "superuser" }, as: :json
      assert_response :ok
      assert json.key?("replaced_count")
      assert json.key?("files_affected")
      assert json.key?("errors")
      assert json.key?("partial")
    end

    test "replace_in_files returns 400 for blank query" do
      post "/mbeditor/replace_in_files", params: { query: "", replacement: "x" }, as: :json
      assert_response :bad_request
      assert_match(/required/i, json["error"])
    end

    test "replace_in_files returns 400 for query longer than 500 chars" do
      post "/mbeditor/replace_in_files", params: { query: "a" * 501, replacement: "x" }, as: :json
      assert_response :bad_request
      assert_match(/too long/i, json["error"])
    end

    test "replace_in_files returns 403 without X-Mbeditor-Client header" do
      File.write(File.join(@workspace, "README.md"), "hello\n")
      # Post directly without the auto-added header by calling ActionDispatch directly
      ActionDispatch::Integration::Session.new(Rails.application).tap do |sess|
        sess.post "/mbeditor/replace_in_files", params: { query: "hello", replacement: "world" }, as: :json
        assert_equal 403, sess.response.status
      end
    end

    test "replace_in_files returns 422 when too many files matched" do
      original = Mbeditor::SearchReplaceService::MAX_REPLACE_FILES
      $VERBOSE = nil
      Mbeditor::SearchReplaceService.send(:remove_const, :MAX_REPLACE_FILES)
      Mbeditor::SearchReplaceService.const_set(:MAX_REPLACE_FILES, 0)
      $VERBOSE = true

      File.write(File.join(@workspace, "README.md"), "hello\n")
      post "/mbeditor/replace_in_files", params: { query: "hello", replacement: "world" }, as: :json
      assert_response :unprocessable_entity
      assert_match(/too many files/i, json["error"])
    ensure
      $VERBOSE = nil
      Mbeditor::SearchReplaceService.send(:remove_const, :MAX_REPLACE_FILES)
      Mbeditor::SearchReplaceService.const_set(:MAX_REPLACE_FILES, original)
      $VERBOSE = true
    end

    # ---------------------------------------------------------------------------
    # related_files
    # ---------------------------------------------------------------------------

    test "related_files returns 400 for missing path param" do
      get "/mbeditor/related_files"
      assert_response :bad_request
    end

    test "related_files returns empty hash for non-Rails path" do
      get "/mbeditor/related_files", params: { path: "README.md" }
      assert_response :ok
      assert_equal({}, json)
    end

    test "related_files returns model group when model file exists" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "controllers"))
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      get "/mbeditor/related_files", params: { path: "app/controllers/users_controller.rb" }
      assert_response :ok
      assert json.key?("model"), "expected model group"
      assert_equal "app/models/user.rb", json["model"].first["path"]
    end

    test "related_files returns views group with sorted children" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "views", "users"))
      File.write(File.join(@workspace, "app", "views", "users", "index.html.erb"), "")
      File.write(File.join(@workspace, "app", "views", "users", "show.html.erb"), "")
      get "/mbeditor/related_files", params: { path: "app/controllers/users_controller.rb" }
      assert_response :ok
      assert json.key?("views")
      names = json["views"].map { |e| e["name"] }
      assert_equal %w[index.html.erb show.html.erb], names
    end

    test "related_files omits groups with no existing files" do
      # No related files exist for this controller path
      get "/mbeditor/related_files", params: { path: "app/controllers/things_controller.rb" }
      assert_response :ok
      assert_equal({}, json)
    end

    test "related_files uses configured related_files_custom_paths" do
      base = "app/assets/javascripts/ux"
      FileUtils.mkdir_p(File.join(@workspace, base, "users"))
      File.write(File.join(@workspace, base, "users", "index.js"), "")
      Mbeditor.configure { |c| c.related_files_custom_paths = [base] }
      get "/mbeditor/related_files", params: { path: "app/controllers/users_controller.rb" }
      assert_response :ok
      assert json.key?("custom")
      assert json["custom"].key?(base)
      assert_equal "index.js", json["custom"][base].first["name"]
    ensure
      Mbeditor.configure { |c| c.related_files_custom_paths = [] }
    end

    test "client_config returns 200 with related_files_custom_paths" do
      Mbeditor.configure { |c| c.related_files_custom_paths = ["app/javascript/components"] }
      get "/mbeditor/client_config"
      assert_response :ok
      assert json.key?("related_files_custom_paths")
      assert_includes json["related_files_custom_paths"], "app/javascript/components"
    ensure
      Mbeditor.configure { |c| c.related_files_custom_paths = [] }
    end

    # ---------------------------------------------------------------------------
    # Origin / Referer validation (CSRF defense-in-depth) — issue #75
    # ---------------------------------------------------------------------------

    test "non-GET request with cross-origin Origin header is forbidden" do
      post "/mbeditor/state",
           params: { state: { openTabs: ["foo.rb"] } },
           as: :json,
           headers: { "HTTP_ORIGIN" => "http://evil.example.com" }
      assert_response :forbidden
    end

    test "non-GET request with same-origin Origin header is allowed" do
      post "/mbeditor/state",
           params: { state: { openTabs: ["foo.rb"] } },
           as: :json,
           headers: { "HTTP_ORIGIN" => "http://www.example.com" }
      assert_response :ok
      assert_equal true, json["ok"]
    end

    test "non-GET request with cross-origin Referer (no Origin) is forbidden" do
      post "/mbeditor/state",
           params: { state: { openTabs: ["foo.rb"] } },
           as: :json,
           headers: { "HTTP_REFERER" => "http://evil.example.com/page" }
      assert_response :forbidden
    end

    test "non-GET request with same-origin Referer (no Origin) is allowed" do
      post "/mbeditor/state",
           params: { state: { openTabs: ["foo.rb"] } },
           as: :json,
           headers: { "HTTP_REFERER" => "http://www.example.com/mbeditor" }
      assert_response :ok
      assert_equal true, json["ok"]
    end

    test "non-GET request with neither Origin nor Referer is allowed" do
      post "/mbeditor/state",
           params: { state: { openTabs: ["foo.rb"] } },
           as: :json
      assert_response :ok
      assert_equal true, json["ok"]
    end

    # ---------------------------------------------------------------------------
    # import
    # ---------------------------------------------------------------------------

    # Rack::Test::UploadedFile needs a file on disk; @upload_dir holds the
    # sources so they are never confused with workspace contents.
    def uploaded(name, content)
      @upload_dir ||= Dir.mktmpdir("mbeditor_uploads_")
      source = File.join(@upload_dir, name)
      FileUtils.mkdir_p(File.dirname(source))
      File.binwrite(source, content)
      ::Rack::Test::UploadedFile.new(source, "application/octet-stream", true)
    end

    test "import writes a dropped file into the workspace" do
      post "/mbeditor/import", params: {
        files: [uploaded("notes.txt", "hello")],
        paths: ["notes.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal ["notes.txt"], json["imported"].map { |e| e["path"] }
      assert_empty json["conflicts"]
      assert_empty json["errors"]
      assert_equal "hello", File.read(File.join(@workspace, "notes.txt"))
    end

    test "import preserves binary content byte for byte" do
      bytes = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".dup.force_encoding(Encoding::BINARY)

      post "/mbeditor/import", params: {
        files: [uploaded("logo.png", bytes)],
        paths: ["app/assets/logo.png"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal bytes, File.binread(File.join(@workspace, "app/assets/logo.png"))
    end

    test "import reports an existing target as a conflict without writing it" do
      post "/mbeditor/import", params: {
        files: [uploaded("README.md", "replacement")],
        paths: ["README.md"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal ["README.md"], json["conflicts"].map { |e| e["path"] }
      assert_equal "# Hello\n", File.read(File.join(@workspace, "README.md"))
    end

    test "import overwrites when asked to" do
      post "/mbeditor/import", params: {
        files: [uploaded("README.md", "replacement")],
        paths: ["README.md"],
        on_conflict: "overwrite"
      }

      assert_response :ok
      assert_equal ["README.md"], json["imported"].map { |e| e["path"] }
      assert_equal "replacement", File.read(File.join(@workspace, "README.md"))
    end

    test "import rejects a path outside the workspace as an entry error" do
      post "/mbeditor/import", params: {
        files: [uploaded("evil.txt", "x")],
        paths: ["../evil.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_empty json["imported"]
      assert_equal ["../evil.txt"], json["errors"].map { |e| e["path"] }
    end

    test "import rejects an excluded path as an entry error" do
      post "/mbeditor/import", params: {
        files: [uploaded("cache.txt", "x")],
        paths: ["tmp/cache.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_empty json["imported"]
      assert_equal ["tmp/cache.txt"], json["errors"].map { |e| e["path"] }
      refute File.exist?(File.join(@workspace, "tmp", "cache.txt"))
    end

    # File.expand_path raises ArgumentError on a null byte. Before resolve_path
    # rescued it, that escaped the per-entry loop and the blanket rescue turned
    # the whole drop into a 422 — one malformed name losing every good file.
    test "import isolates a null-byte path to its own entry error" do
      post "/mbeditor/import", params: {
        files: [uploaded("good.txt", "kept"), uploaded("weird.txt", "x")],
        paths: ["good.txt", "we\0ird.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal ["good.txt"], json["imported"].map { |e| e["path"] }
      assert_equal ["we\0ird.txt"], json["errors"].map { |e| e["path"] }
      assert_equal "kept", File.read(File.join(@workspace, "good.txt"))
    end

    test "import without the client header is forbidden" do
      # Bypass the header-injecting override defined at the top of this class.
      # Going straight to the session skips the copy-back that populates
      # @response for assert_response, so assert on the session's own response.
      integration_session.post "/mbeditor/import", params: {
        files: [uploaded("notes.txt", "hello")],
        paths: ["notes.txt"]
      }

      assert_equal 403, integration_session.response.status
      refute File.exist?(File.join(@workspace, "notes.txt"))
    end

    test "import rejects a batch whose files and paths lengths differ" do
      post "/mbeditor/import", params: {
        files: [uploaded("a.txt", "a")],
        paths: ["a.txt", "b.txt"],
        on_conflict: "ask"
      }

      assert_response :unprocessable_content
      assert_match(/same length/, json["error"])
    end

    test "import rejects an unknown conflict mode" do
      post "/mbeditor/import", params: {
        files: [uploaded("a.txt", "a")],
        paths: ["a.txt"],
        on_conflict: "clobber"
      }

      assert_response :unprocessable_content
      assert_equal "Unknown on_conflict: clobber", json["error"]
      refute File.exist?(File.join(@workspace, "a.txt"))
    end

    test "import rejects values that are not uploaded files" do
      post "/mbeditor/import", params: {
        files: ["not-an-upload"],
        paths: ["a.txt"],
        on_conflict: "ask"
      }

      assert_response :unprocessable_content
      assert_equal "files must be uploaded files", json["error"]
      refute File.exist?(File.join(@workspace, "a.txt"))
    end

    # 101 file parts stays under Rack's multipart_part_limit of 128, so the
    # request reaches the action and the guard answers with a real 422. Raising
    # IMPORT_MAX_FILES to 128 or beyond would make this a 500 instead.
    test "import rejects a batch over the file count limit" do
      count = EditorsController::IMPORT_MAX_FILES + 1
      files = Array.new(count) { |i| uploaded("f#{i}.txt", "x") }
      paths = Array.new(count) { |i| "f#{i}.txt" }

      post "/mbeditor/import", params: { files: files, paths: paths, on_conflict: "ask" }

      assert_response :unprocessable_content
      assert_match(/Too many files/, json["error"])
      refute File.exist?(File.join(@workspace, "f0.txt"))
    end

    test "import rejects a batch over the total size limit" do
      # Two files of 30 MB each clear the per-file 5 MB check only because the
      # batch guard runs first — this asserts the batch guard, not the entry one.
      chunk = "x" * (30 * 1024 * 1024)

      post "/mbeditor/import", params: {
        files: [uploaded("big1.bin", chunk), uploaded("big2.bin", chunk)],
        paths: ["big1.bin", "big2.bin"],
        on_conflict: "ask"
      }

      assert_response :unprocessable_content
      assert_match(/too large/i, json["error"])
    end

    test "import rejects an empty batch" do
      post "/mbeditor/import", params: { on_conflict: "ask" }

      assert_response :unprocessable_content
      assert_match(/Nothing to import/, json["error"])
    end

    # ── model_schema ─────────────────────────────────────────────────────────

    SCHEMA_RB = <<~RUBY
      ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.index ["email"], name: "index_users_on_email", unique: true
        end
      end
    RUBY

    def write_schema_rb
      FileUtils.mkdir_p(File.join(@workspace, "db"))
      File.write(File.join(@workspace, "db", "schema.rb"), SCHEMA_RB)
    end

    test "model_schema returns the table for a known model" do
      write_schema_rb

      get "/mbeditor/model_schema", params: { model: "User" }

      assert_response :success
      assert_equal "users", json["table"]
      assert_equal "User", json["model"]
      assert_equal ["email"], json["columns"].map { |c| c["name"] }
      assert_equal true, json["indexes"].first["unique"]
    end

    test "model_schema honours an explicit self.table_name in the model file" do
      write_schema_rb
      File.write(File.join(@workspace, "app", "models", "user.rb"),
                 "class User\n  self.table_name = \"users\"\nend\n")

      get "/mbeditor/model_schema", params: { model: "User" }

      assert_response :success
      assert_equal "users", json["table"]
    end

    test "model_schema is 404 when the table is not in the schema" do
      write_schema_rb

      get "/mbeditor/model_schema", params: { model: "Nonexistent" }

      assert_response :not_found
      assert_match(/No schema found/, json["error"])
    end

    test "model_schema is 400 when the model is blank" do
      get "/mbeditor/model_schema", params: { model: "  " }

      assert_response :bad_request
    end

    # The model name is interpolated into app/models/<underscored>.rb, and
    # Inflector.underscore leaves "../" untouched. Without a constant-name
    # check the parameter is a filesystem path.
    test "model_schema rejects a traversing model name" do
      write_schema_rb

      ["../../../../etc/passwd", "../../config/master", "..%2f..%2fsecret",
       "/etc/passwd", "user; rm -rf /"].each do |evil|
        get "/mbeditor/model_schema", params: { model: evil }

        assert_response :bad_request, "#{evil.inspect} should be refused before it becomes a path"
      end
    end

    test "model_schema accepts a namespaced model name" do
      write_schema_rb
      FileUtils.mkdir_p(File.join(@workspace, "app", "models", "admin"))
      File.write(File.join(@workspace, "app", "models", "admin", "user.rb"),
                 "class Admin::User\n  self.table_name = \"users\"\nend\n")

      get "/mbeditor/model_schema", params: { model: "Admin::User" }

      assert_response :success
      assert_equal "users", json["table"]
    end

    private

    def json
      JSON.parse(response.body)
    end

    # Temporarily wrap ProcessRunner.call so every subprocess invocation is
    # recorded (cmd + timeout) while still delegating to the real runner.
    # Mirrors the recorder used in git_info_service_test.rb (issue #70/#71).
    def with_process_runner_recorder(captured)
      real = ProcessRunner.method(:call)
      verbose = $VERBOSE
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call) do |cmd, **kwargs|
        captured << { cmd: cmd, timeout: kwargs[:timeout] }
        real.call(cmd, **kwargs)
      end
      $VERBOSE = verbose
      yield
    ensure
      $VERBOSE = nil
      ProcessRunner.singleton_class.send(:define_method, :call, real)
      $VERBOSE = verbose
    end
  end
end
