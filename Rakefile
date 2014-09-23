require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |t|
  t.pattern = "spec/**/*_spec.rb"
end

desc 'Flush the test database (15)'
task :flushdb do
  require 'redis'
  Redis.new(db: 15).flushdb
end