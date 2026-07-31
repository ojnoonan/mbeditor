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
                  :js_program, :js_program_exclude,
                  :js_syntax_check, :babel_standalone_path,
                  :ruby_lsp, :ruby_lsp_command, :ruby_lsp_timeout,
                  :exception_capture,
                  :search_respect_gitignore, :ripgrep_command

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
      @search_timeout         = 15 # seconds; wall-clock bound on every search subprocess, nil disables
      # Skip .gitignore'd files in project search and definition lookups.
      #
      # Defaults to true, matching VS Code and ripgrep. The false path has to
      # ask git for --no-index, which walks every ignored tree the app has —
      # node_modules, public/packs, app/assets/builds, caches — and on the
      # git-grep tier (no ripgrep installed) that measured 29x slower on this
      # repo alone: 3714 files walked instead of 253. It also fills results
      # with matches inside minified bundles.
      #
      # Set to false to search ignored files too; expect it to be slow on a
      # machine without ripgrep.
      @search_respect_gitignore = true
      # Path to the ripgrep binary. nil auto-resolves: PATH first, then the
      # usual install prefixes.
      #
      # This matters more than it looks. ripgrep is 10-30x faster than the
      # git-grep fallback, and the probe used to run a bare "rg" — so it found
      # ripgrep only if the *server process* had it on PATH. A Rails server
      # started from launchd, systemd, foreman or an IDE typically inherits a
      # stripped PATH without /opt/homebrew/bin or /usr/local/bin, so ripgrep
      # could be installed and still invisible, silently dropping every search
      # to the slow tier. GET /workspace reports the tier actually in use.
      @ripgrep_command = nil
      @ruby_def_include_dirs  = %w[app/models app/controllers app/helpers app/concerns]
      @related_files_custom_paths = []
      @authentication_cache_ttl = 0
      @js_global_identifiers = [] # extra ambient JS globals for the editor (runtime-only names invisible to static scan, e.g. %w[Routes I18n])
      # Load the workspace's own JS source into Monaco's TypeScript program, so
      # cross-file references get real inferred types instead of ambient `any`.
      @js_program = true
      # Excluded from that program on top of excluded_paths. Vendored libraries
      # are UMD-wrapped (the global is assigned inside a closure), so their
      # source yields no globals to TypeScript and only costs parse time — they
      # stay on ambient declarations instead. Add any other directory of
      # third-party or generated JS here, e.g. "app/assets/javascripts/react".
      @js_program_exclude = %w[vendor]
      @js_syntax_check = :auto # save-time babel parse check via host mini_racer + babel-standalone; false disables
      @babel_standalone_path = nil # explicit path to babel-standalone JS; nil auto-detects via the asset pipeline
      @ruby_lsp         = :auto # use the host's ruby-lsp for Ruby definitions/hover/completion when available; false disables
      @ruby_lsp_command = nil   # override the ruby-lsp launch command (String or Array); nil auto-resolves bin/ruby-lsp > gem > bundle exec
      @ruby_lsp_timeout = 3     # seconds per LSP request before falling back to the built-in services
      # Record exceptions raised by the host app's controllers so they show up
      # in the editor's Problems panel instead of only in the log. Development
      # only. Exception messages can contain interpolated request params — the
      # same exposure the log panel already has, since it tails the dev log.
      # Set to false to record nothing.
      @exception_capture = :auto
      @mount_path = nil # explicit URL prefix override; nil falls through to detection/"/mbeditor"
      @resilient_routing = true # serve /mbeditor from middleware so the editor survives a broken host routes.rb; false is the escape hatch
    end
  end
end
