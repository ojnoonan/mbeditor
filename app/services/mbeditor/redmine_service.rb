# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module Mbeditor
  class RedmineDisabledError < StandardError
    def initialize
      super("Redmine integration is not enabled. Set config.mbeditor.redmine_enabled = true.")
    end
  end

  class RedmineConfigError < StandardError; end

  # Fetches a Redmine issue via the REST API.
  #
  # Only usable when Mbeditor.configuration.redmine_enabled is true.
  #
  # Returns:
  #   {
  #     "id"          => Integer,
  #     "title"       => String,
  #     "description" => String,
  #     "status"      => String,
  #     "author"      => String,
  #     "notes"       => Array<String>
  #   }
  class RedmineService
    TIMEOUT_SECONDS = 5

    attr_reader :issue_id

    def initialize(issue_id:)
      @issue_id = issue_id.to_s
    end

    def call
      raise RedmineDisabledError unless Mbeditor.configuration.redmine_enabled

      config = Mbeditor.configuration
      raise RedmineConfigError, "redmine_url is not configured" if config.redmine_url.blank?
      raise RedmineConfigError, "redmine_api_key is not configured" if config.redmine_api_key.blank?

      fetch_issue(config.redmine_url, config.redmine_api_key)
    end

    private

    def fetch_issue(base_url, api_key)
      uri = URI.parse("#{base_url.chomp('/')}/issues/#{issue_id}.json")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = TIMEOUT_SECONDS
      http.read_timeout = TIMEOUT_SECONDS

      request = Net::HTTP::Get.new(uri.request_uri)
      request["X-Redmine-API-Key"] = api_key
      request["Accept"] = "application/json"

      response = http.request(request)

      raise "Redmine returned HTTP #{response.code} for issue ##{issue_id}" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      issue = data["issue"] || {}

      {
        "id"          => issue["id"],
        "title"       => issue.dig("subject"),
        "description" => issue.dig("description").to_s,
        "status"      => issue.dig("status", "name"),
        "author"      => issue.dig("author", "name"),
        "notes"       => extract_notes(issue)
      }
    end

    def extract_notes(issue)
      journals = issue["journals"] || []
      journals
        .select { |j| j["notes"].to_s.present? }
        .map { |j| { "author" => j.dig("user", "name"), "note" => j["notes"], "date" => j["created_on"] } }
    end
  end
end
