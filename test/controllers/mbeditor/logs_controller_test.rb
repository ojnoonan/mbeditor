# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class LogsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    def log_path
      @log_path
    end

    setup do
      Mbeditor.configure { |c| c.allowed_environments = %i[test development] }
      @log_path = Rails.root.join("log", "#{Rails.env}.log")
      @log_existed = File.exist?(@log_path)
      @log_backup = @log_existed ? File.read(@log_path) : nil
    end

    teardown do
      Mbeditor.configure { |c| c.allowed_environments = %i[test development] }
      if @log_existed
        File.write(@log_path, @log_backup)
      elsif File.exist?(@log_path)
        File.delete(@log_path)
      end
    end

    test "GET /logs/tail returns lines, offset and reset as JSON" do
      File.write(log_path, "alpha\nbravo\n")
      get "/mbeditor/logs/tail"
      assert_response :success
      body = JSON.parse(response.body)
      assert_includes body["lines"], "alpha"
      assert_includes body["lines"], "bravo"
      assert_equal true, body["reset"]
      assert body["offset"].is_a?(Integer)
    end

    test "GET /logs/tail?offset= only returns lines appended after that offset" do
      File.write(log_path, "one\n")
      first = JSON.parse(get_json("/mbeditor/logs/tail"))
      File.open(log_path, "a") { |f| f.write("two\n") }
      second = JSON.parse(get_json("/mbeditor/logs/tail?offset=#{first['offset']}"))
      assert_equal ["two"], second["lines"]
    end

    # The log tail hands out the host's environment log, so it must be behind
    # the same environment gate as every other endpoint — it used to declare
    # none at all and served in production.
    test "GET /logs/tail 404s when the current environment is not allowed" do
      Mbeditor.configure { |c| c.allowed_environments = [:production] }
      get "/mbeditor/logs/tail"
      assert_response :not_found
    end

    test "GET /logs/tail?offset= ignores a negative offset instead of 500ing" do
      File.write(log_path, "alpha\n")
      get "/mbeditor/logs/tail?offset=-5"
      assert_response :success
      assert_includes JSON.parse(response.body)["lines"], "alpha"
    end

    private

    def get_json(path)
      get path
      response.body
    end
  end
end
