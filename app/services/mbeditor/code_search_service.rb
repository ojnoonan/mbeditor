# frozen_string_literal: true

require "shellwords"
require "etc"

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

      # Same shape as SearchReplaceService's grep tier: find prunes every
      # exclusion — slashed ones included, which --exclude-dir cannot express —
      # before the walk, and applies the include/minified globs there too, so
      # grep only ever opens candidate JS files. grep -r --include still walked
      # (and for public/assets, read) the excluded trees on every lookup.
      # ProcessRunner kills the process group, so the sh -c pipeline dies as
      # one unit on timeout.
      def run_grep(pattern, workspace_root, globs)
        prune = excluded_paths.flat_map do |p|
          p.include?("/") ? ["-path", File.join(workspace_root, p), "-o"] : ["-name", p, "-o"]
        end
        find = ["find", workspace_root]
        find += ["("] + prune[0..-2] + [")", "-prune", "-o"] unless prune.empty?
        find += ["-type", "f", "("] + globs.flat_map { |g| ["-name", g, "-o"] }[0..-2] + [")"]
        MINIFIED_GLOBS.each { |g| find += ["!", "-name", g] }
        find << "-print0"
        xargs = ["xargs", "-0", "-P", Etc.nprocessors.clamp(2, 8).to_s, "-n", "500",
                 "grep", "-I", "-Hn", "--line-buffered", "--color=never", "-E", "-e", pattern, "--"]
        cmd = "#{Shellwords.shelljoin(find)} | #{Shellwords.shelljoin(xargs)}"
        run_command(["sh", "-c", cmd], env: { "LC_ALL" => "C" })
      end
    end
  end
end
