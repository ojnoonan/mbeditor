require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList[
    'test/controllers/**/*_test.rb',
    'test/channels/**/*_test.rb',
    'test/services/**/*_test.rb',
    'test/lib/**/*_test.rb',
    'test/integration/**/*_test.rb'
  ]
  t.verbose = false
end

Rake::TestTask.new(:system_test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/system/**/*_test.rb']
  t.verbose = false
end

# Ensure JS is compiled before the gem is built

task default: :test
