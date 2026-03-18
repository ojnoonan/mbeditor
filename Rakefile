require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = false
end

desc 'Compile JSX components to plain JS'
task :build_js do
  if File.exist?(File.join(__dir__, 'build_js.js'))
    sh 'node build_js.js'
  else
    puts '[mbeditor] build_js.js not found — skipping JSX compile (using committed output)'
  end
end

# Ensure JS is compiled before the gem is built
task build: :build_js

task default: :test
