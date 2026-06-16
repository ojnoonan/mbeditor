# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class LogsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
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

    private

    def get_json(path)
      get path
      response.body
    end
  end
end
