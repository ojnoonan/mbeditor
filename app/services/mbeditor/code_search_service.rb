# frozen_string_literal: true

require "open3"

module Mbeditor
  # Line-oriented regex search over the workspace's JS-family files. Backs the
  # JS definition/member lookups. Same three-tier backend as
  # SearchReplaceService (rg > git grep > grep), bounded by
  # config.search_timeout and config.excluded_paths.
  class CodeSearchService
    JS_GLOBS = %w[*.js *.jsx *.ts *.tsx *.js.jsx *.js.erb *.jsx.erb].freeze

    class << self
      def call(pattern, workspace_root, globs: JS_GLOBS)
        root = workspace_root.to_s
        if SearchReplaceService.rg_available?
          run_rg(pattern, root, globs)
        elsif File.exist?(File.join(root, ".git"))
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
        args = ["rg", "--no-heading", "-n", "--color=never", "-e", pattern]
        args += globs.flat_map { |g| ["-g", g] }
        excluded_paths.each { |p| args << "--glob=!#{p}" }
        args << workspace_root
        run_command(args)
      end

      def run_git_grep(pattern, workspace_root, globs)
        args = ["git", "-C", workspace_root, "grep", "-I", "-n", "--no-color", "--untracked", "-E", "-e", pattern, "--"]
        args += globs
        lines = run_command(args, env: { "LC_ALL" => "C" })
        # git grep prints workspace-relative paths; callers expect absolute
        # (they re-relativize against workspace_root).
        lines.map { |l| "#{workspace_root}/#{l}" }
      end

      def run_grep(pattern, workspace_root, globs)
        includes = globs.map { |g| "--include=#{g}" }
        args = ["grep", "-I", "-rn", "--color=never", "-E", pattern] + includes
        excluded_paths.reject { |p| p.include?("/") }.select { |d| d.match?(/\A[\w.-]+\z/) }.each do |d|
          args << "--exclude-dir=#{d}"
        end
        args << workspace_root
        run_command(args, env: { "LC_ALL" => "C" })
      end
    end
  end
end
