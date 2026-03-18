require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = false
end

desc 'Compile JSX components to plain JS'
task :build_js do
  sh 'node build_js.js'
end

# Ensure JS is compiled before the gem is built
task build: :build_js

task default: :test
