# frozen_string_literal: true

module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command,
                  :redmine_enabled, :redmine_url, :redmine_api_key, :redmine_ticket_source,
                  :test_framework, :test_command, :test_timeout,
                  :authenticate_with,
                  :lint_timeout, :base_branch_candidates, :git_timeout

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
      @lint_timeout     = 15  # seconds for RuboCop/haml-lint subprocesses
      @base_branch_candidates = %w[origin/develop origin/main origin/master develop main master]
      @git_timeout      = nil # seconds; nil disables (no timeout on git subprocesses)
    end
  end
end
