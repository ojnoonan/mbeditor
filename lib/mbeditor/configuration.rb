module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command,
                  :redmine_enabled, :redmine_url, :redmine_api_key,
                  :test_framework, :test_command, :test_timeout

    def initialize
      @allowed_environments = [:development]
      @workspace_root = nil
      @excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
      @rubocop_command = "rubocop"
      @redmine_enabled  = false
      @redmine_url      = nil
      @redmine_api_key  = nil
      @test_framework   = nil # :minitest or :rspec — auto-detected when nil
      @test_command     = nil # e.g. "bundle exec ruby -Itest" or "bundle exec rspec"
      @test_timeout     = 60  # seconds
    end
  end
end
