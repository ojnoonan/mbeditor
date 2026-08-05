# frozen_string_literal: true

module Mbeditor
  # Line-oriented regex search over the workspace's JS-family files. Backs the
  # JS definition/member lookups. Same three-tier backend as
  # SearchReplaceService (rg > git grep > grep), bounded by
  # config.search_timeout and config.excluded_paths.
  class CodeSearchService
    JS_GLOBS = %w[*.js *.jsx *.ts *.tsx *.js.jsx *.js.erb *.jsx.erb].freeze

    # Minified bundles are skipped, matching JsProgramService and
    # JsGlobalsService (which use the same [.-]min.ext convention as a Regexp).
    # A bundle's globals are one-letter names inside a closure, so it can never
    # hold the definition being looked for — but it is usually the largest file
    # in the workspace and one enormous line, which is the worst case for the
    # -E alternation these lookups run. Pure cost, no results.
    MINIFIED_GLOBS = %w[*.min.js *.min.jsx *.min.ts *.min.tsx
                        *-min.js *-min.jsx *-min.ts *-min.tsx].freeze

    class << self
      def call(pattern, workspace_root, globs: JS_GLOBS)
        root = workspace_root.to_s
        if SearchReplaceService.rg_available?
          run_rg(pattern, root, globs)
        elsif SearchReplaceService.git_tier?(root)
          run_git_grep(pattern, root, globs)
        else
          run_grep(pattern, root, globs)
        end
      rescue StandardError
        []
      end

      private

      def excluded_paths
        Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:empty?)
      end

      def search_timeout
        t = Mbeditor.configuration.search_timeout
        t && t.to_i > 0 ? t.to_i : nil
      end

      def run_command(args, env: {})
        result = ProcessRunner.call(args, timeout: search_timeout, env: env)
        out = result[:stdout].force_encoding(Encoding::UTF_8)
        out = out.scrub("�") unless out.valid_encoding?
        out.lines
      rescue ProcessRunner::TimeoutError
        []
      rescue StandardError
        []
      end

      def run_rg(pattern, workspace_root, globs)
        args = [SearchReplaceService.rg_command, "--no-heading", "-n", "--color=never"]
        # Matches SearchReplaceService: both search paths honour the same
        # config so definition lookups and project search can't disagree about
        # which files exist.
        args << "--no-ignore" unless SearchReplaceService.respect_gitignore?
        args += ["-e", pattern]
        args += globs.flat_map { |g| ["-g", g] }
        MINIFIED_GLOBS.each { |g| args << "--glob=!#{g}" }
        excluded_paths.each { |p| args << "--glob=!#{p}" }
        args << workspace_root
        run_command(args)
      end

      # Exclusions must reach git as :(exclude) pathspecs, not just be filtered
      # out of the results afterwards: without them git walks node_modules and
      # every other excluded tree in full before we throw the matches away.
      #
      # No LC_ALL=C here. It is not free — the C locale sends git's -E engine
      # down a slower path (measured 2.2x on this workspace), and the patterns
      # built above are always -E.
      def run_git_grep(pattern, workspace_root, globs)
        gitignore_flag = SearchReplaceService.respect_gitignore? ? "--untracked" : "--no-index"
        args = ["git", "-C", workspace_root, "grep", "-I", "-n", "--no-color", gitignore_flag, "-E", "-e", pattern, "--"]
        args += globs
        args += MINIFIED_GLOBS.map { |g| ":(exclude)#{g}" }
        args += excluded_paths.map { |p| ":(exclude)#{p}" }
        lines = run_command(args)
        # git grep prints workspace-relative paths; callers expect absolute
        # (they re-relativize against workspace_root).
        lines.map { |l| "#{workspace_root}/#{l}" }
      end

      def run_grep(pattern, workspace_root, globs)
        includes = globs.map { |g| "--include=#{g}" }
        excludes = MINIFIED_GLOBS.map { |g| "--exclude=#{g}" }
        args = ["grep", "-I", "-rn", "--color=never", "-E", pattern] + includes + excludes
        excluded_paths.reject { |p| p.include?("/") }.select { |d| d.match?(/\A[\w.-]+\z/) }.each do |d|
          args << "--exclude-dir=#{d}"
        end
        args << workspace_root
        run_command(args, env: { "LC_ALL" => "C" })
      end
    end
  end
end
