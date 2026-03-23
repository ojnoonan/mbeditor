# frozen_string_literal: true

require "test_helper"
require "open3"

module Mbeditor
  class GitControllerTest < ActionDispatch::IntegrationTest
    def setup
      # Use the actual web-editor repo root as the workspace so that git
      # commands work against a real git repo — the same approach used by
      # the existing git_status / git_info tests in EditorsControllerTest.
      @workspace = File.expand_path("../../..", __dir__) # project root
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.redmine_enabled      = false
      end
    end

    def teardown
      Mbeditor.configure do |c|
        c.redmine_enabled = false
        c.redmine_url     = nil
        c.redmine_api_key = nil
      end
    end

    # ─── git/diff ──────────────────────────────────────────────────────────────

    test "diff returns original and modified keys for a tracked file" do
      get "/mbeditor/git/diff", params: { file: "Gemfile" }
      assert_response :ok
      assert json.key?("original"), "diff should return original"
      assert json.key?("modified"), "diff should return modified"
      assert_kind_of String, json["original"]
      assert_kind_of String, json["modified"]
    end

    test "diff returns 400 when file param is missing" do
      get "/mbeditor/git/diff"
      assert_response :bad_request
      assert json.key?("error")
    end

    test "diff returns 403 for path traversal attempt" do
      get "/mbeditor/git/diff", params: { file: "../../etc/passwd" }
      assert_response :forbidden
    end

    # ─── git/blame ─────────────────────────────────────────────────────────────

    test "blame returns lines array for a tracked file" do
      get "/mbeditor/git/blame", params: { file: "Gemfile" }
      assert_response :ok
      assert json.key?("lines"), "blame should return lines key"
      assert_kind_of Array, json["lines"]

      # Each line should have the expected keys
      line = json["lines"].first
      assert line.key?("line"),    "blame line should have 'line'"
      assert line.key?("sha"),     "blame line should have 'sha'"
      assert line.key?("author"),  "blame line should have 'author'"
      assert line.key?("content"), "blame line should have 'content'"
    end

    test "blame returns 400 when file param is missing" do
      get "/mbeditor/git/blame"
      assert_response :bad_request
    end

    test "blame returns 403 for path traversal" do
      get "/mbeditor/git/blame", params: { file: "../../etc/passwd" }
      assert_response :forbidden
    end

    test "blame returns error for a non-existent file" do
      get "/mbeditor/git/blame", params: { file: "this_file_does_not_exist_at_all.rb" }
      assert_response :unprocessable_entity
      assert json.key?("error")
    end

    # ─── git/file_history ──────────────────────────────────────────────────────

    test "file_history returns commits array for a tracked file" do
      get "/mbeditor/git/file_history", params: { file: "Gemfile" }
      assert_response :ok
      assert json.key?("commits"), "file_history should return commits key"
      assert_kind_of Array, json["commits"]

      commit = json["commits"].first
      assert commit.key?("hash"),   "commit should have 'hash'"
      assert commit.key?("title"),  "commit should have 'title'"
      assert commit.key?("author"), "commit should have 'author'"
      assert commit.key?("date"),   "commit should have 'date'"
    end

    test "file_history returns 400 when file param is missing" do
      get "/mbeditor/git/file_history"
      assert_response :bad_request
    end

    test "file_history returns 403 for path traversal" do
      get "/mbeditor/git/file_history", params: { file: "../../etc/passwd" }
      assert_response :forbidden
    end

    # ─── git/commit_graph ──────────────────────────────────────────────────────

    test "commit_graph returns commits array with expected keys" do
      get "/mbeditor/git/commit_graph"
      assert_response :ok
      assert json.key?("commits"), "commit_graph should return commits key"
      assert_kind_of Array, json["commits"]

      commit = json["commits"].first
      assert commit.key?("hash"),    "commit should have 'hash'"
      assert commit.key?("parents"), "commit should have 'parents'"
      assert commit.key?("title"),   "commit should have 'title'"
      assert commit.key?("author"),  "commit should have 'author'"
      assert commit.key?("date"),    "commit should have 'date'"
      assert commit.key?("isLocal"), "commit should have 'isLocal'"
      assert_kind_of Array, commit["parents"]
    end

    # ─── redmine/issue/:id ─────────────────────────────────────────────────────

    test "redmine_issue returns 503 when redmine_enabled is false" do
      Mbeditor.configure { |c| c.redmine_enabled = false }

      get "/mbeditor/redmine/issue/1"
      assert_response :service_unavailable
      assert json.key?("error")
      assert_match(/disabled/i, json["error"])
    end

    test "redmine_issue returns 422 when enabled but url is missing" do
      Mbeditor.configure do |c|
        c.redmine_enabled = true
        c.redmine_url     = nil
        c.redmine_api_key = "dummy_key"
      end

      get "/mbeditor/redmine/issue/1"
      assert_response :unprocessable_entity
      assert json.key?("error")
    end

    test "redmine_issue returns 422 when enabled but api_key is missing" do
      Mbeditor.configure do |c|
        c.redmine_enabled = true
        c.redmine_url     = "https://redmine.example.com"
        c.redmine_api_key = nil
      end

      get "/mbeditor/redmine/issue/1"
      assert_response :unprocessable_entity
      assert json.key?("error")
    end

    # ─── git/commit_detail ─────────────────────────────────────────────────────

    test "commit_detail returns 400 when sha is missing" do
      get "/mbeditor/git/commit_detail"
      assert_response :bad_request
      assert json.key?("error")
    end

    test "commit_detail returns 400 for invalid non-hex sha" do
      get "/mbeditor/git/commit_detail", params: { sha: "not-valid-sha!!" }
      assert_response :bad_request
      assert_match(/invalid sha/i, json["error"])
    end

    test "commit_detail returns commit metadata and files for a valid sha" do
      sha, = Open3.capture2("git", "-C", @workspace, "log", "-1", "--pretty=format:%H")
      skip "No commits found" if sha.blank?

      get "/mbeditor/git/commit_detail", params: { sha: sha.strip }
      assert_response :ok
      assert json.key?("sha"), "commit_detail should return sha"
      assert json.key?("title")
      assert json.key?("author")
      assert json.key?("date")
      assert json.key?("files")
      assert_kind_of Array, json["files"]
    end

    private

    def json
      JSON.parse(response.body)
    end
  end
end
