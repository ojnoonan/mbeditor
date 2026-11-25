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

    test "ai_bundle part K of N returns that part under a part filename" do
      get "/mbeditor/ai_bundle", params: { paths: ["lib", "a.txt"], parts: 2, part: 2 }

      assert_response :success
      assert_match(/filename="#{File.basename(@workspace)}-bundle-2-of-2\.md"/, response.headers["Content-Disposition"])
      assert_includes response.body, "(part 2 of 2)"
      assert_equal "1", response.headers["X-Mbeditor-Bundle-Files"]
      assert_includes response.body, "=== FILE: lib/b.rb "
      refute_includes response.body, "=== FILE: a.txt "
    end

    test "ai_bundle rejects bad parts and part values" do
      [{ parts: 4 }, { parts: 0 }, { parts: 2, part: 3 }, { parts: 2, part: 0 }].each do |extra|
        get "/mbeditor/ai_bundle", params: { paths: ["a.txt"] }.merge(extra)

        assert_response :bad_request, extra.inspect
      end
    end

    test "ai_bundle prompt=1 with parts names every part" do
      get "/mbeditor/ai_bundle", params: { prompt: 1, parts: 3 }

      assert_response :success
      assert_includes response.body, "-bundle-1-of-3.md"
      assert_includes response.body, "-bundle-3-of-3.md"
      assert_includes response.body, "Upload all 3"
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

    test "ai_bundle 404 names the relative path that was not found" do
      get "/mbeditor/ai_bundle", params: { paths: ["lib", "gone_dir"] }

      assert_response :not_found
      assert_equal "Not found: gone_dir", JSON.parse(response.body)["error"]
    end

    test "archive 404 names the relative path that was not found" do
      get "/mbeditor/archive", params: { paths: ["gone_dir"] }

      assert_response :not_found
      assert_equal "Not found: gone_dir", JSON.parse(response.body)["error"]
    end

    test "ai_bundle never lists secrets with content" do
      File.write(File.join(@workspace, ".env"), "TOPSECRET=1\n")
      get "/mbeditor/ai_bundle", params: { paths: [".", "a.txt"] }

      assert_response :success
      refute_includes response.body, "TOPSECRET"
      assert_includes response.body, "- .env skipped (secret)"
    end

    test "ai_bundle error for an unreadable file carries no absolute path" do
      skip "root can read anything" if Process.uid.zero?
      full = File.join(@workspace, "locked.txt")
      File.write(full, "x")
      File.chmod(0, full)
      get "/mbeditor/ai_bundle", params: { paths: ["locked.txt"] }

      assert_response :unprocessable_content
      refute_includes response.body, @workspace
      assert_includes response.body, "locked.txt"
    ensure
      File.chmod(0o644, full) if full
    end

    test "raw sends a sandbox CSP and nosniff, and serves html as text" do
      File.write(File.join(@workspace, "page.html"), "<script>alert(1)</script>")
      get "/mbeditor/raw", params: { path: "page.html" }

      assert_response :success
      assert_equal "sandbox", response.headers["Content-Security-Policy"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_equal "text/plain", response.media_type
    end

    test "raw keeps svg as an image but sandboxed, and html stays html as a download" do
      File.write(File.join(@workspace, "i.svg"), "<svg xmlns='http://www.w3.org/2000/svg'/>")
      File.write(File.join(@workspace, "page.html"), "<p>x</p>")
      get "/mbeditor/raw", params: { path: "i.svg" }

      assert_equal "image/svg+xml", response.media_type
      assert_equal "sandbox", response.headers["Content-Security-Policy"]

      get "/mbeditor/raw", params: { path: "page.html", download: "1" }

      assert_equal "text/html", response.media_type
      assert_equal "sandbox", response.headers["Content-Security-Policy"]
      assert_match(/attachment/, response.headers["Content-Disposition"])
    end

    test "apply_patch refuses a path in excluded_paths on check and on apply" do
      patch = "diff --git a/tmp/x.txt b/tmp/x.txt\nnew file mode 100644\n--- /dev/null\n+++ b/tmp/x.txt\n@@ -0,0 +1 @@\n+x\n"
      [true, false].each do |check|
        post_patch(check: check, patch: patch)

        assert_response :unprocessable_content
        assert_match(/tmp\/x\.txt/, JSON.parse(response.body)["error"])
        refute File.exist?(File.join(@workspace, "tmp", "x.txt"))
      end
    end

    test "apply_patch turns a git timeout into a clear error" do
      original = ProcessRunner.method(:call)
      ProcessRunner.define_singleton_method(:call) { |*, **| raise ProcessRunner::TimeoutError, "boom" }
      begin
        post_patch(check: true)
      ensure
        ProcessRunner.define_singleton_method(:call, original)
      end

      assert_response :unprocessable_content
      assert_match(/timed out/, JSON.parse(response.body)["error"])
    end

    test "import over the size cap is rejected with 413 before parsing" do
      post "/mbeditor/import", params: { on_conflict: "ask" },
                               headers: { "X-Mbeditor-Client" => "1", "CONTENT_LENGTH" => (EditorsController::IMPORT_MAX_TOTAL_BYTES + 10_000_000).to_s }

      assert_response :content_too_large
    end
  end
end
