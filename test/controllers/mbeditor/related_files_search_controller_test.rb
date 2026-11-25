# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RelatedFilesSearchControllerTest < ActionDispatch::IntegrationTest
    def setup
      @workspace = Dir.mktmpdir("mbeditor_test_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User; end\n")
      FileUtils.mkdir_p(File.join(@workspace, "tmp"))
      File.write(File.join(@workspace, "tmp", "dump.rb"), "User\n")
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

    test "q returns files with reasons and honours exclusions" do
      get "/mbeditor/related_files", params: { q: "User" }
      assert_response :success
      body = JSON.parse(response.body)
      model = body["files"].find { |f| f["path"] == "app/models/user.rb" }
      assert_equal "model", model["reason"]
      assert model["direct"]
      assert_equal [], body["files"].select { |f| f["path"].start_with?("tmp/") }
    end

    test "q that is not a constant is rejected" do
      get "/mbeditor/related_files", params: { q: "../../etc" }
      assert_response :bad_request
    end

    test "path still returns the Rails panel groups" do
      get "/mbeditor/related_files", params: { path: "app/models/user.rb" }
      assert_response :success
      assert JSON.parse(response.body).key?("model")
    end
  end
end
