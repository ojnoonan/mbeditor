# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class MigrationsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @workspace = Dir.mktmpdir("mbeditor_test_")
      FileUtils.mkdir_p(File.join(@workspace, "db", "migrate"))
      File.write(File.join(@workspace, "db", "migrate", "20240101000000_create_users.rb"), "create_table :users\n")
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.authenticate_with    = nil
      end
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    test "returns migrations as JSON" do
      get "/mbeditor/migrations"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal ["20240101000000"], body["migrations"].map { |m| m["version"] }
      assert_includes %w[ok unavailable], body["db"]
    end
  end
end
