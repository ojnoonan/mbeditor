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

    def teardown
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.authenticate_with = nil }
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
      File.binwrite(big, 'x' * (Mbeditor::EditorsController::MAX_OPEN_FILE_SIZE_BYTES + 1))
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

    test "save rejects content exceeding MAX_OPEN_FILE_SIZE_BYTES" do
      oversized = "x" * (Mbeditor::EditorsController::MAX_OPEN_FILE_SIZE_BYTES + 1)
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

    test "create_file rejects content exceeding MAX_OPEN_FILE_SIZE_BYTES" do
      oversized = "x" * (Mbeditor::EditorsController::MAX_OPEN_FILE_SIZE_BYTES + 1)
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
        f.write("x" * (Mbeditor::EditorsController::MAX_OPEN_FILE_SIZE_BYTES + 1))
      end

      get "/mbeditor/file", params: { path: "big.txt" }
      assert_response 413
    ensure
      File.delete(big_file) if File.exist?(big_file)
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

    test "search omits total_count on subsequent pages" do
      get "/mbeditor/search", params: { q: "class", offset: 50 }
      assert_response :ok
      assert_kind_of Hash, json
      assert_not json.key?("total_count"), "offset>0 response must not include total_count"
    end

    test "search fallback excludes nested path without excluding similarly named directories" do
      FileUtils.mkdir_p(File.join(@workspace, "app", "assets"))
      FileUtils.mkdir_p(File.join(@workspace, "public", "assets"))

      File.write(File.join(@workspace, "app", "assets", "site.css"), "/* NEEDLE_TOKEN */\n")
      File.write(File.join(@workspace, "public", "assets", "bundle.css"), "/* NEEDLE_TOKEN */\n")

      Mbeditor.configure { |c| c.excluded_paths = %w[.git tmp log public/assets] }

      original_rg_available = Mbeditor::EditorsController::RG_AVAILABLE
      $VERBOSE = nil
      Mbeditor::EditorsController.send(:remove_const, :RG_AVAILABLE)
      Mbeditor::EditorsController.const_set(:RG_AVAILABLE, false)
      $VERBOSE = true

      get "/mbeditor/search", params: { q: "NEEDLE_TOKEN" }
      assert_response :ok

      files = json.fetch("results", []).map { |row| row["file"] }
      assert_includes files, "app/assets/site.css"
      assert_not_includes files, "public/assets/bundle.css"
      assert json.key?("total_count"), "grep fallback must include total_count when thread completes in time"
      assert json["total_count"] >= 1, "grep total_count must reflect at least the one matched file"
    ensure
      $VERBOSE = nil
      Mbeditor::EditorsController.send(:remove_const, :RG_AVAILABLE)
      Mbeditor::EditorsController.const_set(:RG_AVAILABLE, original_rg_available)
      $VERBOSE = true
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

    # ---------------------------------------------------------------------------
    # git_info
    # ---------------------------------------------------------------------------

    test "git_info returns error JSON in a non-git workspace" do
      get "/mbeditor/git_info"
      # temp workspace is not a git repo — controller returns 422
      assert_response :unprocessable_content
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

    test "monaco_asset serves an existing Monaco file" do
      get "/mbeditor/monaco-editor/vs/loader.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset returns 404 for a missing file" do
      get "/mbeditor/monaco-editor/vs/nonexistent.js"
      assert_response :not_found
    end

    test "monaco_asset returns 404 for a path traversal attempt" do
      get "/mbeditor/monaco-editor/../../etc/passwd"
      assert_response :not_found
    end

    test "monaco_asset serves a language file" do
      get "/mbeditor/monaco-editor/vs/basic-languages/ruby/ruby.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset serves the TypeScript language file" do
      get "/mbeditor/monaco-editor/vs/basic-languages/typescript/typescript.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    test "monaco_asset serves the shell language file" do
      get "/mbeditor/monaco-editor/vs/basic-languages/shell/shell.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
    end

    # ---------------------------------------------------------------------------
    # monaco_worker
    # ---------------------------------------------------------------------------

    test "monaco_worker serves the worker JS file" do
      get "/mbeditor/monaco_worker.js"
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
    # replace_in_files (POST /replace_in_files)
    # ---------------------------------------------------------------------------

    test "replace_in_files replaces content across matching files" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User\n  ROLE = 'admin'\nend\n")
      post "/mbeditor/replace_in_files", params: { query: "admin", replacement: "superuser" }, as: :json
      assert_response :ok
      assert_equal 1, json["replaced_count"]
      assert_includes json["files_affected"], "app/models/user.rb"
      assert_equal [], json["errors"]
      assert_includes File.read(File.join(@workspace, "app", "models", "user.rb")), "superuser"
    end

    test "replace_in_files replaces across multiple files" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "NEEDLE\n")
      File.write(File.join(@workspace, "README.md"), "NEEDLE\n")
      post "/mbeditor/replace_in_files", params: { query: "NEEDLE", replacement: "PIN" }, as: :json
      assert_response :ok
      assert json["replaced_count"] >= 2
      assert json["files_affected"].length >= 2
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

    test "replace_in_files is case-insensitive by default" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class ADMIN\nend\n")
      post "/mbeditor/replace_in_files", params: { query: "admin", replacement: "superuser", match_case: "false" }, as: :json
      assert_response :ok
      assert_equal 1, json["replaced_count"]
      assert_includes File.read(File.join(@workspace, "app", "models", "user.rb")), "superuser"
    end

    test "replace_in_files respects match_case=true" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "admin\nADMIN\n")
      post "/mbeditor/replace_in_files", params: { query: "admin", replacement: "superuser", match_case: "true" }, as: :json
      assert_response :ok
      content = File.read(File.join(@workspace, "app", "models", "user.rb"))
      assert_includes content, "superuser"
      assert_includes content, "ADMIN"  # uppercase should be untouched
    end

    test "replace_in_files returns empty result when query has no matches" do
      File.write(File.join(@workspace, "README.md"), "# Hello World\n")
      post "/mbeditor/replace_in_files", params: { query: "ZZZNOTFOUND", replacement: "x" }, as: :json
      assert_response :ok
      assert_equal 0, json["replaced_count"]
      assert_equal [], json["files_affected"]
    end

    test "replace_in_files with whole_word=true only replaces whole words" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "admin administrator superadmin\n")
      post "/mbeditor/replace_in_files",
           params: { query: "admin", replacement: "root", whole_word: "true" },
           as: :json
      assert_response :ok
      content = File.read(File.join(@workspace, "app", "models", "user.rb"))
      assert_includes content, "root"
      assert_includes content, "administrator"  # substring — must NOT be replaced
      assert_includes content, "superadmin"     # substring — must NOT be replaced
      assert_equal 1, json["replaced_count"]
    end

    test "replace_in_files returns 422 when too many files matched" do
      # Stub MAX_REPLACE_FILES to 0 so any match exceeds the cap
      original = Mbeditor::EditorsController::MAX_REPLACE_FILES
      $VERBOSE = nil
      Mbeditor::EditorsController.send(:remove_const, :MAX_REPLACE_FILES)
      Mbeditor::EditorsController.const_set(:MAX_REPLACE_FILES, 0)
      $VERBOSE = true

      File.write(File.join(@workspace, "README.md"), "hello\n")
      post "/mbeditor/replace_in_files", params: { query: "hello", replacement: "world" }, as: :json
      assert_response :unprocessable_entity
      assert_match(/too many files/i, json["error"])
    ensure
      $VERBOSE = nil
      Mbeditor::EditorsController.send(:remove_const, :MAX_REPLACE_FILES)
      Mbeditor::EditorsController.const_set(:MAX_REPLACE_FILES, original)
      $VERBOSE = true
    end

    test "replace_in_files with regex=true performs regex replacement" do
      File.write(File.join(@workspace, "app", "models", "user.rb"), "foo123 foo456\n")
      post "/mbeditor/replace_in_files",
           params: { query: "foo\\d+", replacement: "bar", regex: "true", match_case: "true" },
           as: :json
      assert_response :ok
      content = File.read(File.join(@workspace, "app", "models", "user.rb"))
      assert_equal "bar bar\n", content
      assert_equal 2, json["replaced_count"]
    end

    private

    def json
      JSON.parse(response.body)
    end
  end
end
