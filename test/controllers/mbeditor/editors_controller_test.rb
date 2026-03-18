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
        c.allowed_environments = %i[test development]
        c.workspace_root = @workspace
        c.excluded_paths = %w[.git tmp log]
      end
    end

    def teardown
      FileUtils.rm_rf(@workspace)
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

    test "files excludes configured excluded_paths" do
      get "/mbeditor/files"
      assert_response :ok
      names = json.map { |n| n["name"] }
      assert_not_includes names, "tmp"
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

    test "show returns 403 for path traversal attempt" do
      get "/mbeditor/file", params: { path: "../../etc/passwd" }
      assert_response :forbidden
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
      assert_response :unprocessable_entity
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
      assert_response :unprocessable_entity
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
      assert_response :unprocessable_entity
    end

    test "rename returns 403 for path traversal on source" do
      patch "/mbeditor/rename", params: { path: "../../etc/passwd", new_path: "stolen.txt" }, as: :json
      assert_response :forbidden
    end

    test "rename returns 403 for path traversal on target" do
      patch "/mbeditor/rename", params: { path: "README.md", new_path: "../../evil.md" }, as: :json
      assert_response :forbidden
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

    test "destroy_path returns 404 for missing path" do
      delete "/mbeditor/delete", params: { path: "ghost.rb" }, as: :json
      assert_response :not_found
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
      assert_kind_of Array, json
      assert json.any? { |r| r["file"].include?("user.rb") }, "expected user.rb in results"
    end

    # ---------------------------------------------------------------------------
    # reload
    # ---------------------------------------------------------------------------

    test "reload touches tmp/restart.txt" do
      post "/mbeditor/reload"
      assert_response :ok
      assert_equal true, json["ok"]
      assert File.exist?(File.join(@workspace, "tmp", "restart.txt"))
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
      assert_response :unprocessable_entity
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

      post "/mbeditor/format", params: { path: "app/models/user.rb" }, as: :json
      assert_response :ok
      assert json.key?("content"), "response should have content key"
      assert_kind_of String, json["content"]
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

    # ---------------------------------------------------------------------------
    # monaco_worker
    # ---------------------------------------------------------------------------

    test "monaco_worker serves the worker JS file" do
      get "/mbeditor/monaco_worker.js"
      assert_response :ok
      assert_includes response.content_type, "javascript"
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

    private

    def json
      JSON.parse(response.body)
    end
  end
end
