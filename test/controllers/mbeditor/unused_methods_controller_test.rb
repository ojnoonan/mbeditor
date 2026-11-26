# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class UnusedMethodsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @workspace = Dir.mktmpdir("mbeditor_test_")
      FileUtils.mkdir_p(File.join(@workspace, "app", "models"))
      File.write(File.join(@workspace, "app", "models", "user.rb"), "class User\n  def never_called\n  end\nend\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.authenticate_with    = nil
      end
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    test "returns unused methods as JSON" do
      get "/mbeditor/unused_methods"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [{ "file" => "app/models/user.rb", "line" => 2, "name" => "never_called", "kind" => "def", "group" => "User" }], body["methods"]
      assert_equal [{ "path" => "app/models/user.rb", "group" => "User" }], body["files"]
      assert_equal false, body["truncated"]
    end
  end
end
