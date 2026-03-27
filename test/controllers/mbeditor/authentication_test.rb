# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # Tests for the authenticate_with configuration hook using the session-based
  # proc configured in the dummy app's initializer.
  class AuthenticationTest < ActionDispatch::IntegrationTest
    def setup
      @workspace = File.expand_path("../../..", __dir__)
      Mbeditor.configure do |c|
        c.allowed_environments = %i[test development]
        c.workspace_root       = @workspace
        c.authenticate_with    = proc {
          unless session[:authenticated]
            render plain: "Unauthorized", status: :unauthorized
          end
        }
      end
    end

    def teardown
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    # ── unauthenticated ────────────────────────────────────────────────────────

    test "unauthenticated request to editors endpoint is blocked" do
      get "/mbeditor/ping"
      assert_response :unauthorized
    end

    test "unauthenticated request to git endpoint is blocked" do
      get "/mbeditor/git/commit_graph"
      assert_response :unauthorized
    end

    test "unauthenticated request to files endpoint is blocked" do
      get "/mbeditor/files"
      assert_response :unauthorized
    end

    # ── authenticated ──────────────────────────────────────────────────────────

    test "authenticated request to editors endpoint is allowed" do
      post "/login"
      get "/mbeditor/ping"
      assert_response :ok
    end

    test "authenticated request to git endpoint is allowed" do
      post "/login"
      get "/mbeditor/git/commit_graph"
      assert_response :ok
    end

    test "authenticated request to files endpoint is allowed" do
      post "/login"
      get "/mbeditor/files"
      assert_response :ok
    end

    # ── session lifecycle ──────────────────────────────────────────────────────

    test "logging out blocks subsequent requests" do
      post "/login"
      get "/mbeditor/ping"
      assert_response :ok

      delete "/logout"
      get "/mbeditor/ping"
      assert_response :unauthorized
    end
  end
end
