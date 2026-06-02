# frozen_string_literal: true

module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command,
                  :redmine_enabled, :redmine_url, :redmine_api_key, :redmine_ticket_source,
                  :test_framework, :test_command, :test_timeout,
                  :authenticate_with, :authentication_cache_ttl,
                  :lint_timeout, :base_branch_candidates, :git_timeout,
                  :ruby_def_include_dirs, :related_files_custom_paths,
                  :mount_path, :resilient_routing

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
      @git_timeout            = nil # seconds; nil disables (no timeout on git subprocesses)
      @ruby_def_include_dirs  = %w[app/models app/controllers app/helpers app/concerns]
      @related_files_custom_paths = []
      @authentication_cache_ttl = 0
      @mount_path = nil # explicit URL prefix override; nil falls through to detection/"/mbeditor"
      @resilient_routing = true # serve /mbeditor from middleware so the editor survives a broken host routes.rb; false is the escape hatch
    end
  end
end
