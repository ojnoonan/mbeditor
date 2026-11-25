# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class AiRoundTripControllerTest < ActionDispatch::IntegrationTest
    include ActionCable::TestHelper

    PATCH = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"

    def setup
      @workspace = Dir.mktmpdir("mbeditor_test_")
      File.write(File.join(@workspace, "a.txt"), "one\ntwo\n")
      FileUtils.mkdir_p(File.join(@workspace, "lib"))
      File.write(File.join(@workspace, "lib", "b.rb"), "B = 1\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.excluded_paths       = %w[.git tmp log]
        c.authenticate_with    = nil
      end
    end

    def teardown
      FileUtils.rm_rf(@workspace)
      Mbeditor.configure { |c| c.excluded_paths = Configuration.new.excluded_paths }
    end

    def post_patch(check:, patch: PATCH, headers: { "X-Mbeditor-Client" => "1" })
      post "/mbeditor/apply_patch", params: { patch: patch, check: check }, as: :json, headers: headers
    end

    test "ai_bundle downloads markdown with size headers" do
      get "/mbeditor/ai_bundle", params: { paths: ["lib", "a.txt"] }

      assert_response :success
      assert_equal "text/markdown", response.media_type
      assert_match(/attachment; filename="#{File.basename(@workspace)}-bundle\.md"/, response.headers["Content-Disposition"])
      assert_equal "2", response.headers["X-Mbeditor-Bundle-Files"]
      assert_equal response.body.bytesize.to_s, response.headers["X-Mbeditor-Bundle-Bytes"]
      assert_includes response.body, "=== FILE: lib/b.rb (1 lines) ==="
    end

    test "ai_bundle prompt=1 returns the plain-text prompt without needing paths" do
      get "/mbeditor/ai_bundle", params: { prompt: 1 }

      assert_response :success
      assert_equal "text/plain", response.media_type
      assert_includes response.body, "`#{File.basename(@workspace)}-bundle.md` is a large source bundle"
      assert response.body.end_with?("TASK: ")
      refute_includes response.body, "B = 1"
    end

    test "ai_bundle rejects paths outside the workspace" do
      get "/mbeditor/ai_bundle", params: { paths: ["../etc"] }

      assert_response :forbidden
    end

    test "ai_bundle needs paths" do
      get "/mbeditor/ai_bundle"

      assert_response :bad_request
    end

    test "ai_bundle over the cap is 413 with a JSON error" do
      File.write(File.join(@workspace, "big.txt"), "a" * (AiBundleService::MAX_BYTES + 1))
      get "/mbeditor/ai_bundle", params: { paths: ["big.txt"] }

      assert_response :content_too_large
      assert_match(/too large/, JSON.parse(response.body)["error"])
    end

    test "apply_patch check lists files and leaves disk alone" do
      post_patch(check: true)

      assert_response :success
      json = JSON.parse(response.body)
      assert json["ok"]
      assert_equal "a.txt", json["files"].first["path"]
      assert_equal "modified", json["files"].first["status"]
      assert_equal "one\ntwo\n", File.read(File.join(@workspace, "a.txt"))
    end

    test "apply_patch writes and broadcasts files_changed" do
      assert_broadcasts("mbeditor_editor", 1) { post_patch(check: false) }

      assert_response :success
      assert_equal "one\nTWO\n", File.read(File.join(@workspace, "a.txt"))
    end

    test "apply_patch failure is 422 with git's message" do
      post_patch(check: true, patch: PATCH.sub("-two", "-nope"))

      assert_response :unprocessable_content
      assert_match(/patch does not apply/, JSON.parse(response.body)["error"])
    end

    test "apply_patch without the client header is forbidden" do
      integration_session.post "/mbeditor/apply_patch", params: { patch: PATCH, check: false }, as: :json

      assert_equal 403, integration_session.response.status
      assert_equal "one\ntwo\n", File.read(File.join(@workspace, "a.txt"))
    end
  end
end
