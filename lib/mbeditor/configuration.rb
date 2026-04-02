module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command,
                  :redmine_enabled, :redmine_url, :redmine_api_key, :redmine_ticket_source,
                  :test_framework, :test_command, :test_timeout, :git_timeout,
                  :authenticate_with

    def initialize
      @allowed_environments = [:development]
      @workspace_root = nil
      @excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
      @rubocop_command = "rubocop"
      @redmine_enabled       = false
      @redmine_url           = nil
      @redmine_api_key       = nil
      @redmine_ticket_source = :commit # :commit (scan commit messages) or :branch (leading digits of branch name)
      @test_framework   = nil # :minitest or :rspec — auto-detected when nil
      @test_command     = nil # e.g. "bundle exec ruby -Itest" or "bundle exec rspec"
      @test_timeout     = 60  # seconds
      @git_timeout      = 10  # seconds for git subprocesses
    end

    def validate_workspace_root!
      root = workspace_root
      return if !root || root.to_s.strip.empty?

      root_path = root.to_s
      unless File.directory?(root_path)
        raise ArgumentError, "workspace_root must be an existing directory: #{root_path}"
      end
    end
  end
end
