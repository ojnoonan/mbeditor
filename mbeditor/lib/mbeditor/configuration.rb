module Mbeditor
  class Configuration
    attr_accessor :allowed_environments, :workspace_root

    def initialize
      @allowed_environments = [:development]
      @workspace_root = nil
    end
  end
end
