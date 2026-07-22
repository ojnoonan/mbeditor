# frozen_string_literal: true

module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command, :rubocop_server,
                  :redmine_enabled, :redmine_url, :redmine_api_key, :redmine_ticket_source,
                  :test_framework, :test_command, :test_timeout,
                  :authenticate_with, :authentication_cache_ttl,
                  :lint_timeout, :base_branch_candidates, :git_timeout, :search_timeout,
                  :ruby_def_include_dirs, :related_files_custom_paths,
                  :mount_path, :resilient_routing, :js_global_identifiers,
                  :js_syntax_check, :babel_standalone_path,
                  :ruby_lsp, :ruby_lsp_command, :ruby_lsp_timeout

    def initialize
      @allowed_environments = [:development]
      @workspace_root = nil
      @excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle public/assets storage]
      @rubocop_command = "rubocop"
      @rubocop_server  = true # use rubocop's --server daemon (rubocop >= 1.31) for ~10x faster lint; false forces --no-server
      @redmine_enabled       = false
      @redmine_url           = nil
      @redmine_api_key       = nil
      @redmine_ticket_source = :commit # :commit (scan commit messages) or :branch (leading digits of branch name)
      @test_framework   = nil # :minitest or :rspec — auto-detected when nil
      @test_command     = nil # e.g. "bundle exec ruby -Itest" or "bundle exec rspec"
      @test_timeout     = 60  # seconds
      @lint_timeout     = 15  # seconds for RuboCop/haml-lint subprocesses
      @base_branch_candidates = %w[origin/develop origin/main origin/master develop main master]
      @git_timeout            = 10 # seconds; nil disables (no timeout on git subprocesses)
      @search_timeout         = 15 # seconds; wall-clock bound on search subprocesses, nil disables
      @ruby_def_include_dirs  = %w[app/models app/controllers app/helpers app/concerns]
      @related_files_custom_paths = []
      @authentication_cache_ttl = 0
      @js_global_identifiers = [] # extra ambient JS globals for the editor (runtime-only names invisible to static scan, e.g. %w[Routes I18n])
      @js_syntax_check = :auto # save-time babel parse check via host mini_racer + babel-standalone; false disables
      @babel_standalone_path = nil # explicit path to babel-standalone JS; nil auto-detects via the asset pipeline
      @ruby_lsp         = :auto # use the host's ruby-lsp for Ruby definitions/hover/completion when available; false disables
      @ruby_lsp_command = nil   # override the ruby-lsp launch command (String or Array); nil auto-resolves bin/ruby-lsp > gem > bundle exec
      @ruby_lsp_timeout = 3     # seconds per LSP request before falling back to the built-in services
      @mount_path = nil # explicit URL prefix override; nil falls through to detection/"/mbeditor"
      @resilient_routing = true # serve /mbeditor from middleware so the editor survives a broken host routes.rb; false is the escape hatch
    end
  end
end
