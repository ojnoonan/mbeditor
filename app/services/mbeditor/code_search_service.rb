# frozen_string_literal: true

require "open3"

module Mbeditor
  class CodeSearchService
    JS_GLOBS = %w[*.js *.jsx *.ts *.tsx *.js.jsx *.js.erb *.jsx.erb].freeze

    class << self
      def call(pattern, workspace_root, globs: JS_GLOBS)
        if SearchReplaceService::RG_AVAILABLE
          run_rg(pattern, workspace_root, globs)
        else
          run_grep(pattern, workspace_root, globs)
        end
      rescue StandardError
        []
      end

      private

      def run_rg(pattern, workspace_root, globs)
        args = ["rg", "--no-heading", "-n", "--color=never", "-e", pattern]
        args += globs.flat_map { |g| ["-g", g] }
        args << workspace_root
        out, = Open3.capture2(*args)
        out.lines
      rescue StandardError
        []
      end

      def run_grep(pattern, workspace_root, globs)
        includes = globs.map { |g| "--include=#{g}" }
        args = ["grep", "-rn", "--color=never", "-E", pattern] + includes + [workspace_root]
        out, = Open3.capture2(*args)
        out.lines
      rescue StandardError
        []
      end
    end
  end
end
