require_relative "lib/mbeditor/version"

Gem::Specification.new do |spec|
  spec.name        = "mbeditor"
  spec.version     = Mbeditor::VERSION
  spec.authors     = ["Mini Browser Editor"]
  spec.email       = ["maintainers@example.com"]
  spec.summary     = "Mini Browser Editor (mbeditor) mountable Rails engine"
  spec.description = "Mbeditor provides an in-browser code editor with split panes, git insights, search, and optional RuboCop linting for Rails apps."
  spec.homepage    = "https://example.com/mbeditor"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["app/**/*", "config/**/*", "lib/**/*", "README.md", "mbeditor.gemspec"]
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "rails", "~> 7.1"
  spec.add_dependency "sprockets", "~> 4.0"
  spec.add_dependency "sprockets-rails", "~> 3.4"
  spec.add_dependency "babel-transpiler", "~> 0.7"
  spec.add_dependency "babel-source", "~> 5.8"

  spec.add_development_dependency "rubocop", "~> 1.80"
  spec.add_development_dependency "rubocop-rails", "~> 2.33"
end
