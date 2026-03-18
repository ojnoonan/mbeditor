module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root, :excluded_paths, :rubocop_command, :monaco_cdn_base

    def initialize
      @allowed_environments = [:development]
      @workspace_root = nil
      @excluded_paths = %w[.git tmp log node_modules .bundle coverage vendor/bundle]
      @rubocop_command = "rubocop"
      @monaco_cdn_base = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2"
    end
  end
end
