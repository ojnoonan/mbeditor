# frozen_string_literal: true

module Mbeditor
  class CodeSearchService
    JS_GLOBS = %w[*.js *.jsx *.ts *.tsx *.js.jsx *.js.erb *.jsx.erb].freeze

    class << self
      def call(pattern, workspace_root, globs: JS_GLOBS)
        args =
          if AvailabilityProbe.rg
            rg_args(pattern, workspace_root, globs)
          else
            grep_args(pattern, workspace_root, globs)
          end

        # Route through ProcessRunner so a hung rg/grep over a large workspace
        # is killed (process-group SIGKILL) rather than blocking the Puma
        # thread. A timeout is treated as a non-result, matching the graceful
        # degradation already used for every other subprocess failure here.
        result = ProcessRunner.call(args, timeout: timeout)
        result[:stdout].lines
      rescue StandardError
        []
      end

      private

      def timeout
        secs = Mbeditor.configuration.search_timeout&.to_i
        secs && secs.positive? ? secs : nil
      end

      def rg_args(pattern, workspace_root, globs)
        args = ["rg", "--no-heading", "-n", "--color=never", "-e", pattern]
        args += globs.flat_map { |g| ["-g", g] }
        args << workspace_root
      end

      def grep_args(pattern, workspace_root, globs)
        includes = globs.map { |g| "--include=#{g}" }
        ["grep", "-rn", "--color=never", "-E", pattern] + includes + [workspace_root]
      end
    end
  end
end
