require_relative "lib/mbeditor/version"

Gem::Specification.new do |spec|
  spec.name        = "mbeditor"
  spec.version     = Mbeditor::VERSION
  spec.authors     = ["Oliver Noonan"]
  spec.email       = ["s3660457@student.rmit.edu.au"]
  spec.summary     = "Mini Browser Editor (mbeditor) mountable Rails engine"
  spec.description = "Mbeditor provides an in-browser code editor with split panes, git insights, search, and optional RuboCop linting for Rails apps."
  spec.homepage    = "https://github.com/ojnoonan/mbeditor"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["app/**/*", "config/**/*", "lib/**/*", "public/**/*", "vendor/**/*", "README.md", "mbeditor.gemspec"]
  end

  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => "https://github.com/ojnoonan/mbeditor",
    "source_code_uri" => "https://github.com/ojnoonan/mbeditor",
    "bug_tracker_uri" => "https://github.com/ojnoonan/mbeditor/issues"
  }

  spec.add_dependency "rails", ">= 7.1", "< 9.0"
  spec.add_dependency "sprockets-rails", ">= 3.4"
  spec.add_dependency "babel-transpiler", "~> 0.7"

  spec.add_development_dependency "rubocop", "~> 1.80"
  spec.add_development_dependency "rubocop-rails", "~> 2.33"
end
